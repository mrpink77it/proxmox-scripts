#!/usr/bin/env bash
# ==============================================================================
# Proxmox GPU Toggle (Hook Script + Auto-Installer) v1.3.0
# Automatizza VFIO, protezione container (LXC) e fix automatico gruppi IOMMU
# ==============================================================================

set -euo pipefail

VERSION="1.3.0"
TARGET_DIR="/var/lib/vz/snippets"
TARGET_FILE="$TARGET_DIR/proxmox-gpu-toggle.sh"

# ==============================================================================
# 1. MODALITÀ AUTO-INSTALLAZIONE E AGGIORNAMENTO
# ==============================================================================
if [ $# -ne 2 ] || ! [[ "$2" =~ ^(pre-start|post-start|pre-stop|post-stop)$ ]]; then
    echo -e "\e[1;36m=== Proxmox GPU Toggle - Setup Automatico v$VERSION ===\e[0m"
    
    # --- 1.1 Preparazione e Copia Script ---
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "[-] Cartella Snippets non trovata. Creazione in $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
        pvesm set local --content images,iso,vztmpl,rootdir,snippets || true
    fi

    SCRIPT_PATH="$(realpath "$0")"
    if [ ! -f "$TARGET_FILE" ] || [ "$(grep '^VERSION=' "$TARGET_FILE" | head -n 1 | cut -d'"' -f2 || echo "0.0.0")" != "$VERSION" ]; then
        if [ "$SCRIPT_PATH" != "$(realpath "$TARGET_FILE")" ]; then
            cp -f "$SCRIPT_PATH" "$TARGET_FILE"
            chmod +x "$TARGET_FILE"
            echo -e "\e[1;32m[+] Script installato/aggiornato con successo.\e[0m"
        fi
    else
        echo -e "[-] Script già aggiornato alla v$VERSION."
    fi

    # --- 1.2 Controllo e Fix Isolamento IOMMU ---
    echo -e "\n[-] Controllo isolamento IOMMU della GPU..."
    GPU_PCI=$(lspci -D -nn | grep -iE 'vga|3d controller' | grep -iE 'nvidia|amd' | head -n 1 | awk '{print $1}' || echo "")
    
    if [ -n "$GPU_PCI" ]; then
        IOMMU_GROUP=$(find /sys/kernel/iommu_groups/ -type l -name "*$GPU_PCI*" | grep -Eo '[0-9]+' | tail -n 1 || echo "")
        
        if [ -n "$IOMMU_GROUP" ]; then
            BASE_PCI=$(echo "$GPU_PCI" | cut -d'.' -f1)
            BAD_ISOLATION=0
            
            for dev in $(ls /sys/kernel/iommu_groups/$IOMMU_GROUP/devices/); do
                if [[ ! "$dev" == *"$BASE_PCI"* ]]; then
                    BAD_ISOLATION=1
                    break
                fi
            done
            
            if [ $BAD_ISOLATION -eq 1 ]; then
                echo -e "\e[1;33m[!] Isolamento IOMMU imperfetto rilevato nel gruppo $IOMMU_GROUP.\e[0m"
                echo -e "[-] Applicazione automatica della patch PCIe ACS Override..."
                
                MODIFIED=0
                # ZFS / systemd-boot
                if [ -f /etc/kernel/cmdline ] && ! grep -q "pcie_acs_override" /etc/kernel/cmdline; then
                    sed -i 's/$/ pcie_acs_override=downstream,multifunction/' /etc/kernel/cmdline
                    MODIFIED=1
                fi
                # LVM / GRUB
                if [ -f /etc/default/grub ] && ! grep -q "pcie_acs_override" /etc/default/grub; then
                    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="pcie_acs_override=downstream,multifunction /' /etc/default/grub
                    MODIFIED=1
                fi
                
                if [ $MODIFIED -eq 1 ]; then
                    echo -e "[-] Aggiornamento del bootloader in corso..."
                    proxmox-boot-tool refresh >/dev/null 2>&1 || update-grub >/dev/null 2>&1
                    echo -e "\e[1;32m[+] Patch applicata con successo.\e[0m"
                    
                    read -p "    [?] È necessario riavviare il nodo per dividere i gruppi IOMMU. Riavviare ORA? (s/N): " REBOOT_ANS
                    if [[ "$REBOOT_ANS" =~ ^[Ss]$ ]]; then
                        echo -e "[-] Riavvio in corso..."
                        reboot
                        exit 0
                    fi
                else
                    echo -e "[-] Patch già presente, ma i gruppi non sono isolati. Esegui un riavvio se non lo hai ancora fatto."
                fi
            else
                echo -e "\e[1;32m[+] Isolamento IOMMU perfetto. Nessun fix necessario.\e[0m"
            fi
        else
            echo -e "[-] IOMMU non sembra abilitato (intel_iommu=on o amd_iommu=on mancante)."
        fi
    fi

    # --- 1.3 Associazione alla VM ---
    echo ""
    read -p "Vuoi associare questo hook a una VM ora? (Inserisci il VMID, es. 900, o invio per uscire): " INPUT_VMID
    if [[ -n "$INPUT_VMID" && "$INPUT_VMID" =~ ^[0-9]+$ ]]; then
        if qm status "$INPUT_VMID" >/dev/null 2>&1; then
            qm set "$INPUT_VMID" --hookscript local:snippets/proxmox-gpu-toggle.sh
            echo -e "\e[1;32m[+] Hook script associato correttamente alla VM $INPUT_VMID!\e[0m"
        else
            echo -e "\e[1;31m[!] Errore: La VM $INPUT_VMID non esiste.\e[0m"
        fi
    fi

    echo -e "\e[1;36m=== Setup Completato. ===\e[0m"
    exit 0
fi

# ==============================================================================
# 2. INIZIO LOGICA HOOK SCRIPT PROXMOX (Eseguita in background dalla VM)
# ==============================================================================

VMID=$1
PHASE=$2

# --- CONFIGURAZIONE AMBIENTE ---
LXC_TO_MANAGE="ALL"
LXC_EXCLUDE="100 205 210"
LOG_FILE="/var/log/proxmox-gpu-toggle.log"
STATE_FILE="/run/proxmox_gpu_state_vm${VMID}.lock"
# -------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [VM $VMID] [$PHASE] - $1" >> "$LOG_FILE"
}

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
        if [[ " $LXC_EXCLUDE " =~ " $id " ]]; then
            log "LXC $id ignorato (protetto da LXC_EXCLUDE)."
            continue
        fi

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
        ;;
esac

exit 0#!/usr/bin/env bash
# ==============================================================================
# Proxmox GPU Toggle (Hook Script + Auto-Installer) v1.3.0
# Automatizza VFIO, protezione container (LXC) e fix automatico gruppi IOMMU
# ==============================================================================

set -euo pipefail

VERSION="1.3.0"
TARGET_DIR="/var/lib/vz/snippets"
TARGET_FILE="$TARGET_DIR/proxmox-gpu-toggle.sh"

# ==============================================================================
# 1. MODALITÀ AUTO-INSTALLAZIONE E AGGIORNAMENTO
# ==============================================================================
if [ $# -ne 2 ] || ! [[ "$2" =~ ^(pre-start|post-start|pre-stop|post-stop)$ ]]; then
    echo -e "\e[1;36m=== Proxmox GPU Toggle - Setup Automatico v$VERSION ===\e[0m"
    
    # --- 1.1 Preparazione e Copia Script ---
    if [ ! -d "$TARGET_DIR" ]; then
        echo -e "[-] Cartella Snippets non trovata. Creazione in $TARGET_DIR..."
        mkdir -p "$TARGET_DIR"
        pvesm set local --content images,iso,vztmpl,rootdir,snippets || true
    fi

    SCRIPT_PATH="$(realpath "$0")"
    if [ ! -f "$TARGET_FILE" ] || [ "$(grep '^VERSION=' "$TARGET_FILE" | head -n 1 | cut -d'"' -f2 || echo "0.0.0")" != "$VERSION" ]; then
        if [ "$SCRIPT_PATH" != "$(realpath "$TARGET_FILE")" ]; then
            cp -f "$SCRIPT_PATH" "$TARGET_FILE"
            chmod +x "$TARGET_FILE"
            echo -e "\e[1;32m[+] Script installato/aggiornato con successo.\e[0m"
        fi
    else
        echo -e "[-] Script già aggiornato alla v$VERSION."
    fi

    # --- 1.2 Controllo e Fix Isolamento IOMMU ---
    echo -e "\n[-] Controllo isolamento IOMMU della GPU..."
    GPU_PCI=$(lspci -D -nn | grep -iE 'vga|3d controller' | grep -iE 'nvidia|amd' | head -n 1 | awk '{print $1}' || echo "")
    
    if [ -n "$GPU_PCI" ]; then
        IOMMU_GROUP=$(find /sys/kernel/iommu_groups/ -type l -name "*$GPU_PCI*" | grep -Eo '[0-9]+' | tail -n 1 || echo "")
        
        if [ -n "$IOMMU_GROUP" ]; then
            BASE_PCI=$(echo "$GPU_PCI" | cut -d'.' -f1)
            BAD_ISOLATION=0
            
            for dev in $(ls /sys/kernel/iommu_groups/$IOMMU_GROUP/devices/); do
                if [[ ! "$dev" == *"$BASE_PCI"* ]]; then
                    BAD_ISOLATION=1
                    break
                fi
            done
            
            if [ $BAD_ISOLATION -eq 1 ]; then
                echo -e "\e[1;33m[!] Isolamento IOMMU imperfetto rilevato nel gruppo $IOMMU_GROUP.\e[0m"
                echo -e "[-] Applicazione automatica della patch PCIe ACS Override..."
                
                MODIFIED=0
                # ZFS / systemd-boot
                if [ -f /etc/kernel/cmdline ] && ! grep -q "pcie_acs_override" /etc/kernel/cmdline; then
                    sed -i 's/$/ pcie_acs_override=downstream,multifunction/' /etc/kernel/cmdline
                    MODIFIED=1
                fi
                # LVM / GRUB
                if [ -f /etc/default/grub ] && ! grep -q "pcie_acs_override" /etc/default/grub; then
                    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="pcie_acs_override=downstream,multifunction /' /etc/default/grub
                    MODIFIED=1
                fi
                
                if [ $MODIFIED -eq 1 ]; then
                    echo -e "[-] Aggiornamento del bootloader in corso..."
                    proxmox-boot-tool refresh >/dev/null 2>&1 || update-grub >/dev/null 2>&1
                    echo -e "\e[1;32m[+] Patch applicata con successo.\e[0m"
                    
                    read -p "    [?] È necessario riavviare il nodo per dividere i gruppi IOMMU. Riavviare ORA? (s/N): " REBOOT_ANS
                    if [[ "$REBOOT_ANS" =~ ^[Ss]$ ]]; then
                        echo -e "[-] Riavvio in corso..."
                        reboot
                        exit 0
                    fi
                else
                    echo -e "[-] Patch già presente, ma i gruppi non sono isolati. Esegui un riavvio se non lo hai ancora fatto."
                fi
            else
                echo -e "\e[1;32m[+] Isolamento IOMMU perfetto. Nessun fix necessario.\e[0m"
            fi
        else
            echo -e "[-] IOMMU non sembra abilitato (intel_iommu=on o amd_iommu=on mancante)."
        fi
    fi

    # --- 1.3 Associazione alla VM ---
    echo ""
    read -p "Vuoi associare questo hook a una VM ora? (Inserisci il VMID, es. 900, o invio per uscire): " INPUT_VMID
    if [[ -n "$INPUT_VMID" && "$INPUT_VMID" =~ ^[0-9]+$ ]]; then
        if qm status "$INPUT_VMID" >/dev/null 2>&1; then
            qm set "$INPUT_VMID" --hookscript local:snippets/proxmox-gpu-toggle.sh
            echo -e "\e[1;32m[+] Hook script associato correttamente alla VM $INPUT_VMID!\e[0m"
        else
            echo -e "\e[1;31m[!] Errore: La VM $INPUT_VMID non esiste.\e[0m"
        fi
    fi

    echo -e "\e[1;36m=== Setup Completato. ===\e[0m"
    exit 0
fi

# ==============================================================================
# 2. INIZIO LOGICA HOOK SCRIPT PROXMOX (Eseguita in background dalla VM)
# ==============================================================================

VMID=$1
PHASE=$2

# --- CONFIGURAZIONE AMBIENTE ---
LXC_TO_MANAGE="ALL"
LXC_EXCLUDE="100 205 210"
LOG_FILE="/var/log/proxmox-gpu-toggle.log"
STATE_FILE="/run/proxmox_gpu_state_vm${VMID}.lock"
# -------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [VM $VMID] [$PHASE] - $1" >> "$LOG_FILE"
}

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
        if [[ " $LXC_EXCLUDE " =~ " $id " ]]; then
            log "LXC $id ignorato (protetto da LXC_EXCLUDE)."
            continue
        fi

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
        ;;
esac

exit 0
