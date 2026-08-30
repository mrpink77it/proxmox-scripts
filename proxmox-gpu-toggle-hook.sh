#!/usr/bin/env bash
# ==============================================================================
# Proxmox GPU Toggle (Hook Script + Auto-Installer) v1.2.0
# Automatizza VFIO, ripristino e protezione dei container di sistema (Whitelist)
# ==============================================================================

set -euo pipefail

VERSION="1.2.0"
TARGET_DIR="/var/lib/vz/snippets"
TARGET_FILE="$TARGET_DIR/proxmox-gpu-toggle.sh"

# ==============================================================================
# 1. MODALITÀ AUTO-INSTALLAZIONE E AGGIORNAMENTO
# ==============================================================================
# Se riceve parametri diversi da quelli standard di Proxmox, entra in setup
if [ $# -ne 2 ] || ! [[ "$2" =~ ^(pre-start|post-start|pre-stop|post-stop)$ ]]; then
    echo -e "\e[1;36m=== Proxmox GPU Toggle - Setup Automatico v$VERSION ===\e[0m"
    
    # Controllo cartella Snippets e sblocco storage Proxmox
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "[-] Cartella Snippets non trovata. Creazione in $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
        # Abilita esplicitamente gli snippet sullo storage 'local' di Proxmox
        pvesm set local --content images,iso,vztmpl,rootdir,snippets || true
    fi

    SCRIPT_PATH="$(realpath "$0")"
    DO_INSTALL=0

    # Controllo presenza e versione del file in destinazione
    if [ ! -f "$TARGET_FILE" ]; then
        echo -e "[-] Hook script non presente. Procedo all'installazione..."
        DO_INSTALL=1
    else
        # Estrae la versione corrente dello script installato
        TARGET_VERSION=$(grep '^VERSION=' "$TARGET_FILE" | head -n 1 | cut -d'"' -f2 || echo "0.0.0")
        if [ "$VERSION" != "$TARGET_VERSION" ]; then
            echo -e "[-] Trovata versione vecchia ($TARGET_VERSION). Aggiornamento alla v$VERSION in corso..."
            DO_INSTALL=1
        else
            echo -e "[-] Lo script in $TARGET_FILE è già aggiornato alla v$VERSION."
        fi
    fi

    # Copia se stesso e forza i permessi
    if [ $DO_INSTALL -eq 1 ]; then
        if [ "$SCRIPT_PATH" != "$(realpath "$TARGET_FILE")" ]; then
            cp -f "$SCRIPT_PATH" "$TARGET_FILE"
            chmod +x "$TARGET_FILE"
            echo -e "\e[1;32m[+] Script copiato e permessi esecutivi (+x) assegnati con successo.\e[0m"
        else
            chmod +x "$TARGET_FILE"
            echo -e "[-] Stai già eseguendo lo script dalla cartella di destinazione."
        fi
    fi

    # Associazione finale alla Macchina Virtuale
    echo ""
    read -p "Vuoi associare questo hook a una VM ora? (Inserisci il VMID, es. 900, o invio per uscire): " INPUT_VMID
    if [[ -n "$INPUT_VMID" && "$INPUT_VMID" =~ ^[0-9]+$ ]]; then
        if qm status "$INPUT_VMID" >/dev/null 2>&1; then
            qm set "$INPUT_VMID" --hookscript local:snippets/proxmox-gpu-toggle.sh
            echo -e "\e[1;32m[+] Hook script associato correttamente alla VM $INPUT_VMID!\e[0m"
        else
            echo -e "\e[1;31m[!] Errore: La VM $INPUT_VMID non esiste su questo nodo.\e[0m"
        fi
    else
        echo -e "Associazione saltata. Puoi farla in futuro dal terminale."
    fi

    echo -e "\e[1;36m=== Installazione completata. Fine. ===\e[0m"
    exit 0
fi

# ==============================================================================
# 2. INIZIO LOGICA HOOK SCRIPT PROXMOX (Eseguita in background dalla VM)
# ==============================================================================

# Parametri passati automaticamente da Proxmox all'avvio/spegnimento
VMID=$1
PHASE=$2

# --- CONFIGURAZIONE AMBIENTE ---
LXC_TO_MANAGE="ALL"       # "ALL" oppure lista ID es. "101 105"
LXC_EXCLUDE="100 205 210" # Inserisci qui gli ID da NON spegnere mai (es. DNS, Proxy, DB)
LOG_FILE="/var/log/proxmox-gpu-toggle.log"
STATE_FILE="/run/proxmox_gpu_state_vm${VMID}.lock"
# -------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [VM $VMID] [$PHASE] - $1" >> "$LOG_FILE"
}

