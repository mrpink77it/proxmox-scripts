#!/usr/bin/env bash
#
# PVE-Zsync Manager - Gestione Sincronizzazione LXC Proxmox VE
#

set -uo pipefail

CONFIG_FILE="/etc/pve-zsync-tui.conf"

# Caricamento configurazione notifiche se esiste
if [[ -f "\$CONFIG_FILE" ]]; then
    source "\$CONFIG_FILE"
fi

TELEGRAM_BOT_TOKEN="\${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="\${TELEGRAM_CHAT_ID:-}"
NOTIFICATION_EMAIL="\${NOTIFICATION_EMAIL:-}"

# Verifica permessi di root
if [[ \$EUID -ne 0 ]]; then
    echo "Errore: Questo script deve essere eseguito come root." >&2
    exit 1
fi

# Controllo OS Proxmox VE
if ! command -v pveversion &> /dev/null; then
    echo "Errore: Questo sistema non sembra essere un nodo Proxmox VE." >&2
    exit 1
fi

# Funzione per installazione dipendenze e aggiornamento OS
init_system() {
    {
        echo 10; sleep 1
        apt-get update -qq
        echo 40; sleep 1
        apt-get install -y -qq whiptail pve-zsync nmap sshpass diffutils pv mbuffer mailutils curl jq
        echo 100; sleep 1
    } | whiptail --title "Inizializzazione Sistema" --gauge "Aggiornamento repository e installazione dipendenze..." 8 60 0
}

init_system

# Helper per dialoghi standard con pulsante Indietro
msg_box() {
    whiptail --title "\$1" --ok-button "OK" --msgbox "\$2" 12 65
}

# Invio Notifiche
send_notifications() {
    local subject="\$1"
    local message="\$2"

    # Telegram
    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=\${TELEGRAM_CHAT_ID}" \
            -d "text=*[PVE-Zsync]* %0A\${subject}%0A%0A\${message}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi

    # Email
    if [[ -n "\${NOTIFICATION_EMAIL}" ]] && command -v mail &>/dev/null; then
        echo -e "$message" \vert{} mail -s "[PVE-Zsync] $subject" "$NOTIFICATION_EMAIL" || true
    fi
}

# Estrazione nome effettivo dal file di configurazione Proxmox LXC
get_lxc_hostname() {
    local vmid="\$1"
    local conf_file="/etc/pve/lxc/\${vmid}.conf"
    local hostname=""

    if [[ -f "\$conf_file" ]]; then
        hostname=$(grep -E "^hostname:" "$conf_file" | awk '{print \$2}')
    fi

    if [[ -z "\$hostname" ]]; then
        echo "senza-nome"
    else
        echo "\$hostname"
    fi
}

# Funzione per selezionare un container LXC locale
select_container() {
    local action_context="\${1:-Operazione in corso}"
    local containers_raw
    containers_raw=\$(pct list 2>/dev/null | tail -n +2)

    if [[ -z "\$containers_raw" ]]; then
        msg_box "Errore" "Nessun container LXC trovato su questo nodo."
        return 1
    fi

    local options=()
    while read -r line; do
        [[ -z "\$line" ]] && continue
        local vmid status
        vmid=$(echo "$line" | awk '{print \$1}')
        status=$(echo "$line" | awk '{print \$2}')
        
        local name
        name=$(get_lxc_hostname "$vmid")
        
        options+=("\$vmid" "$name [Stato:$status]")
    done <<< "\$containers_raw"

    local prompt_msg="\${action_context}\n\nLo script eseguirà la sincronizzazione ZFS dei dati e l'adattamento della configurazione.\n\nSeleziona il container LXC:"

    CHOICE=\$(whiptail --title "Selezione Container LXC" \
        --ok-button "Seleziona" \
        --cancel-button "Indietro" \
        --menu "$prompt_msg" 18 70 6 "${options[@]}" 2>&1 >/dev/tty)

    if [[ \$? -ne 0 ]]; then
        return 1
    fi

    echo "\$CHOICE"
}

