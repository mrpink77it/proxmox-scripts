#!/bin/bash
# Script TUI/CLI per la migrazione e ripristino di container LXC su Proxmox

# Protezione da disconnessioni brutali dell'SSH mentre 'screen' è in esecuzione
trap "" HUP

# File di log
LOG_FILE="/var/log/migrate_lxc.log"
echo "--- Inizio sessione $(date) ---" > "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 1. Controllo permessi root
log "Controllo permessi root..."
if [ "$EUID" -ne 0 ]; then
  echo "❌ Devi eseguire questo script come root."
  exit 1
fi

echo "Verifica dipendenze in corso (whiptail, sshpass)..."
log "Verifica installazione dipendenze..."
if ! command -v whiptail &>> "$LOG_FILE" || ! command -v sshpass &>> "$LOG_FILE"; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -yq whiptail sshpass >> "$LOG_FILE" 2>&1
fi

clear
export TERM=xterm-256color
USE_FALLBACK=0

# =======================================================
# FUNZIONE: Navigatore di File (TUI File Picker)
# =======================================================
file_picker() {
    local current_dir="$1"
    [ ! -d "$current_dir" ] && current_dir="/"
    
    while true; do
        shopt -s nullglob
        local dirs=("$current_dir"/*/)
        local files=("$current_dir"/*.tar.zst "$current_dir"/*.tar.gz "$current_dir"/*.tar.lzo)
        shopt -u nullglob
        
        local options=()
        options+=(".." "Cartella Superiore")
        
        for d in "${dirs[@]}"; do
            options+=("$(basename "$d")/" "Cartella")
        done
        for f in "${files[@]}"; do
            options+=("$(basename "$f")" "File Backup")
        done
        
        local selection
        selection=$(whiptail --title "Seleziona File di Backup" --menu "Esplora: $current_dir\nScegli un file o naviga:" 22 75 14 "${options[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            return 1
        fi
        
        if [ "$selection" == ".." ]; then
            if [ "$current_dir" != "/" ]; then
                current_dir=$(dirname "$current_dir")
            fi
        elif [[ "$selection" == */ ]]; then
            current_dir="${current_dir}/${selection%/}"
            current_dir=$(realpath "$current_dir" 2>/dev/null || echo "$current_dir")
        else
            echo "$current_dir/$selection"
            return 0
        fi
    done
}

