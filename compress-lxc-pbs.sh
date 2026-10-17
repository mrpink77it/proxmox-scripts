#!/usr/bin/env bash

if [ "$EUID" -ne 0 ]; then
    echo "Errore: questo script deve essere eseguito come root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/lxc_migration.log"

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
}

log_msg "=== Avvio script di migrazione LXC (PBS Only) ==="

MISSING_PACKAGES=()
for cmd in whiptail jq pct pvesm; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_PACKAGES+=("$cmd")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log_msg "Pacchetti mancanti rilevati: ${MISSING_PACKAGES[*]}. Installazione in corso..."
    apt-get update -y && apt-get install -y whiptail jq >> "$LOG_FILE" 2>&1
fi

# 1. Selezione Container Sorgente
containers=$(pct list | awk 'NR>1 {print $1, "ID:"$1"-Status:"$2"-Name:"$3}')
if [ -z "$containers" ]; then
    log_msg "Errore: Nessun container LXC trovato sul nodo."
    whiptail --title "Errore" --msgbox "Nessun container LXC trovato su questo nodo." 10 40
    exit 1
fi

lxc_list=()
while read -r id status name; do
    lxc_list+=("$id" "$name ($status)")
done < <(pct list | awk 'NR>1 {print $1, $2, $3}')