# Rilevamento dinamico GPU e Audio
GPU_PCI=$(lspci -D -nn | grep -iE 'vga|3d controller' | grep -iE 'nvidia|amd' | head -n 1 | awk '{print $1}')
if [ -z "$GPU_PCI" ]; then
    log "ERRORE CRITICO: Nessuna GPU compatibile rilevata."
    exit 1
fi

BASE_PCI=$(echo "$GPU_PCI" | cut -d'.' -f1)
AUD_PCI=$(lspci -D -nn | grep "$BASE_PCI" | grep -i audio | awk '{print $1}' || echo "")

suspend_lxcs() {
    log "Analisi stato LXC in corso..."
    local active_lxcs=""
    local running_lxcs=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

    for id in $running_lxcs; do
        # 1. Se l'ID è nella lista delle esclusioni, saltalo immediatamente
        if [[ " $LXC_EXCLUDE " =~ " $id " ]]; then
            log "LXC $id ignorato (protetto da LXC_EXCLUDE)."
            continue
        fi

        # 2. Se non è escluso, verifica se deve essere gestito
        if [ "$LXC_TO_MANAGE" == "ALL" ] || [[ " $LXC_TO_MANAGE " =~ " $id " ]]; then
            active_lxcs="$active_lxcs $id"
        fi
    done

    if [ -n "$active_lxcs" ]; then
        echo "$active_lxcs" > "$STATE_FILE"
        for lxc in $active_lxcs; do
            log "Sospensione LXC $lxc per liberare la GPU..."
            pct stop "$lxc" || log "ATTENZIONE: Fallito stop LXC $lxc"
        done
        sleep 2
    else
        > "$STATE_FILE"
        log "Nessun LXC conflittuale in esecuzione (escludendo quelli protetti)."
    fi
}

resume_lxcs() {
    if [ -f "$STATE_FILE" ]; then
        local lxcs_to_start=$(cat "$STATE_FILE")
        for lxc in $lxcs_to_start; do
            log "Ripristino ambiente: Avvio LXC $lxc..."
            pct start "$lxc" || log "ATTENZIONE: Fallito avvio LXC $lxc"
        done
        rm -f "$STATE_FILE"
    else
        log "Nessun file di stato trovato. Nessun LXC da riavviare."
    fi
}

bind_vfio() {
    log "Inizio distacco GPU dall'host ($GPU_PCI)..."
    
    systemctl stop nvidia-persistenced 2>/dev/null || true
    
    if [ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ]; then
        echo -n "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind
    fi
    echo "vfio-pci" > /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    
    if [ -n "$AUD_PCI" ]; then
        if [ -e "/sys/bus/pci/devices/$AUD_PCI/driver" ]; then
            echo -n "$AUD_PCI" > /sys/bus/pci/devices/$AUD_PCI/driver/unbind
        fi
        echo "vfio-pci" > /sys/bus/pci/devices/$AUD_PCI/driver_override
        echo "$AUD_PCI" > /sys/bus/pci/drivers_probe
    fi
    log "GPU assegnata a VFIO con successo."
}

bind_host() {
    log "Inizio ripristino GPU ai driver nativi dell'host..."
    
    if [ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ]; then
        echo -n "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind
    fi
    echo "" > /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    
    if [ -n "$AUD_PCI" ]; then
        if [ -e "/sys/bus/pci/devices/$AUD_PCI/driver" ]; then
            echo -n "$AUD_PCI" > /sys/bus/pci/devices/$AUD_PCI/driver/unbind
        fi
        echo "" > /sys/bus/pci/devices/$AUD_PCI/driver_override
        echo "$AUD_PCI" > /sys/bus/pci/drivers_probe
    fi
    
    modprobe nvidia_uvm || true
    systemctl start nvidia-persistenced 2>/dev/null || true
    
    log "GPU restituita all'host con successo."
}

# ================= ROUTING FASI PROXMOX =================
case "$PHASE" in
    pre-start)
        log "--- RICHIESTA AVVIO VM RICEVUTA ---"
        suspend_lxcs
        bind_vfio
        ;;
    post-start)
        log "La VM è ora in esecuzione."
        ;;
    pre-stop)
        log "--- RICHIESTA SPEGNIMENTO VM RICEVUTA ---"
        ;;
    post-stop)
        bind_host
        resume_lxcs
        log "Ciclo di spegnimento concluso."
        ;;
    *)
        # Ignora avvii manuali spuri passati oltre il blocco di setup
        ;;
esac

exit 0
