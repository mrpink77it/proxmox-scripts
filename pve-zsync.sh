#!/usr/bin/env bash
#
# PVE-Zsync TUI Manager - Advanced LXC Migration & Disaster Recovery for Proxmox VE
#

set -uo pipefail

CONFIG_FILE="/etc/pve-zsync-tui.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"

if [[ $EUID -ne 0 ]]; then
    echo "Errore: Questo script deve essere eseguito come root." >&2
    exit 1
fi

if ! command -v pveversion &> /dev/null; then
    echo "Errore: Questo sistema non sembra essere un nodo Proxmox VE." >&2
    exit 1
fi

init_system() {
    {
        echo 10; sleep 1
        apt-get update -qq
        echo 40; sleep 1
        apt-get install -y -qq whiptail pve-zsync nmap sshpass diffutils pv mbuffer mailutils curl
        echo 100; sleep 1
    } | whiptail --title "Inizializzazione Sistema" --gauge "Aggiornamento repository e installazione dipendenze..." 8 60 0
}

init_system

msg_box() {
    whiptail --title "$1" --msgbox "$2" 10 60
}

send_notifications() {
    local subject="$1"
    local message="$2"

    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=*[PVE Migration]* %0A${subject}%0A%0A${message}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi

    if [[ -n "${NOTIFICATION_EMAIL}" ]] && command -v mail &>/dev/null; then
        echo -e "$message" | mail -s "[Proxmox Migration] $subject" "$NOTIFICATION_EMAIL" || true
    fi
}

select_container() {
    local containers
    containers=$(pct list | tail -n +2 | awk '{print $1, ($4 ? $4 : "no-name") " (Status: " $2 ")"}')
    
    if [[ -z "$containers" ]]; then
        msg_box "Errore" "Nessun container LXC trovato su questo nodo."
        return 1
    fi

    local options=()
    while read -r vmid desc; do
        options+=("$vmid" "$desc")
    done <<< "$containers"

    CHOICE=$(whiptail --title "Selezione Container LXC" --menu "Scegli il container:" 15 60 6 "${options[@]}" 2>&1 >/dev/tty)
    clear
    [[ $? -eq 0 ]] && echo "$CHOICE"
}

discover_nodes() {
    local nodes=()
    
    if command -v pvesh &>/dev/null; then
        while read -r node; do
            [[ -n "$node" ]] && nodes+=("$node" "Cluster Node")
        done < <(pvesh get /nodes --output-format json 2>/dev/null | grep -o '"node": "[^"]*"' | cut -d'"' -f4)
    fi

    local local_subnet
    local_subnet=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -n 1)
    if [[ -n "$local_subnet" ]]; then
        local scanned
        scanned=$(nmap -p 8006 --open -oG - "$local_subnet" 2>/dev/null | awk '/Host:/ {print $2}')
        for ip in $scanned; do
            local found=0
            for existing in "${nodes[@]}"; do
                [[ "$existing" == "$ip" ]] && found=1
            done
            if [[ $found -eq 0 ]]; then
                nodes+=("$ip" "LAN Proxmox Node")
            fi
        done
    fi

    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "MANUAL"
    else
        echo "${nodes[@]}"
    fi
}

