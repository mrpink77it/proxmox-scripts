#!/bin/bash
# Script per la migrazione e il ridimensionamento di un container LXC tra nodi Proxmox
set -e

# 1. Controllo permessi root e dipendenze
if [ "$EUID" -ne 0 ]; then
  echo "❌ Devi eseguire questo script come root."
  exit 1
fi

echo "Verifica dipendenze (whiptail, sshpass)..."
if ! command -v whiptail &> /dev/null || ! command -v sshpass &> /dev/null; then
    apt-get update -qq
    apt-get install -y whiptail sshpass -qq
fi

# 2. Interfaccia TUI per la raccolta dei dati
FORM_DATA=$(whiptail --title "Migrazione LXC Proxmox" --form "Inserisci i parametri di migrazione. (Usa le frecce per muoverti, TAB per i bottoni):" 22 75 8 \
  "CTID Origine:" 1 1 "" 1 30 15 0 \
  "CTID Destinazione:" 2 1 "" 2 30 15 0 \
  "IP Server Remoto:" 3 1 "" 3 30 20 0 \
  "Porta SSH Remota:" 4 1 "22" 4 30 10 0 \
  "Storage Dest (es. local-lvm):" 5 1 "local-lvm" 5 30 20 0 \
  "Tmp Locale (es /mnt/disk1):" 6 1 "/mnt/tmp_locale" 6 30 25 0 \
  "Tmp Remoto (es /mnt/disk2):" 7 1 "/mnt/tmp_remoto" 7 30 25 0 \
  3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    echo "❌ Operazione annullata dall'utente."
    exit 1
fi

# Estrazione delle variabili dal form
CTID=$(echo "$FORM_DATA" | sed -n '1p')
NEW_CTID=$(echo "$FORM_DATA" | sed -n '2p')
REMOTE_HOST=$(echo "$FORM_DATA" | sed -n '3p')
REMOTE_PORT=$(echo "$FORM_DATA" | sed -n '4p')
REMOTE_STORAGE=$(echo "$FORM_DATA" | sed -n '5p')
LOCAL_TMP_DIR=$(echo "$FORM_DATA" | sed -n '6p')
REMOTE_TMP_DIR=$(echo "$FORM_DATA" | sed -n '7p')

# Validazione dei campi vuoti
if [ -z "$CTID" ] || [ -z "$NEW_CTID" ] || [ -z "$REMOTE_HOST" ] || [ -z "$LOCAL_TMP_DIR" ] || [ -z "$REMOTE_TMP_DIR" ]; then
    echo "❌ Tutti i campi sono obbligatori!"
    exit 1
fi

# Richiesta sicura della password (non in chiaro)
REMOTE_PASS=$(whiptail --title "Autenticazione SSH" --passwordbox "Inserisci la password di root per il server remoto ($REMOTE_HOST):" 10 65 3>&1 1>&2 2>&3)
if [ $? -ne 0 ]; then
    echo "❌ Operazione annullata."
    exit 1
fi

# Esporta la password per usarla con sshpass
export SSHPASS="$REMOTE_PASS"
SSH_CMD="sshpass -e ssh -o StrictHostKeyChecking=no -p $REMOTE_PORT root@$REMOTE_HOST"
SCP_CMD="sshpass -e scp -o StrictHostKeyChecking=no -P $REMOTE_PORT"

echo ""
echo "=========================================================="
echo "🚀 INIZIO PROCEDURA DI MIGRAZIONE LXC $CTID -> $NEW_CTID"
echo "=========================================================="

# 3. Calcolo dello spazio effettivamente occupato dai dati
echo "⏳ [1/5] Calcolo delle dimensioni del contenuto originale..."
IS_RUNNING=$(pct status $CTID | grep -c "running")

if [ "$IS_RUNNING" -eq 1 ]; then
    # Se è acceso, leggiamo lo spazio usato direttamente da dentro
    USED_KB=$(pct exec $CTID -- df -k / | awk 'NR==2 {print $3}')
else
    # Se è spento, montiamo il disco per leggerlo
    echo "   (Il container è spento. Montaggio temporaneo del disco in corso...)"
    pct mount $CTID > /dev/null 2>&1
    USED_KB=$(df -k /var/lib/lxc/$CTID/rootfs | awk 'NR==2 {print $3}')
    pct unmount $CTID > /dev/null 2>&1
fi

# Converte in GB arrotondando per eccesso e aggiunge i 5GB richiesti
USED_GB=$(awk "BEGIN {print int(($USED_KB/1048576) + 0.999)}")
NEW_SIZE_GB=$((USED_GB + 5))

echo "   ✅ Spazio contenuto attuale: ~${USED_GB}GB"
echo "   ✅ Il nuovo disco remoto sarà dimensionato a: ${NEW_SIZE_GB}GB"

# 4. Creazione del Backup
echo "⏳ [2/5] Creazione del backup (snapshot) in $LOCAL_TMP_DIR..."
mkdir -p "$LOCAL_TMP_DIR"
vzdump $CTID --mode snapshot --compress zstd --dumpdir "$LOCAL_TMP_DIR"

BACKUP_FILE=$(ls -t $LOCAL_TMP_DIR/vzdump-lxc-$CTID-*.tar.zst | head -n 1)
FILE_NAME=$(basename "$BACKUP_FILE")

# 5. Trasferimento
echo "⏳ [3/5] Preparazione cartella remota e trasferimento file via SCP..."
$SSH_CMD "mkdir -p $REMOTE_TMP_DIR"
$SCP_CMD "$BACKUP_FILE" "root@$REMOTE_HOST:$REMOTE_TMP_DIR/"

# 6. Ripristino (con ridimensionamento automatico)
echo "⏳ [4/5] Ripristino del container come ID $NEW_CTID sul server remoto..."
$SSH_CMD "pct restore $NEW_CTID $REMOTE_TMP_DIR/$FILE_NAME --rootfs $REMOTE_STORAGE:${NEW_SIZE_GB}G"

# 7. Pulizia
echo "⏳ [5/5] Pulizia dei file temporanei..."
rm -f "$BACKUP_FILE"
$SSH_CMD "rm -f $REMOTE_TMP_DIR/$FILE_NAME"

echo "=========================================================="
echo "🎉 MIGRAZIONE COMPLETATA CON SUCCESSO!"
echo "Il container $NEW_CTID è pronto su $REMOTE_HOST con disco da ${NEW_SIZE_GB}GB."
echo "=========================================================="
