#!/usr/bin/env bash
#
# PVE-Zsync Manager - Gestione Sincronizzazione LXC Proxmox VE
#

set -uo pipefail

CONFIG_FILE="/etc/pve-zsync-tui.conf"

# Caricamento configurazione notifiche se esiste
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"

# Verifica permessi di root
if [[ $EUID -ne 0 ]]; then
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
    whiptail --title "$1" --ok-button "OK" --msgbox "$2" 12 65
}

# Invio Notifiche
send_notifications() {
    local subject="$1"
    local message="$2"

    # Telegram
    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=*[PVE-Zsync]* %0A${subject}%0A%0A${message}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1 || true
    fi

    # Email
    if [[ -n "${NOTIFICATION_EMAIL}" ]] && command -v mail &>/dev/null; then
        echo -e "$message" | mail -s "[PVE-Zsync] $subject" "$NOTIFICATION_EMAIL" || true
    fi
}

# Estrazione nome effettivo dal file di configurazione Proxmox LXC
get_lxc_hostname() {
    local vmid="$1"
    local conf_file="/etc/pve/lxc/${vmid}.conf"
    local hostname=""

    if [[ -f "$conf_file" ]]; then
        hostname=$(grep -E "^hostname:" "$conf_file" | awk '{print $2}')
    fi

    if [[ -z "$hostname" ]]; then
        echo "senza-nome"
    else
        echo "$hostname"
    fi
}

# Funzione per selezionare un container LXC locale
select_container() {
    local action_context="${1:-Operazione in corso}"
    local containers_raw
    containers_raw=$(pct list 2>/dev/null | tail -n +2)

    if [[ -z "$containers_raw" ]]; then
        msg_box "Errore" "Nessun container LXC trovato su questo nodo."
        return 1
    fi

    local options=()
    while read -r line; do
        [[ -z "$line" ]] && continue
        local vmid status
        vmid=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        
        local name
        name=$(get_lxc_hostname "$vmid")
        
        options+=("$vmid" "$name [Stato: $status]")
    done <<< "$containers_raw"

    local prompt_msg="${action_context}\n\nLo script eseguirà la sincronizzazione ZFS dei dati e l'adattamento della configurazione.\n\nSeleziona il container LXC:"

    # Dimensioni ampliate a 20x78 con altezza menu 8 per evitare il disallineamento grafico
    CHOICE=$(whiptail --title "Selezione Container LXC" \
        --ok-button "Seleziona" \
        --cancel-button "Indietro" \
        --menu "$prompt_msg" 20 78 8 "${options[@]}" 2>&1 >/dev/tty)

    if [[ $? -ne 0 ]]; then
        return 1
    fi

    echo "$CHOICE"
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
                nodes+=("$ip" "Nodo Proxmox LAN")
            fi
        done
    fi

    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "MANUAL"
    else
        echo "${nodes[@]}"
    fi
}