get_target_connection() {
    local node_list
    node_list=($(discover_nodes))

    local target_ip=""
    if [[ "${node_list[0]}" == "MANUAL" ]] || [[ ${#node_list[@]} -eq 0 ]]; then
        target_ip=$(whiptail --title "Nodo Target" --inputbox "Inserisci IP o hostname del nodo target:" 10 50 2>&1 >/dev/tty)
        [[ $? -ne 0 ]] && return 1
    else
        node_list+=("MANUAL" "Inserisci IP/Hostname manualmente")
        local choice
        choice=$(whiptail --title "Selezione Nodo Target" --menu "Scegli un nodo rilevato o inseriscilo:" 18 65 8 "${node_list[@]}" 2>&1 >/dev/tty)
        [[ $? -ne 0 ]] && return 1
        
        if [[ "$choice" == "MANUAL" ]]; then
            target_ip=$(whiptail --title "Nodo Target" --inputbox "Inserisci IP o hostname del nodo target:" 10 50 2>&1 >/dev/tty)
            [[ $? -ne 0 ]] && return 1
        else
            target_ip="$choice"
        fi
    fi

    local ssh_port
    ssh_port=$(whiptail --title "Porta SSH" --inputbox "Inserisci la porta SSH:" 10 50 "22" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return 1

    local ssh_user
    ssh_user=$(whiptail --title "Utente SSH" --inputbox "Inserisci l'utente SSH:" 10 50 "root" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return 1

    local ssh_pass
    ssh_pass=$(whiptail --title "Password SSH" --passwordbox "Inserisci la password SSH (lascia vuoto se usi chiavi SSH):" 10 50 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return 1

    echo "$target_ip|$ssh_port|$ssh_user|$ssh_pass"
}

ssh_key_wizard() {
    local conn_info
    conn_info=$(get_target_connection)
    [[ -z "$conn_info" ]] && return

    IFS='|' read -r ip port user pass <<< "$conn_info"

    if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
        ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa &>/dev/null
    fi

    if [[ -n "$pass" ]]; then
        sshpass -p "$pass" ssh-copy-id -o StrictHostKeyChecking=no -p "$port" "${user}@${ip}" &>/dev/null
    else
        ssh-copy-id -o StrictHostKeyChecking=no -p "$port" "${user}@${ip}" &>/dev/null
    fi

    if [[ $? -eq 0 ]]; then
        msg_box "Successo" "Chiave SSH configurata con successo per ${user}@${ip}!"
    else
        msg_box "Errore" "Impossibile configurare la chiave SSH. Verifica le credenziali."
    fi
}

preflight_checks() {
    local ip="$1" port="$2" user="$3" pass="$4" pool="$5"
    
    local ssh_cmd="ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"
    if [[ -n "$pass" ]]; then
        ssh_cmd="sshpass -p $pass ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"
    fi

    local free_space
    free_space=$($ssh_cmd "zfs get -H -o value available $pool" 2>/dev/null)
    if [[ -z "$free_space" ]]; then
        msg_box "Errore Pre-flight" "Impossibile verificare il pool ZFS '${pool}' sul target ${ip}."
        return 1
    fi

    return 0
}

sync_container_menu() {
    local vmid
    vmid=$(select_container)
    [[ -z "$vmid" ]] && return

    local conn_info
    conn_info=$(get_target_connection)
    [[ -z "$conn_info" ]] && return

    IFS='|' read -r target_node target_port ssh_user ssh_pass <<< "$conn_info"

    local target_pool
    target_pool=$(whiptail --title "Pool ZFS Target" --inputbox "Inserisci il pool/dataset ZFS di destinazione:" 10 50 "rpool/data" 2>&1 >/dev/tty)
    [[ $? -ne 0 || -z "$target_pool" ]] && return

    if ! preflight_checks "$target_node" "$target_port" "$ssh_user" "$ssh_pass" "$target_pool"; then
        return
    fi

    local job_type
    job_type=$(whiptail --title "Modalità pve-zsync" --menu "Seleziona modalità:" 12 50 2 \
        "sync" "Sincronizzazione singola (One-shot)" \
        "create" "Job periodico ricorsivo" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    local job_name="lxc-migr-${vmid}"
    if [[ "$job_type" == "create" ]]; then
        job_name=$(whiptail --title "Nome Job" --inputbox "Nome identificativo job pve-zsync:" 10 50 "$job_name" 2>&1 >/dev/tty)
        [[ $? -ne 0 ]] && return
    fi

    local post_action
    post_action=$(whiptail --title "Azioni Post-Migrazione" --menu "Cosa fare dopo la sincronizzazione?" 14 60 3 \
        "none" "Nessuna azione automatica" \
        "switch" "Spegni sorgente e avvia target (Switchover)" \
        "shutdown_src" "Spegni solo il container sorgente" 2>&1 >/dev/tty)

    {
        if [[ "$job_type" == "sync" ]]; then
            pve-zsync sync --source "$vmid" --dest "${target_node}:${target_pool}" --name "$job_name" --maxsnap 2 --verbose
        else
            pve-zsync create --source "$vmid" --dest "${target_node}:${target_pool}" --name "$job_name" --schedule hourly --maxsnap 2 --verbose
        fi

        local scp_cmd="scp -P $target_port -o StrictHostKeyChecking=no"
        if [[ -n "$ssh_pass" ]]; then
            sshpass -p "$ssh_pass" $scp_cmd "/etc/pve/lxc/${vmid}.conf" "${ssh_user}@${target_node}:/etc/pve/lxc/${vmid}.conf"
        else
            $scp_cmd "/etc/pve/lxc/${vmid}.conf" "${ssh_user}@${target_node}:/etc/pve/lxc/${vmid}.conf"
        fi

        local ssh_exec="ssh -p $target_port -o StrictHostKeyChecking=no ${ssh_user}@${target_node}"
        [[ -n "$ssh_pass" ]] && ssh_exec="sshpass -p $ssh_pass ssh -p $target_port -o StrictHostKeyChecking=no ${ssh_user}@${target_node}"

        if [[ "$post_action" == "switch" || "$post_action" == "shutdown_src" ]]; then
            pct stop "$vmid" --skiplock 1 2>/dev/null || true
        fi

        if [[ "$post_action" == "switch" ]]; then
            $ssh_exec "pct start $vmid" 2>/dev/null || true
        fi

    } | whiptail --title "Elaborazione in corso" --gauge "Sincronizzazione in corso..." 10 60 0

    send_notifications "Sincronizzazione LXC Completata" "Container ID: ${vmid} sincronizzato con successo verso ${target_node}."
    msg_box "Completato" "Procedura completata con successo!"
}

manage_jobs_menu() {
    local jobs_raw
    jobs_raw=$(pve-zsync list 2>/dev/null | tail -n +2)

    if [[ -z "$jobs_raw" ]]; then
        msg_box "Info" "Nessun job pve-zsync configurato."
        return
    fi

    local options=()
    while read -r line; do
        [[ -z "$line" ]] && continue
        local jname=$(echo "$line" | awk '{print $1}')
        local jsource=$(echo "$line" | awk '{print $2}')
        options+=("$jname" "Source: $jsource")
    done <<< "$jobs_raw"

    local selected_job
    selected_job=$(whiptail --title "Gestione Job pve-zsync" --menu "Seleziona il job da eliminare:" 15 60 6 "${options[@]}" 2>&1 >/dev/tty)
    [[ $? -ne 0 || -z "$selected_job" ]] && return

    if (whiptail --title "Conferma" --yesno "Vuoi davvero eliminare il job '${selected_job}'?" 10 50); then
        pve-zsync destroy --name "$selected_job"
        msg_box "Eliminato" "Job rimosso con successo."
    fi
}

configure_notifications_menu() {
    local token
    token=$(whiptail --title "Telegram Bot" --inputbox "Inserisci Telegram Bot Token (lascia vuoto per disabilitare):" 10 50 "$TELEGRAM_BOT_TOKEN" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    local chatid
    chatid=$(whiptail --title "Telegram Chat ID" --inputbox "Inserisci Telegram Chat ID:" 10 50 "$TELEGRAM_CHAT_ID" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    local email
    email=$(whiptail --title "Notifiche Email" --inputbox "Inserisci indirizzo Email per i report:" 10 50 "$NOTIFICATION_EMAIL" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    cat << EOF > "$CONFIG_FILE"
TELEGRAM_BOT_TOKEN="${token}"
TELEGRAM_CHAT_ID="${chatid}"
NOTIFICATION_EMAIL="${email}"
EOF

    msg_box "Salvataggio" "Configurazione notifiche salvata con successo."
}

compare_config_menu() {
    local vmid
    vmid=$(select_container)
    [[ -z "$vmid" ]] && return

    local conn_info
    conn_info=$(get_target_connection)
    [[ -z "$conn_info" ]] && return

    IFS='|' read -r target_node target_port ssh_user ssh_pass <<< "$conn_info"

    local local_conf="/etc/pve/lxc/${vmid}.conf"
    local temp_remote_conf="/tmp/${vmid}_remote.conf"

    if [[ ! -f "$local_conf" ]]; then
        msg_box "Errore" "Configurazione locale non trovata."
        return
    fi

    local scp_cmd="scp -P $target_port -o StrictHostKeyChecking=no"
    if [[ -n "$ssh_pass" ]]; then
        sshpass -p "$ssh_pass" $scp_cmd "${ssh_user}@${target_node}:/etc/pve/lxc/${vmid}.conf" "$temp_remote_conf" 2>/dev/null
    else
        $scp_cmd "${ssh_user}@${target_node}:/etc/pve/lxc/${vmid}.conf" "$temp_remote_conf" 2>/dev/null
    fi

    if [[ ! -f "$temp_remote_conf" ]]; then
        msg_box "Errore" "Impossibile recuperare il file di configurazione remoto."
        return
    fi

    local diff_output
    diff_output=$(diff -u "$local_conf" "$temp_remote_conf" || true)
    rm -f "$temp_remote_conf"

    if [[ -z "$diff_output" ]]; then
        msg_box "Confronto" "Le configurazioni sono IDENTICHE."
    else
        echo "$diff_output" > /tmp/lxc_diff.txt
        whiptail --title "Differenze Configurazioni (Locale vs Remota)" --textbox /tmp/lxc_diff.txt 22 80
        rm -f /tmp/lxc_diff.txt
    fi
}

while true; do
    CHOICE=$(whiptail --title "PVE-Zsync LXC Manager" --menu "Gestione Avanzata Migrazioni e DR Proxmox" 18 68 6 \
        "1" "Sincronizza / Clona Container LXC (con pre-flight e post-azioni)" \
        "2" "Configura Wizard Chiavi SSH Passwordless" \
        "3" "Gestisci / Elimina Job pve-zsync" \
        "4" "Confronta Configurazione (Sorgente vs Target)" \
        "5" "Configura Notifiche (Telegram & Email)" \
        "6" "Esci" 2>&1 >/dev/tty)

    [[ $? -ne 0 ]] && break

    case $CHOICE in
        1) sync_container_menu ;;
        2) ssh_key_wizard ;;
        3) manage_jobs_menu ;;
        4) compare_config_menu ;;
        5) configure_notifications_menu ;;
        6) clear; exit 0 ;;
    esac
done

clear
