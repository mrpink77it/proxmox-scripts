#!/bin/bash
# Script TUI per la migrazione, ridimensionamento e riconfigurazione di un LXC su Proxmox

# Rimuovo 'set -e' per gestire gli errori manualmente e non far crashare la TUI
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
    log "Dipendenze mancanti. Avvio apt-get..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt-get install -yq whiptail sshpass >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log "ERRORE: Fallita l'installazione delle dipendenze."
        echo "❌ Errore nell'installazione dei pacchetti. Leggi $LOG_FILE"
        exit 1
    fi
fi

# Pulizia schermo
clear
log "Avvio STEP 1 (TUI Form)..."

# 2. Interfaccia TUI - STEP 1 (Altezza ridotta a 20 per compatibilità)
FORM_BASE=$(whiptail --title "Migrazione LXC (1/2) - Server e Path" --form "Inserisci i parametri del server (Frecce per muoversi, TAB per i bottoni):" 20 75 7 \
  "CTID Origine:" 1 1 "" 1 30 15 0 \
  "CTID Destinazione:" 2 1 "" 2 30 15 0 \
  "IP Server Remoto:" 3 1 "" 3 30 20 0 \
  "Porta SSH Remota:" 4 1 "22" 4 30 10 0 \
  "Storage Dest (es. local-lvm):" 5 1 "local-lvm" 5 30 20 0 \
  "Tmp Locale (es. /mnt/disk1):" 6 1 "/mnt/tmp_locale" 6 30 25 0 \
  "Tmp Remoto (es. /mnt/disk2):" 7 1 "/mnt/tmp_remoto" 7 30 25 0 \
  3>&1 1>&2 2>&3)

WT_STATUS=$?
log "Uscita TUI Step 1 con codice: $WT_STATUS"

if [ $WT_STATUS -ne 0 ]; then 
    echo "❌ Operazione annullata dall'utente o errore grafico (prova a ingrandire la finestra del terminale)."
    exit 1
fi

CTID=$(echo "$FORM_BASE" | sed -n '1p')
NEW_CTID=$(echo "$FORM_BASE" | sed -n '2p')
REMOTE_HOST=$(echo "$FORM_BASE" | sed -n '3p')
REMOTE_PORT=$(echo "$FORM_BASE" | sed -n '4p')
REMOTE_STORAGE=$(echo "$FORM_BASE" | sed -n '5p')
LOCAL_TMP_DIR=$(echo "$FORM_BASE" | sed -n '6p')
REMOTE_TMP_DIR=$(echo "$FORM_BASE" | sed -n '7p')

if [ -z "$CTID" ] || [ -z "$NEW_CTID" ] || [ -z "$REMOTE_HOST" ]; then
    log "ERRORE: Parametri di base mancanti"
    echo "❌ Parametri di base mancanti!"
    exit 1
fi

log "STEP 1 completato: CTID $CTID -> $NEW_CTID su $REMOTE_HOST"