# Configurazione Target Node & SSH
get_target_connection() {
    local node_list
    node_list=($(discover_nodes))

    local target_ip=""
    if [[ "${node_list[0]}" == "MANUAL" ]] || [[ ${#node_list[@]} -eq 0 ]]; then
        target_ip=$(whiptail --title "Nodo Target" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci IP o hostname del nodo target:" 10 55 2>&1 >/dev/tty)
        [[ $? -ne 0 ]] && return 1
    else
        node_list+=("MANUAL" "Inserisci IP/Hostname manualmente")
        local choice
        choice=$(whiptail --title "Selezione Nodo Target" --ok-button "Seleziona" --cancel-button "Indietro" --menu "Scegli un nodo rilevato sulla rete o inseriscilo manualmente:" 18 68 8 "${node_list[@]}" 2>&1 >/dev/tty)
        [[ $? -ne 0 ]] && return 1
        
        if [[ "$choice" == "MANUAL" ]]; then
            target_ip=$(whiptail --title "Nodo Target" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci IP o hostname del nodo target:" 10 55 2>&1 >/dev/tty)
            [[ $? -ne 0 ]] && return 1
        else
            target_ip="$choice"
        fi
    fi

    local ssh_port
    ssh_port=$(whiptail --title "Porta SSH" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci la porta SSH:" 10 55 "22" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return 1

    local ssh_user
    ssh_user=$(whiptail --title "Utente SSH" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci l'utente SSH:" 10 55 "root" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return 1

    local ssh_pass
    ssh_pass=$(whiptail --title "Password SSH" --ok-button "Avanti" --cancel-button "Indietro" --passwordbox "Inserisci la password SSH (lascia vuoto se usi chiavi SSH):" 10 55 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return 1

    echo "$target_ip|$ssh_port|$ssh_user|$ssh_pass"
}

# Rilevamento Storage Proxmox remoti via SSH
get_target_storages() {
    local ip="$1" port="$2" user="$3" pass="$4"
    local ssh_cmd="ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"
    [[ -n "$pass" ]] && ssh_cmd="sshpass -p $pass ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"

    local storages_raw
    storages_raw=$($ssh_cmd "pvesm status --content rootdir 2>/dev/null | tail -n +2" 2>/dev/null)

    if [[ -z "$storages_raw" ]]; then
        echo ""
        return
    fi

    local options=()
    while read -r line; do
        [[ -z "$line" ]] && continue
        local st_name st_type st_status
        st_name=$(echo "$line" | awk '{print $1}')
        st_type=$(echo "$line" | awk '{print $2}')
        st_status=$(echo "$line" | awk '{print $3}')
        
        if [[ "$st_status" == "active" ]]; then
            options+=("$st_name" "Tipo: $st_type")
        fi
    done <<< "$storages_raw"

    echo "${options[@]}"
}

# Rilevamento pool ZFS reale associato a uno storage Proxmox
get_zfs_pool_from_storage() {
    local ip="$1" port="$2" user="$3" pass="$4" storage_name="$5"
    local ssh_cmd="ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"
    [[ -n "$pass" ]] && ssh_cmd="sshpass -p $pass ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"

    local pool_name
    pool_name=$($ssh_cmd "pvesm config $storage_name 2>/dev/null | awk '/pool/ {print \$2}'" 2>/dev/null)

    if [[ -z "$pool_name" ]]; then
        echo "$storage_name"
    else
        echo "$pool_name"
    fi
}

# Ricerca del dataset ZFS sorgente associato al container
get_source_zfs_dataset() {
    local vmid="$1"
    local conf_file="/etc/pve/lxc/${vmid}.conf"
    local rootfs_line
    rootfs_line=$(grep -E "^rootfs:" "$conf_file")
    
    local vol_path
    vol_path=$(echo "$rootfs_line" | awk '{print $2}' | cut -d',' -f1)
    
    local storage_name=$(echo "$vol_path" | cut -d':' -f1)
    local subvol_name=$(echo "$vol_path" | cut -d':' -f2)
    
    local zpool_name
    zpool_name=$(pvesm config "$storage_name" 2>/dev/null | awk '/pool/ {print $2}')
    [[ -z "$zpool_name" ]] && zpool_name="rpool/data"
    
    echo "${zpool_name}/${subvol_name}"
}

# Wizard Chiavi SSH
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

# Pre-flight checks
preflight_checks() {
    local ip="$1" port="$2" user="$3" pass="$4" pool="$5"
    
    local ssh_cmd="ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"
    [[ -n "$pass" ]] && ssh_cmd="sshpass -p $pass ssh -o StrictHostKeyChecking=no -p $port ${user}@${ip}"

    local free_space
    free_space=$($ssh_cmd "zfs get -H -o value available $pool" 2>/dev/null)
    if [[ -z "$free_space" ]]; then
        msg_box "Errore Pre-flight" "Impossibile verificare lo spazio libero sul pool ZFS '${pool}' del nodo ${ip}."
        return 1
    fi

    return 0
}

# Funzione per riscrivere e caricare il file di configurazione
rewrite_and_upload_conf() {
    local src_vmid="$1" target_vmid="$2" target_storage="$3" ip="$4" port="$5" user="$6" pass="$7"
    local local_conf="/etc/pve/lxc/${src_vmid}.conf"
    local temp_conf="/tmp/${target_vmid}_target.conf"

    cp "$local_conf" "$temp_conf"

    local src_storage
    src_storage=$(grep -E "^rootfs:" "$temp_conf" | awk '{print $2}' | cut -d':' -f1)

    if [[ -n "$src_storage" && "$src_storage" != "$target_storage" ]]; then
        sed -i "s/$src_storage:/$target_storage:/g" "$temp_conf"
    fi

    if [[ "$src_vmid" != "$target_vmid" ]]; then
        sed -i "s/subvol-${src_vmid}-disk-/subvol-${target_vmid}-disk-/g" "$temp_conf"
    fi

    local scp_cmd="scp -P $port -o StrictHostKeyChecking=no"
    local ssh_exec="ssh -p $port -o StrictHostKeyChecking=no ${user}@${ip}"
    if [[ -n "$pass" ]]; then
        scp_cmd="sshpass -p $pass scp -P $port -o StrictHostKeyChecking=no"
        ssh_exec="sshpass -p $pass ssh -p $port -o StrictHostKeyChecking=no ${user}@${ip}"
    fi

    $ssh_exec "[ -f /etc/pve/lxc/${target_vmid}.conf ] && cp /etc/pve/lxc/${target_vmid}.conf /etc/pve/lxc/${target_vmid}.conf.bak" 2>/dev/null || true
    $scp_cmd "$temp_conf" "${user}@${ip}:/etc/pve/lxc/${target_vmid}.conf"
    rm -f "$temp_conf"
}

# Dashboard con due aree separate: Avanzamento (Top) e Log Esteso (Bottom)
run_sync_with_dual_dashboard() {
    local src_vmid="$1" target_vmid="$2" target_node="$3" target_port="$4" ssh_user="$5" ssh_pass="$6" target_zfs_pool="$7" job_type="$8" job_name="$9" selected_storage="${10}" post_action="${11}"

    local src_dataset
    src_dataset=$(get_source_zfs_dataset "$src_vmid")
    
    local total_bytes=0
    if zfs list "$src_dataset" &>/dev/null; then
        total_bytes=$(zfs get -H -o value used "$src_dataset" | numfmt --from=auto)
    fi
    [[ $total_bytes -eq 0 ]] && total_bytes=1073741824

    local log_file="/tmp/pve_sync_${src_vmid}.log"
    > "$log_file"

    if [[ "$job_type" == "sync" ]]; then
        pve-zsync sync --source "$src_vmid" --dest "${target_node}:${target_zfs_pool}" --name "$job_name" --maxsnap 2 --verbose >> "$log_file" 2>&1 &
    else
        pve-zsync create --source "$src_vmid" --dest "${target_node}:${target_zfs_pool}" --name "$job_name" --schedule hourly --maxsnap 2 --verbose >> "$log_file" 2>&1 &
    fi
    local sync_pid=$!

    local ssh_cmd="ssh -o StrictHostKeyChecking=no -p $target_port ${ssh_user}@${target_node}"
    [[ -n "$ssh_pass" ]] && ssh_cmd="sshpass -p $ssh_pass ssh -o StrictHostKeyChecking=no -p $target_port ${ssh_user}@${target_node}"

    clear
    while kill -0 $sync_pid 2>/dev/null; do
        local written_bytes=0
        local target_dataset="${target_zfs_pool}/subvol-${src_vmid}-disk-0"
        local remote_res
        remote_res=$($ssh_cmd "zfs get -H -o value written $target_dataset" 2>/dev/null)
        if [[ -n "$remote_res" ]]; then
            written_bytes=$(echo "$remote_res" | head -n 1 | numfmt --from=auto 2>/dev/null || echo 0)
        fi

        [[ $written_bytes -gt $total_bytes ]] && written_bytes=$total_bytes
        local percent=$(( written_bytes * 100 / total_bytes ))
        [[ $percent -gt 100 ]] && percent=100

        local written_human=$(numfmt --to=iec $written_bytes 2>/dev/null || echo "$written_bytes B")
        local total_human=$(numfmt --to=iec $total_bytes 2>/dev/null || echo "N/D")

        local bar_len=35
        local filled_len=$(( percent * bar_len / 100 ))
        local bar=""
        for ((i=0; i<filled_len; i++)); do bar+="#"; done
        for ((i=filled_len; i<bar_len; i++)); do bar+="-"; done

        tput cup 0 0
        echo "======================================================================"
        echo "                 PVE-ZSYNC MANAGER - STATO SINCRONIZZAZIONE           "
        echo "======================================================================"
        echo " Container Sorgente: ID $src_vmid  ==> Target: $target_node ($target_vmid)"
        echo " Storage Destinazione: $selected_storage ($target_zfs_pool)"
        echo "----------------------------------------------------------------------"
        echo -e " Avanzamento: [${bar}] ${percent}%"
        echo " Dati Trasferiti:   ${written_human} / ${total_human}"
        echo " Stato:             Sincronizzazione ZFS e polling in corso (agg. ogni 2s)"
        echo "======================================================================"
        echo " LOG ESTESO IN TEMPO REALE (Ultime righe):"
        echo "----------------------------------------------------------------------"
        
        tail -n 10 "$log_file"
        
        sleep 2
    done

    wait $sync_pid
    local sync_status=$?

    if [[ $sync_status -eq 0 ]]; then
        echo ">> Sincronizzazione ZFS completata. Trasferimento configurazione .conf..." >> "$log_file"
        rewrite_and_upload_conf "$src_vmid" "$target_vmid" "$selected_storage" "$target_node" "$target_port" "$ssh_user" "$ssh_pass"

        local ssh_exec="ssh -p $target_port -o StrictHostKeyChecking=no ${ssh_user}@${target_node}"
        [[ -n "$ssh_pass" ]] && ssh_exec="sshpass -p $ssh_pass ssh -p $target_port -o StrictHostKeyChecking=no ${ssh_user}@${target_node}"

        if [[ "$post_action" == "switch" || "$post_action" == "shutdown_src" ]]; then
            pct stop "$src_vmid" --skiplock 1 2>/dev/null || true
        fi

        if [[ "$post_action" == "switch" ]]; then
            $ssh_exec "pct start $target_vmid" 2>/dev/null || true
        fi

        send_notifications "Sincronizzazione completata" "Container ID $src_vmid sincronizzato con successo sul nodo $target_node."
        msg_box "Completato" "Procedura di sincronizzazione e adeguamento dello storage eseguita con successo!"
    else
        msg_box "Errore" "La sincronizzazione pve-zsync ha restituito un errore. Controlla il log."
    fi
}

# Sincronizzazione / Clonazione LXC Menu
sync_container_menu() {
    local src_vmid
    src_vmid=$(select_container "Sincronizzazione / Clonazione LXC")
    [[ -z "$src_vmid" ]] && return

    local conn_info
    conn_info=$(get_target_connection)
    [[ -z "$conn_info" ]] && return

    IFS='|' read -r target_node target_port ssh_user ssh_pass <<< "$conn_info"

    local target_vmid
    target_vmid=$(whiptail --title "VMID sul Nodo Target" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci l'ID del container sul nodo target:" 10 55 "$src_vmid" 2>&1 >/dev/tty)
    [[ $? -ne 0 || -z "$target_vmid" ]] && return

    local storages_list
    storages_list=($(get_target_storages "$target_node" "$target_port" "$ssh_user" "$ssh_pass"))

    local selected_storage=""
    if [[ ${#storages_list[@]} -eq 0 ]]; then
        selected_storage=$(whiptail --title "Storage Target Manuale" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Nessun storage rilevato automaticamente. Inserisci il nome dello Storage Proxmox target:" 10 60 "local-zfs" 2>&1 >/dev/tty)
        [[ $? -ne 0 || -z "$selected_storage" ]] && return
    else
        selected_storage=$(whiptail --title "Selezione Storage Proxmox Target" --ok-button "Seleziona" --cancel-button "Indietro" --menu "Seleziona lo Storage Proxmox attivo sul nodo target:" 18 68 8 "${storages_list[@]}" 2>&1 >/dev/tty)
        [[ $? -ne 0 || -z "$selected_storage" ]] && return
    fi

    local target_zfs_pool
    target_zfs_pool=$(get_zfs_pool_from_storage "$target_node" "$target_port" "$ssh_user" "$ssh_pass" "$selected_storage")

    if ! preflight_checks "$target_node" "$target_port" "$ssh_user" "$ssh_pass" "$target_zfs_pool"; then
        return
    fi

    local job_type
    job_type=$(whiptail --title "Modalità pve-zsync" --ok-button "Seleziona" --cancel-button "Indietro" --menu "Seleziona la modalità di sincronizzazione:" 12 55 2 \
        "sync" "Sincronizzazione singola (una tantum)" \
        "create" "Job ricorsivo schedulato" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    local job_name="lxc-sync-${target_vmid}"
    if [[ "$job_type" == "create" ]]; then
        job_name=$(whiptail --title "Nome Job" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci il nome del job pve-zsync:" 10 55 "$job_name" 2>&1 >/dev/tty)
        [[ $? -ne 0 ]] && return
    fi

    local post_action
    post_action=$(whiptail --title "Azioni Post-Sincronizzazione" --ok-button "Seleziona" --cancel-button "Indietro" --menu "Scegli l'azione da eseguire al termine:" 14 62 3 \
        "none" "Nessuna azione automatica" \
        "switch" "Spegni sorgente e avvia target" \
        "shutdown_src" "Spegni solo container sorgente" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    run_sync_with_dual_dashboard "$src_vmid" "$target_vmid" "$target_node" "$target_port" "$ssh_user" "$ssh_pass" "$target_zfs_pool" "$job_type" "$job_name" "$selected_storage" "$post_action"
}

# Gestione ed eliminazione Job pve-zsync
manage_jobs_menu() {
    local jobs_raw
    jobs_raw=$(pve-zsync list 2>/dev/null | tail -n +2)

    if [[ -z "$jobs_raw" ]]; then
        msg_box "Info" "Nessun job pve-zsync trovato sul sistema."
        return
    fi

    local options=()
    while read -r line; do
        [[ -z "$line" ]] && continue
        local jname jsource
        jname=$(echo "$line" | awk '{print $1}')
        jsource=$(echo "$line" | awk '{print $2}')
        options+=("$jname" "Sorgente: $jsource")
    done <<< "$jobs_raw"

    local selected_job
    selected_job=$(whiptail --title "Gestione Job pve-zsync" --ok-button "Seleziona" --cancel-button "Indietro" --menu "Seleziona il job da eliminare:" 15 62 6 "${options[@]}" 2>&1 >/dev/tty)
    [[ $? -ne 0 || -z "$selected_job" ]] && return

    if (whiptail --title "Conferma Eliminazione" --ok-button "Si" --cancel-button "Indietro" --yesno "Sei sicuro di voler eliminare il job '$selected_job'?" 10 55); then
        pve-zsync destroy --name "$selected_job"
        msg_box "Eliminato" "Job '$selected_job' rimosso con successo."
    fi
}

# Configurazione Notifiche
configure_notifications_menu() {
    local token
    token=$(whiptail --title "Telegram Bot Token" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci il Bot Token Telegram (vuoto per disabilitare):" 10 60 "$TELEGRAM_BOT_TOKEN" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    local chatid
    chatid=$(whiptail --title "Telegram Chat ID" --ok-button "Avanti" --cancel-button "Indietro" --inputbox "Inserisci il Chat ID Telegram:" 10 60 "$TELEGRAM_CHAT_ID" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    local email
    email=$(whiptail --title "Email Notifiche" --ok-button "Salva" --cancel-button "Indietro" --inputbox "Inserisci la mail di destinazione:" 10 60 "$NOTIFICATION_EMAIL" 2>&1 >/dev/tty)
    [[ $? -ne 0 ]] && return

    cat << EOF > "$CONFIG_FILE"
TELEGRAM_BOT_TOKEN="${token}"
TELEGRAM_CHAT_ID="${chatid}"
NOTIFICATION_EMAIL="${email}"
EOF

    msg_box "Salvataggio" "Configurazione delle notifiche salvata in $CONFIG_FILE"
}

# Guida e Help Notifiche
help_menu() {
    local help_text="GUIDA PVE-ZSYNC MANAGER

1. SINCRONIZZA / CLONA CONTAINER:
   Consente di trasferire un container LXC verso un nodo remoto con
   una dashboard dedicata in tempo reale (barra di avanzamento percentuale
   e log esteso a polling ogni 2 secondi).
   - Rileva gli storage attivi sul nodo target e mappa il pool ZFS reale.
   - Modifica automaticamente il file .conf per garantire la coerenza con il
     nuovo nome dello storage e del VMID scelto sul target.

2. WIZARD CHIAVI SSH:
   Configura lo scambio di chiavi RSA verso il nodo destinazione per
   abilitare l'accesso automatico passwordless.

3. GESTISCI JOB PVE-ZSYNC:
   Elenca i job di sincronizzazione schedulati attivi ed esegue
   il comando 'pve-zsync destroy' per rimuoverli.

4. CONFRONTA CONFIGURAZIONE:
   Scarica il file .conf remoto via SCP ed esegue un 'diff -u' con
   il file locale per evidenziare le differenze.

--------------------------------------------------
CONFIGURAZIONE BOT TELEGRAM:

1. Apri Telegram e cerca @BotFather.
2. Invia /newbot e segui la procedura per creare il bot.
3. Copia il HTTP API Token fornito.
4. Per trovare il tuo Chat ID, cerca @userinfobot su Telegram,
   inviale /start e copia il tuo 'ID'.
5. Inserisci i dati nel menu 'Configura Notifiche'."

    whiptail --title "Guida & Help" --ok-button "Chiudi" --scrolltext --textbox <(echo "$help_text") 22 72
}

# Confronto Configurazioni
compare_config_menu() {
    local vmid
    vmid=$(select_container "Confronto Configurazioni LXC")
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
        msg_box "Errore" "Impossibile recuperare il file di configurazione dal nodo remoto."
        return
    fi

    local diff_output
    diff_output=$(diff -u "$local_conf" "$temp_remote_conf" || true)
    rm -f "$temp_remote_conf"

    if [[ -z "$diff_output" ]]; then
        msg_box "Confronto" "Le configurazioni sul nodo locale e remoto sono IDENTICHE."
    else
        echo "$diff_output" > /tmp/lxc_diff.txt
        whiptail --title "Differenze Configurazioni (Locale vs Remota)" --ok-button "Chiudi" --textbox /tmp/lxc_diff.txt 22 75
        rm -f /tmp/lxc_diff.txt
    fi
}

# Loop Principale
while true; do
    CHOICE=$(whiptail --title "PVE-Zsync Manager" \
        --ok-button "Seleziona" \
        --cancel-button "Esci" \
        --menu "Gestione Sincronizzazione Container LXC:" 18 68 7 \
        "1" "Sincronizza / Clona Container LXC" \
        "2" "Wizard Chiavi SSH Passwordless" \
        "3" "Gestisci / Elimina Job pve-zsync" \
        "4" "Confronta Configurazione (Sorgente vs Target)" \
        "5" "Configura Notifiche (Telegram & Email)" \
        "6" "Guida e Help" \
        "7" "Esci" 2>&1 >/dev/tty)

    if [[ $? -ne 0 ]]; then
        clear
        exit 0
    fi

    case $CHOICE in
        1) sync_container_menu ;;
        2) ssh_key_wizard ;;
        3) manage_jobs_menu ;;
        4) compare_config_menu ;;
        5) configure_notifications_menu ;;
        6) help_menu ;;
        7) clear; exit 0 ;;
    esac
done

clear