SRC_ID=$(whiptail --title "Backup & Restore LXC - Sorgente" --menu "Seleziona il container LXC sorgente:" 20 60 10 \
    "${lxc_list[@]}" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && log_msg "Operazione annullata dall'utente." && exit 0

log_msg "Container sorgente selezionato: $SRC_ID"

# 2. Inserimento ID Destinazione
find_free_id() {
    local id=100
    while pct status "$id" &>/dev/null || [ -d "/etc/pve/lxc/$id.conf" ]; do
        ((id++))
    done
    echo "$id"
}

DEFAULT_DEST_ID=$(find_free_id)
DEST_ID=$(whiptail --title "ID Destinazione" --inputbox "Inserisci il numero ID per il nuovo LXC destinazione:" 10 50 "$DEFAULT_DEST_ID" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && log_msg "Operazione annullata dall'utente." && exit 0

log_msg "ID destinazione impostato: $DEST_ID"

# 3. Selezione Storage Temporaneo (ESCLUSIVAMENTE PBS)
pbs_storages=$(pvesm status | awk '$2=="pbs" {print $1}')
if [ -z "$pbs_storages" ]; then
    log_msg "Errore: Nessun Proxmox Backup Server (PBS) configurato su questo nodo."
    whiptail --title "Errore" --msgbox "Nessun Proxmox Backup Server (PBS) trovato.\nQuesto script richiede almeno uno storage PBS configurato." 12 50
    exit 1
fi

pbs_list=()
while read -r store; do
    pbs_list+=("$store" "Proxmox Backup Server")
done < <(pvesm status | awk '$2=="pbs" {print $1}')

TMP_STORAGE=$(whiptail --title "Storage Temporaneo (PBS)" --menu "Seleziona il server PBS di destinazione per il backup:" 20 60 10 \
    "${pbs_list[@]}" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && log_msg "Operazione annullata dall'utente." && exit 0

log_msg "Storage PBS selezionato: $TMP_STORAGE"

# 4. Selezione Storage Destinazione Finale per il Restore
all_storages=$(pvesm status -content images,rootdir | awk 'NR>1 {print $1, $2}')
if [ -z "$all_storages" ]; then
    log_msg "Errore: Nessuno storage di destinazione valido trovato."
    whiptail --title "Errore" --msgbox "Nessuno storage valido trovato per il restore." 10 40
    exit 1
fi

dest_storage_list=()
while read -r store type; do
    dest_storage_list+=("$store" "$type")
done < <(pvesm status -content images,rootdir | awk 'NR>1 {print $1, $2}')

DEST_STORAGE=$(whiptail --title "Storage Destinazione Restore" --menu "Seleziona lo storage finale per il nuovo LXC:" 20 60 10 \
    "${dest_storage_list[@]}" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && log_msg "Operazione annullata dall'utente." && exit 0

log_msg "Storage destinazione selezionato: $DEST_STORAGE"

# 5. Calcolo reale dello spazio occupato (Avvio temporaneo se spento)
get_container_size() {
    local vmid="$1"
    local initial_status
    initial_status=$(pct status "$vmid" | awk '{print $2}')
    local was_stopped=false
    local real_gb=0

    if [ "$initial_status" != "running" ]; then
        was_stopped=true
        log_msg "Avvio temporaneo del container $vmid per calcolare lo spazio reale..."
        pct start "$vmid" >/dev/null 2>&1
        local retry=0
        while ! pct status "$vmid" | grep -q "running" && [ $retry -lt 20 ]; do
            sleep 1
            ((retry++))
        done
    fi

    real_gb=$(pct exec "$vmid" -- df -BG / 2>/dev/null | awk 'NR==2 {print $3}' | tr -d 'G' | grep -oE '^[0-9]+')

    if [ "$was_stopped" = true ]; then
        log_msg "Arresto del container $vmid dopo il calcolo..."
        pct stop "$vmid" >/dev/null 2>&1
    fi

    if [ -z "$real_gb" ] || [ "$real_gb" -le 0 ] 2>/dev/null || ! [[ "$real_gb" =~ ^[0-9]+$ ]]; then
        real_gb=10
    fi

    echo "$real_gb"
}

(
    echo "50"; echo "Analisi dello spazio effettivo del container $SRC_ID in corso..."
    REAL_USED_GB=$(get_container_size "$SRC_ID")
    echo "$REAL_USED_GB" > /tmp/lxc_real_gb_$$
    echo "100"; echo "Completato."
) | whiptail --title "Analisi Spazio" --gauge "Attendere il calcolo dello spazio reale..." 6 50 0

if [ -f /tmp/lxc_real_gb_$$ ]; then
    REAL_USED_GB=$(cat /tmp/lxc_real_gb_$$)
    rm -f /tmp/lxc_real_gb_$$
else
    REAL_USED_GB=10
fi

log_msg "Spazio reale rilevato per LXC $SRC_ID: ${REAL_USED_GB}GB"

OFFSET_GB=$(whiptail --title "Dimensione Disco Destinazione" --inputbox "Spazio reale occupato rilevato: ${REAL_USED_GB}GB.\nInserisci quanti GB AGGIUNTIVI (offset) dedicare al disco di destinazione:" 12 60 "10" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && log_msg "Operazione annullata dall'utente." && exit 0

TOTAL_DEST_GB=$((REAL_USED_GB + OFFSET_GB))
log_msg "Offset impostato: ${OFFSET_GB}GB. Dimensione totale destinazione: ${TOTAL_DEST_GB}GB"

# 6. Richiesta cancellazione container sorgente
if whiptail --title "Eliminazione Sorgente" --yesno "Vuoi eliminare definitivamente il container sorgente ($SRC_ID) al termine della procedura?" 10 60; then
    DELETE_SRC=true
    log_msg "Scelta utente: Eliminazione del container sorgente ABILITATA."
else
    DELETE_SRC=false
    log_msg "Scelta utente: Eliminazione del container sorgente DISABILITATA."
fi

# Riepilogo finale prima dell'esecuzione
whiptail --title "Riepilogo Operazione" --msgbox "Sorgente LXC: $SRC_ID\nDestinazione ID: $DEST_ID\nStorage PBS (Backup): $TMP_STORAGE\nStorage Destinazione: $DEST_STORAGE\nSpazio Reale Sorgente: ${REAL_USED_GB}GB\nOffset Aggiuntivo: ${OFFSET_GB}GB\nDimensione Totale Disco: ${TOTAL_DEST_GB}GB\nElimina Sorgente: $DELETE_SRC" 16 60

# 7. Esecuzione della procedura con PBS
(
    echo "5"; echo "Arresto del container sorgente $SRC_ID..."
    log_msg "Arresto del container sorgente $SRC_ID..."
    pct stop "$SRC_ID" || true

    echo "15"; echo "Rimozione repliche esistenti..."
    log_msg "Rimozione repliche esistenti per $SRC_ID..."
    pvesr delete "$SRC_ID-0" 2>/dev/null || true
    pvesr delete "$SRC_ID-1" 2>/dev/null || true
    pvesr delete "$SRC_ID-2" 2>/dev/null || true

    echo "30"; echo "Invio backup su PBS ($TMP_STORAGE)..."
    log_msg "Avvio backup su PBS $TMP_STORAGE..."
    vzdump "$SRC_ID" --storage "$TMP_STORAGE" --mode snapshot >> "$LOG_FILE" 2>&1 &
    PID_BACKUP=$!

    while kill -0 $PID_BACKUP 2>/dev/null; do
        sleep 2
        echo "55"; echo "Backup su PBS in corso..."
    done
    wait $PID_BACKUP
    log_msg "Backup su PBS completato."

    echo "70"; echo "Attesa e recupero snapshot da PBS..."
    sleep 3 # Breve pausa per consentire l'indicizzazione sul PBS
    
    # Ricerca corretta dello snapshot PBS per container LXC (formato ct/ID/...)
    latest_backup=$(pvesm list "$TMP_STORAGE" --content backup 2>/dev/null | grep -E "ct/$SRC_ID/" | sort -r | head -n 1 | awk '{print $1}')
    
    if [ -z "$latest_backup" ]; then
        # Fallback generico cercando l'ID all'interno della lista
        latest_backup=$(pvesm list "$TMP_STORAGE" --content backup 2>/dev/null | grep -E "$SRC_ID" | sort -r | head -n 1 | awk '{print $1}')
    fi

    if [ -z "$latest_backup" ]; then
        log_msg "Errore critico: Impossibile trovare lo snapshot di backup su PBS."
        echo "Errore: Impossibile trovare lo snapshot di backup su PBS." >&2
        exit 1
    fi

    log_msg "Snapshot PBS individuato: $latest_backup"

    echo "75"; echo "Ripristino container su ID $DEST_ID (disco a ${TOTAL_DEST_GB}GB)..."
    log_msg "Avvio ripristino container su ID $DEST_ID da PBS su storage $DEST_STORAGE con dimensione ${TOTAL_DEST_GB}GB..."
    pct restore "$DEST_ID" "$latest_backup" --rootfs "$DEST_STORAGE:$TOTAL_DEST_GB" -unprivileged >> "$LOG_FILE" 2>&1 &
    PID_RESTORE=$!

    while kill -0 $PID_RESTORE 2>/dev/null; do
        sleep 2
        echo "85"; echo "Ripristino ed estrazione disco in corso..."
    done
    wait $PID_RESTORE
    log_msg "Ripristino completato."

    if [ "$DELETE_SRC" = true ]; then
        echo "90"; echo "Rimozione container sorgente $SRC_ID..."
        log_msg "Eliminazione definitiva del container sorgente $SRC_ID..."
        pct set "$SRC_ID" --protection=0
        pct destroy "$SRC_ID" >> "$LOG_FILE" 2>&1 || true
    fi

    echo "95"; echo "Avvio nuovo container $DEST_ID..."
    log_msg "Avvio del nuovo container $DEST_ID..."
    pct start "$DEST_ID" >> "$LOG_FILE" 2>&1 || true

    echo "100"; echo "Procedura completata con successo!"
    log_msg "=== Procedura completata con successo per LXC $DEST_ID ==="
) | whiptail --title "Elaborazione in corso" --gauge "Attendere il completamento delle operazioni..." 8 60 0

whiptail --title "Successo" --msgbox "Procedura completata con successo!\nContainer $DEST_ID creato correttamente da PBS su $DEST_STORAGE con dimensione ${TOTAL_DEST_GB}GB.\n\nLog salvato in: $LOG_FILE" 12 60
exit 0