# 3. Interfaccia TUI - STEP 2
log "Avvio STEP 2 (TUI Form)..."
FORM_HW=$(whiptail --title "Migrazione LXC (2/2) - Risorse e Rete" --form "Configura il container di destinazione:" 20 75 6 \
  "Cores CPU:" 1 1 "2" 1 25 10 0 \
  "RAM (MB):" 2 1 "2048" 2 25 10 0 \
  "Bridge (es. vmbr0):" 3 1 "vmbr0" 3 25 15 0 \
  "IPv4/CIDR (o dhcp):" 4 1 "dhcp" 4 25 20 0 \
  "Gateway IPv4 (opz):" 5 1 "" 5 25 20 0 \
  "Server DNS (opz):" 6 1 "" 6 25 20 0 \
  3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then exit 1; fi

CORES=$(echo "$FORM_HW" | sed -n '1p')
RAM=$(echo "$FORM_HW" | sed -n '2p')
BRIDGE=$(echo "$FORM_HW" | sed -n '3p')
IP=$(echo "$FORM_HW" | sed -n '4p')
GW=$(echo "$FORM_HW" | sed -n '5p')
DNS=$(echo "$FORM_HW" | sed -n '6p')

log "Parametri HW: $CORES Cores, $RAM MB, IP $IP"

# 4. Chiede se avviare il container alla fine
if whiptail --title "Avvio Automatico" --yesno "Vuoi avviare il container automaticamente dopo il ripristino e la configurazione?" 10 60; then
    START_CT="yes"
    log "Scelto avvio automatico a fine operazione."
else
    START_CT="no"
    log "Scelto di NON avviare automaticamente."
fi

# 5. Richiesta sicura della password
REMOTE_PASS=$(whiptail --title "Autenticazione SSH" --passwordbox "Inserisci la password di root per il server remoto ($REMOTE_HOST):" 10 65 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then exit 1; fi

export SSHPASS="$REMOTE_PASS"
SSH_CMD="sshpass -e ssh -o StrictHostKeyChecking=no -p $REMOTE_PORT root@$REMOTE_HOST"
SCP_CMD="sshpass -e scp -o StrictHostKeyChecking=no -P $REMOTE_PORT"

clear
echo "=========================================================="
echo "🚀 INIZIO PROCEDURA DI MIGRAZIONE LXC $CTID -> $NEW_CTID"
echo "📂 I log completi sono disponibili in: $LOG_FILE"
echo "=========================================================="
log "INIZIO PROCESSO DI MIGRAZIONE."

# Calcolo dello spazio
echo "⏳ [1/6] Calcolo delle dimensioni del contenuto originale..."
log "Controllo stato CTID $CTID..."
IS_RUNNING=$(pct status $CTID | grep -c "running" || true)

if [ "$IS_RUNNING" -eq 1 ]; then
    log "Container running, calcolo spazio tramite pct exec..."
    USED_KB=$(pct exec $CTID -- df -k / | awk 'NR==2 {print $3}')
else
    echo "   (Container spento. Montaggio temporaneo del disco in corso...)"
    log "Container spento, avvio pct mount..."
    pct mount $CTID >> "$LOG_FILE" 2>&1
    USED_KB=$(df -k /var/lib/lxc/$CTID/rootfs | awk 'NR==2 {print $3}')
    pct unmount $CTID >> "$LOG_FILE" 2>&1
fi

USED_GB=$(awk "BEGIN {print int(($USED_KB/1048576) + 0.999)}")
NEW_SIZE_GB=$((USED_GB + 5))

echo "   ✅ Spazio contenuto attuale: ~${USED_GB}GB"
echo "   ✅ Il disco di destinazione sarà di: ${NEW_SIZE_GB}GB"
log "Spazio occupato: ${USED_GB}GB. Nuovo disco sarà ${NEW_SIZE_GB}GB."

# Creazione Backup
echo "⏳ [2/6] Creazione del backup (snapshot) in $LOCAL_TMP_DIR..."
log "Creazione directory temporanea $LOCAL_TMP_DIR..."
mkdir -p "$LOCAL_TMP_DIR"

log "Avvio vzdump..."
vzdump $CTID --mode snapshot --compress zstd --dumpdir "$LOCAL_TMP_DIR" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    echo "❌ Errore durante la creazione del backup! Controlla i log."
    log "ERRORE VZDUMP."
    exit 1
fi

BACKUP_FILE=$(ls -t $LOCAL_TMP_DIR/vzdump-lxc-$CTID-*.tar.zst | head -n 1)
FILE_NAME=$(basename "$BACKUP_FILE")
log "Backup completato: $FILE_NAME"

# Trasferimento
echo "⏳ [3/6] Preparazione cartella remota e trasferimento file via SCP..."
log "Creazione dir remota $REMOTE_TMP_DIR tramite SSH..."
$SSH_CMD "mkdir -p $REMOTE_TMP_DIR" >> "$LOG_FILE" 2>&1

log "Avvio trasferimento SCP di $BACKUP_FILE..."
$SCP_CMD "$BACKUP_FILE" "root@$REMOTE_HOST:$REMOTE_TMP_DIR/" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    echo "❌ Errore durante il trasferimento SCP! La password è corretta?"
    log "ERRORE SCP."
    exit 1
fi
log "Trasferimento SCP completato."

# Ripristino
echo "⏳ [4/6] Ripristino del container ID $NEW_CTID (Dimensione: ${NEW_SIZE_GB}G)..."
log "Avvio ripristino remoto con pct restore..."
$SSH_CMD "pct restore $NEW_CTID $REMOTE_TMP_DIR/$FILE_NAME --rootfs $REMOTE_STORAGE:${NEW_SIZE_GB}G --force" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    echo "❌ Errore durante il ripristino sul server remoto!"
    log "ERRORE RIPRISTINO."
    exit 1
fi
log "Ripristino remoto completato."

# Riconfigurazione parametri
echo "⏳ [5/6] Applicazione configurazione Hardware e Rete sul nuovo server..."
NET_CMD="name=eth0,bridge=$BRIDGE,ip=$IP"
if [ -n "$GW" ] && [ "$IP" != "dhcp" ]; then
    NET_CMD="$NET_CMD,gw=$GW"
fi

log "Applicazione impostazioni: Cores $CORES, RAM $RAM, Net $NET_CMD"
$SSH_CMD "pct set $NEW_CTID --cores $CORES --memory $RAM --net0 $NET_CMD" >> "$LOG_FILE" 2>&1

if [ -n "$DNS" ]; then
    $SSH_CMD "pct set $NEW_CTID --nameserver $DNS" >> "$LOG_FILE" 2>&1
fi
log "Configurazione di rete/hardware applicata."

# Pulizia
echo "⏳ [6/6] Pulizia dei file temporanei..."
log "Cancellazione file temporanei locali e remoti..."
rm -f "$BACKUP_FILE"
$SSH_CMD "rm -f $REMOTE_TMP_DIR/$FILE_NAME" >> "$LOG_FILE" 2>&1

echo "=========================================================="
echo "🎉 MIGRAZIONE E CONFIGURAZIONE COMPLETATE!"
echo "Risorse allocate: CPU: $CORES Cores, RAM: ${RAM}MB, Disco: ${NEW_SIZE_GB}GB"
echo "Rete: IP $IP su $BRIDGE"
log "MIGRAZIONE COMPLETATA CON SUCCESSO."

# Avvio automatico
if [ "$START_CT" == "yes" ]; then
    echo "🔄 Avvio del container $NEW_CTID in corso..."
    log "Avvio container remoto..."
    $SSH_CMD "pct start $NEW_CTID" >> "$LOG_FILE" 2>&1
    echo "✅ Container avviato con successo su $REMOTE_HOST."
else
    echo "⏸️ Il container è pronto ma è rimasto spento come richiesto."
fi
echo "=========================================================="
log "--- Fine sessione ---"
