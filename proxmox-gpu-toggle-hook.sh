#!/usr/bin/env bash
# ==============================================================================
# Proxmox GPU Toggle (Hook Script) v1.0.0
# Automatizza VFIO e il ripristino per Macchine Virtuali con tracciamento stato
# ==============================================================================

set -euo pipefail

# Parametri passati automaticamente da Proxmox all'avvio/spegnimento della VM
VMID=$1
PHASE=$2

# ================= CONFIGURAZIONE =================
# "ALL" (sospende tutti gli LXC attivi) oppure metti gli ID (es. "101 105")
LXC_TO_MANAGE="ALL" 

LOG_FILE="/var/log/proxmox-gpu-toggle.log"
STATE_FILE="/run/proxmox_gpu_state_vm${VMID}.lock"
# ==================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [VM $VMID] [$PHASE] - $1" >> "$LOG_FILE"
}

# Rilevamento dinamico della prima GPU e dell'Audio associato
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
    
    if [ "$LXC_TO_MANAGE" == "ALL" ]; then
        active_lxcs=$(pct list | awk 'NR>1 && $2=="running" {print $1}')
    else
        for id in $LXC_TO_MANAGE; do
            if pct status "$id" | grep -q "running"; then
                active_lxcs="$active_lxcs $id"
            fi
        done
    fi

    if [ -n "$active_lxcs" ]; then
        echo "$active_lxcs" > "$STATE_FILE"
        for lxc in $active_lxcs; do
            log "Sospensione LXC $lxc per liberare la GPU..."
            pct stop "$lxc" || log "ATTENZIONE: Fallito stop LXC $lxc"
        done
        sleep 2
    else
        > "$STATE_FILE"
        log "Nessun LXC conflittuale in esecuzione."
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
        log "Fase non riconosciuta: $PHASE"
        ;;
esac

exit 0