# =======================================================
# MENU PRINCIPALE
# =======================================================
CHOICE=$(whiptail --title "Proxmox LXC Manager" --menu "Scegli la modalità di esecuzione:" 15 70 2 \
    "1" "Migrazione live: Clona e sposta un LXC locale su nodo remoto" \
    "2" "Ripristino backup: Invia backup esistente a nodo remoto" \
    3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    log "Selezione menu annullata dall'utente."
    echo "Operazione annullata."
    exit 0
fi

# =======================================================
# STEP 1: Parametri di Base
# =======================================================
log "Avvio STEP 1 (Modalità $CHOICE)..."

if [ "$CHOICE" == "1" ]; then
    # -- FORM MIGRAZIONE LIVE --
    FORM_BASE=$(whiptail --title "Migrazione Live (1/2) - Server e Path" --form "Inserisci i parametri di migrazione:" 20 75 7 \
      "CTID Origine:" 1 1 "" 1 30 15 0 \
      "CTID Destinazione:" 2 1 "" 2 30 15 0 \
      "IP Server Remoto:" 3 1 "" 3 30 20 0 \
      "Porta SSH Remota:" 4 1 "22" 4 30 10 0 \
      "Storage Dest (es. local-lvm):" 5 1 "local-lvm" 5 30 20 0 \
      "Tmp Locale (es. /mnt/disk1):" 6 1 "/mnt/tmp_locale" 6 30 25 0 \
      "Tmp Remoto (es. /mnt/disk2):" 7 1 "/mnt/tmp_remoto" 7 30 25 0 \
      3>&1 1>&2 2>&3)
    
    WT_STATUS=$?
    if [ $WT_STATUS -ne 0 ]; then
        log "Form Grafica Opzione 1 fallita o annullata. Attivazione fallback CLI."
        echo "⚠️  Attenzione: Interfaccia grafica non disponibile o annullata."
        echo "👇 Passaggio alla modalità testuale:"
        read -p "CTID Origine: " CTID
        read -p "CTID Destinazione: " NEW_CTID
        read -p "IP Server Remoto: " REMOTE_HOST
        read -p "Porta SSH Remota [22]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-22}
        read -p "Storage Destinazione [local-lvm]: " REMOTE_STORAGE; REMOTE_STORAGE=${REMOTE_STORAGE:-local-lvm}
        read -p "Cartella Tmp Locale [/mnt/tmp_locale]: " LOCAL_TMP_DIR; LOCAL_TMP_DIR=${LOCAL_TMP_DIR:-/mnt/tmp_locale}
        read -p "Cartella Tmp Remota [/mnt/tmp_remoto]: " REMOTE_TMP_DIR; REMOTE_TMP_DIR=${REMOTE_TMP_DIR:-/mnt/tmp_remoto}
        USE_FALLBACK=1
    else
        CTID=$(echo "$FORM_BASE" | sed -n '1p')
        NEW_CTID=$(echo "$FORM_BASE" | sed -n '2p')
        REMOTE_HOST=$(echo "$FORM_BASE" | sed -n '3p')
        REMOTE_PORT=$(echo "$FORM_BASE" | sed -n '4p')
        REMOTE_STORAGE=$(echo "$FORM_BASE" | sed -n '5p')
        LOCAL_TMP_DIR=$(echo "$FORM_BASE" | sed -n '6p')
        REMOTE_TMP_DIR=$(echo "$FORM_BASE" | sed -n '7p')
    fi

elif [ "$CHOICE" == "2" ]; then
    # -- SELEZIONE FILE E FORM RIPRISTINO --
    BACKUP_FILE=$(file_picker "/Storage/tmp")
    if [ -z "$BACKUP_FILE" ]; then 
        log "Nessun file selezionato nel file_picker."
        echo "❌ Nessun file selezionato. Interruzione."
        exit 1
    fi
    log "Backup selezionato: $BACKUP_FILE"
    
    FORM_BASE=$(whiptail --title "Ripristino (1/2) - Server e Path" --form "Configura il ripristino per $(basename "$BACKUP_FILE"):" 19 75 6 \
      "CTID Destinazione:" 1 1 "" 1 32 15 0 \
      "IP Server Remoto:" 2 1 "" 2 32 20 0 \
      "Porta SSH Remota:" 3 1 "22" 3 32 10 0 \
      "Storage Dest (es. local-lvm):" 4 1 "local-lvm" 4 32 20 0 \
      "Tmp Remoto (es. /mnt/tmp):" 5 1 "/mnt/tmp_remoto" 5 32 25 0 \
      "Nuovo Disco GB (vuoto=default):" 6 1 "" 6 32 10 0 \
      3>&1 1>&2 2>&3)
      
    WT_STATUS=$?
    if [ $WT_STATUS -ne 0 ]; then
        log "Form Grafica Opzione 2 fallita o annullata. Attivazione fallback CLI."
        echo "⚠️  Attenzione: Interfaccia grafica non disponibile o annullata."
        echo "👇 Passaggio alla modalità testuale:"
        read -p "CTID Destinazione: " NEW_CTID
        read -p "IP Server Remoto: " REMOTE_HOST
        read -p "Porta SSH Remota [22]: " REMOTE_PORT; REMOTE_PORT=${REMOTE_PORT:-22}
        read -p "Storage Destinazione [local-lvm]: " REMOTE_STORAGE; REMOTE_STORAGE=${REMOTE_STORAGE:-local-lvm}
        read -p "Cartella Tmp Remota [/mnt/tmp_remoto]: " REMOTE_TMP_DIR; REMOTE_TMP_DIR=${REMOTE_TMP_DIR:-/mnt/tmp_remoto}
        read -p "Nuovo Disco GB (lascia vuoto per default): " NEW_SIZE_GB
        USE_FALLBACK=1
    else
        NEW_CTID=$(echo "$FORM_BASE" | sed -n '1p')
        REMOTE_HOST=$(echo "$FORM_BASE" | sed -n '2p')
        REMOTE_PORT=$(echo "$FORM_BASE" | sed -n '3p')
        REMOTE_STORAGE=$(echo "$FORM_BASE" | sed -n '4p')
        REMOTE_TMP_DIR=$(echo "$FORM_BASE" | sed -n '5p')
        NEW_SIZE_GB=$(echo "$FORM_BASE" | sed -n '6p')
    fi
fi

if [ -z "$NEW_CTID" ] || [ -z "$REMOTE_HOST" ]; then
    log "Parametri fondamentali (NEW_CTID o REMOTE_HOST) mancanti."
    echo "❌ Parametri fondamentali mancanti! Interruzione."
    exit 1
fi

# =======================================================
# STEP 2: Risorse e Rete
# =======================================================
log "Avvio STEP 2..."
if [ $USE_FALLBACK -eq 0 ]; then
    FORM_HW=$(whiptail --title "Configurazione (2/2) - Risorse e Rete" --form "Configura risorse e rete remote:" 19 75 6 \
      "Cores CPU:" 1 1 "2" 1 25 10 0 \
      "RAM (MB):" 2 1 "2048" 2 25 10 0 \
      "Bridge (es. vmbr0):" 3 1 "vmbr0" 3 25 15 0 \
      "IPv4/CIDR (o dhcp):" 4 1 "dhcp" 4 25 20 0 \
      "Gateway IPv4 (opz):" 5 1 "" 5 25 20 0 \
      "Server DNS (opz):" 6 1 "" 6 25 20 0 \
      3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then 
        log "Step 2 annullato."
        exit 1
    fi
    CORES=$(echo "$FORM_HW" | sed -n '1p')
    RAM=$(echo "$FORM_HW" | sed -n '2p')
    BRIDGE=$(echo "$FORM_HW" | sed -n '3p')
    IP=$(echo "$FORM_HW" | sed -n '4p')
    GW=$(echo "$FORM_HW" | sed -n '5p')
    DNS=$(echo "$FORM_HW" | sed -n '6p')

    if whiptail --title "Avvio Automatico" --yesno "Vuoi avviare il container automaticamente alla fine?" 10 60; then
        START_CT="yes"
    else
        START_CT="no"
    fi

    REMOTE_PASS=$(whiptail --title "Autenticazione SSH" --passwordbox "Inserisci la password di root per $REMOTE_HOST:" 10 60 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then 
        log "Inserimento password annullato."
        exit 1
    fi
else
    echo "--------------------------------------------------------"
    read -p "Cores CPU [2]: " CORES; CORES=${CORES:-2}
    read -p "RAM (MB) [2048]: " RAM; RAM=${RAM:-2048}
    read -p "Bridge [vmbr0]: " BRIDGE; BRIDGE=${BRIDGE:-vmbr0}
    read -p "IPv4/CIDR (o dhcp) [dhcp]: " IP; IP=${IP:-dhcp}
    read -p "Gateway IPv4 (lascia vuoto se dhcp): " GW
    read -p "Server DNS (lascia vuoto se default): " DNS
    read -p "Avviare il container alla fine? (y/n) [n]: " START_ANS
    if [[ "$START_ANS" =~ ^[Yy]$ ]]; then START_CT="yes"; else START_CT="no"; fi
    
    read -s -p "Password di root per $REMOTE_HOST: " REMOTE_PASS
    echo ""
fi

export SSHPASS="$REMOTE_PASS"
SSH_CMD="sshpass -e ssh -o StrictHostKeyChecking=no -p $REMOTE_PORT root@$REMOTE_HOST"
SCP_CMD="sshpass -e scp -o StrictHostKeyChecking=no -P $REMOTE_PORT"

# =======================================================
# ESECUZIONE
# =======================================================
clear
echo "=========================================================="
if [ "$CHOICE" == "1" ]; then
    echo "🚀 INIZIO MIGRAZIONE LIVE: LXC $CTID -> $NEW_CTID su $REMOTE_HOST"
else
    echo "🚀 INIZIO RIPRISTINO BACKUP -> $NEW_CTID su $REMOTE_HOST"
fi
echo "📂 Log disponibili in: $LOG_FILE"
echo "=========================================================="
log "Inizio operazioni sui dati."

# --- FASE 1 & 2: PREPARAZIONE FILE ---
if [ "$CHOICE" == "1" ]; then
    echo "⏳ [1/6] Calcolo delle dimensioni del contenuto originale..."
    IS_RUNNING=$(pct status $CTID | grep -c "running" || true)

    if [ "$IS_RUNNING" -eq 1 ]; then
        USED_KB=$(pct exec $CTID -- df -k / | awk 'NR==2 {print $3}')
    else
        echo "   (Container spento. Montaggio temporaneo del disco...)"
        pct mount $CTID >> "$LOG_FILE" 2>&1
        USED_KB=$(df -k /var/lib/lxc/$CTID/rootfs | awk 'NR==2 {print $3}')
        pct unmount $CTID >> "$LOG_FILE" 2>&1
    fi

    USED_GB=$(awk "BEGIN {print int(($USED_KB/1048576) + 0.999)}")
    NEW_SIZE_GB=$((USED_GB + 5))
    echo "   ✅ Spazio contenuto: ~${USED_GB}GB. Nuovo disco: ${NEW_SIZE_GB}GB."

    echo "⏳ [2/6] Creazione snapshot backup in $LOCAL_TMP_DIR..."
    mkdir -p "$LOCAL_TMP_DIR"
    vzdump $CTID --mode snapshot --compress zstd --dumpdir "$LOCAL_TMP_DIR" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "Errore durante vzdump."
        echo "❌ Errore durante il backup! Controlla $LOG_FILE."
        exit 1
    fi
    BACKUP_FILE=$(ls -t $LOCAL_TMP_DIR/vzdump-lxc-$CTID-*.tar.zst | head -n 1)
else
    echo "⏳ [1/6 & 2/6] Utilizzo backup esistente selezionato..."
    echo "   ✅ File: $BACKUP_FILE"
fi

FILE_NAME=$(basename "$BACKUP_FILE")

# --- FASE 3: TRASFERIMENTO ---
echo "⏳ [3/6] Trasferimento del backup al nodo remoto via SCP..."
$SSH_CMD "mkdir -p $REMOTE_TMP_DIR" >> "$LOG_FILE" 2>&1
$SCP_CMD "$BACKUP_FILE" "root@$REMOTE_HOST:$REMOTE_TMP_DIR/" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log "Errore durante trasferimento SCP."
    echo "❌ Errore durante il trasferimento SCP! Rete down o password errata?"
    exit 1
fi

# --- FASE 4: RIPRISTINO ---
if [ -n "$NEW_SIZE_GB" ]; then
    echo "⏳ [4/6] Ripristino di $NEW_CTID forzando la dimensione disco a ${NEW_SIZE_GB}GB..."
    $SSH_CMD "pct restore $NEW_CTID $REMOTE_TMP_DIR/$FILE_NAME --rootfs $REMOTE_STORAGE:${NEW_SIZE_GB} --force" >> "$LOG_FILE" 2>&1
else
    echo "⏳ [4/6] Ripristino di $NEW_CTID mantenendo la dimensione originale del disco..."
    $SSH_CMD "pct restore $NEW_CTID $REMOTE_TMP_DIR/$FILE_NAME --storage $REMOTE_STORAGE --force" >> "$LOG_FILE" 2>&1
fi

if [ $? -ne 0 ]; then
    log "Errore durante pct restore sul server remoto."
    echo "❌ Errore durante il ripristino! Controlla $LOG_FILE."
    exit 1
fi

# --- FASE 5: RETE E HARDWARE ---
echo "⏳ [5/6] Applicazione configurazione Hardware e Rete..."
NET_CMD="name=eth0,bridge=$BRIDGE,ip=$IP"
if [ -n "$GW" ] && [ "$IP" != "dhcp" ]; then
    NET_CMD="$NET_CMD,gw=$GW"
fi

$SSH_CMD "pct set $NEW_CTID --cores $CORES --memory $RAM --net0 $NET_CMD" >> "$LOG_FILE" 2>&1
if [ -n "$DNS" ]; then
    $SSH_CMD "pct set $NEW_CTID --nameserver $DNS" >> "$LOG_FILE" 2>&1
fi

# --- FASE 6: PULIZIA ---
echo "⏳ [6/6] Pulizia dei file temporanei..."
$SSH_CMD "rm -f $REMOTE_TMP_DIR/$FILE_NAME" >> "$LOG_FILE" 2>&1
if [ "$CHOICE" == "1" ]; then
    rm -f "$BACKUP_FILE"
fi

echo "=========================================================="
echo "🎉 OPERAZIONE COMPLETATA CON SUCCESSO!"
echo "ID: $NEW_CTID | CPU: $CORES | RAM: ${RAM}MB | IP: $IP"

if [ "$START_CT" == "yes" ]; then
    echo "🔄 Avvio del container $NEW_CTID in corso..."
    $SSH_CMD "pct start $NEW_CTID" >> "$LOG_FILE" 2>&1
    echo "✅ Container avviato su $REMOTE_HOST."
fi
echo "=========================================================="
log "--- Fine sessione con successo ---"