# Scansione Nodi (Cluster + LAN)
discover_nodes() {
    local nodes=()
    
    if command -v pvesh &>/dev/null; then
        while read -r node; do
            [[ -n "$node" ]] && nodes+=("$node" "Nodo Cluster")
        done < <(pvesh get /nodes --output-format json 2>/dev/null | grep -o '"node": "[^"]*"' | cut -d'"' -f4)
    fi

    local local_subnet
    local_subnet=\$(ip -o -f inet addr show | awk '/scope global/ {print \$4}' | head -n 1)
    if [[ -n "\$local_subnet" ]]; then
        local scanned
        scanned=$(nmap -p 8006 --open -oG - "$local_subnet" 2>/dev/null | awk '/Host:/ {print \$2}')
        for ip in \$scanned; do
            local found=0
            for existing in "\${nodes[@]}"; do
                [[ "$existing" == "$ip" ]] && found=1
            done
            if [[ \$found -eq 0 ]]; then
                nodes+=("\$ip" "Nodo Proxmox LAN")
            fi
        done
    fi

    if [[ \${#nodes[@]} -eq 0 ]]; then
        echo "MANUAL"
    else
        echo "\${nodes[@]}"
    fi
}

# Configurazione Target Node & SSH
get_target_connection() {
    local node_list
    node_list=(\$(discover_nodes))

    local target_ip=""
    if [[ "${node_list[0]}" == "MANUAL" ]] \vert{}\vert{} [[ ${#node_list[@]} -eq 0 ]]; then
        target_ip=\$(whiptail --title "Nodo Target" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci IP o hostname del nodo target:" 10 55 2>&1 >/dev/tty)
        [[ \$? -ne 0 ]] && return 1
    else
        node_list+=("MANUAL" "Inserisci IP/Hostname manualmente")
        local choice
        choice=\$(whiptail --title "Selezione Nodo Target" --ok-button "Seleziona" --cancel-button "Indietro" --menu "Scegli un nodo rilevato sulla rete o inseriscilo manualmente:" 18 68 8 "\${node_list[@]}" 2>&1 >/dev/tty)
        [[ \$? -ne 0 ]] && return 1
        
        if [[ "\$choice" == "MANUAL" ]]; then
            target_ip=\$(whiptail --title "Nodo Target" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci IP o hostname del nodo target:" 10 55 2>&1 >/dev/tty)
            [[ \$? -ne 0 ]] && return 1
        else
            target_ip="\$choice"
        fi
    fi

    local ssh_port
    ssh_port=\$(whiptail --title "Porta SSH" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci la porta SSH:" 10 55 "22" 2>&1 >/dev/tty)
    [[ \$? -ne 0 ]] && return 1

    local ssh_user
    ssh_user=\$(whiptail --title "Utente SSH" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci l'utente SSH:" 10 55 "root" 2>&1 >/dev/tty)
    [[ \$? -ne 0 ]] && return 1

    local ssh_pass
    ssh_pass=\$(whiptail --title "Password SSH" --ok-button "Avanti" --cancel-button "Indietro" --passwordbox "Inserisci la password SSH (lascia vuoto se usi chiavi SSH):" 10 55 2>&1 >/dev/tty)
    [[ \$? -ne 0 ]] && return 1

    echo "$target_ip\vert{}$ssh_port|$ssh_user\vert{}$ssh_pass"
}

# Rilevamento Storage Proxmox remoti via SSH
get_target_storages() {
    local ip="\$1" port="\$2" user="\$3" pass="\$4"
    local ssh_cmd="ssh -o StrictHostKeyChecking=no -p \$port ${user}@${ip}"
    [[ -n "\$pass" ]] && ssh_cmd="sshpass -p $pass ssh -o StrictHostKeyChecking=no -p$port ${user}@${ip}"

    local storages_raw
    storages_raw=$($ssh_cmd "pvesm status --content rootdir 2>/dev/null | tail -n +2" 2>/dev/null)

    if [[ -z "\$storages_raw" ]]; then
        echo ""
        return
    fi

    local options=()
    while read -r line; do
        [[ -z "\$line" ]] && continue
        local st_name st_type st_status
        st_name=$(echo "$line" | awk '{print \$1}')
        st_type=$(echo "$line" | awk '{print \$2}')
        st_status=$(echo "$line" | awk '{print \$3}')
        
        if [[ "\$st_status" == "active" ]]; then
            options+=("$st_name" "Tipo: $st_type")
        fi
    done <<< "\$storages_raw"

    echo "\${options[@]}"
}

# Rilevamento pool ZFS reale associato a uno storage Proxmox
get_zfs_pool_from
