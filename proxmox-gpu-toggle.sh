#!/usr/bin/env bash
# ==============================================================================
# Proxmox 9 - Multi-Vendor GPU Passthrough Manager (LXC <-> VM)
# Versione: 1.0.9 (Display Default & Compute Profile per ROM-Bar)
# Supporto: NVIDIA, AMD, INTEL su ZFS + systemd-boot
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GPU_PCI=""
AUD_PCI=""
VENDOR=""
VENDOR_NAME=""
LAST_DUMPED_ROM=""

select_gpu() {
    local IFS=$'\n'
    local gpu_list=($(lspci -nn | grep -iE 'vga|3d controller'))
    
    if [ ${#gpu_list[@]} -eq 0 ]; then
        echo -e "${RED}[ERRORE] Nessuna GPU rilevata nel sistema.${NC}"
        exit 1
    fi

    local menu_options=()
    for gpu in "${gpu_list[@]}"; do
        local pci_id=$(echo "$gpu" | awk '{print $1}')
        local desc=$(echo "$gpu" | cut -d':' -f3- | sed 's/^[ \t]*//' | sed 's/ (rev [0-9a-z]*)//')
        menu_options+=("$pci_id" "$desc")
    done

    local INTRO_MSG="Questo script automatizza l'assegnazione dinamica delle GPU tra i container LXC e le Macchine Virtuali (passthrough VFIO).\n\nScegli quale scheda video desideri gestire:"

    GPU_PCI=$(whiptail --title "Selezione GPU (v1.0.9)" \
        --menu "$INTRO_MSG" 20 100 4 "${menu_options[@]}" 3>&1 1>&2 2>&3)
    
    [ -z "$GPU_PCI" ] && exit 0

    VENDOR=$(lspci -n -s "$GPU_PCI" | awk '{print $3}' | cut -d':' -f1)
    case "$VENDOR" in
        10de) VENDOR_NAME="NVIDIA" ;;
        1002) VENDOR_NAME="AMD" ;;
        8086) VENDOR_NAME="INTEL" ;;
        *)    VENDOR_NAME="UNKNOWN" ;;
    esac

    local base_pci=$(echo "$GPU_PCI" | cut -d'.' -f1)
    AUD_PCI=$(lspci -D -nn | grep "$base_pci" | grep -i audio | awk '{print $1}' || echo "")
    
    if [[ "$GPU_PCI" != *":"*":"* ]]; then GPU_PCI="0000:$GPU_PCI"; fi
    if [[ -n "$AUD_PCI" && "$AUD_PCI" != *":"*":"* ]]; then AUD_PCI="0000:$AUD_PCI"; fi
}

stop_active_lxcs() {
    local running_lxcs=($(pct list | awk 'NR>1 && $2=="running" {print $1, $3}'))
    
    if [ ${#running_lxcs[@]} -eq 0 ]; then
        return 0
    fi

    local checklist_options=()
    for ((i=0; i<${#running_lxcs[@]}; i+=2)); do
        local vmid="${running_lxcs[$i]}"
        local name="${running_lxcs[$i+1]}"
        checklist_options+=("$vmid" "$name" "OFF")
    done

    local selected_lxcs=$(whiptail --title "Spegnimento Container LXC" \
        --checklist "Seleziona i container associati a questa GPU da SPEGNERE prima di sganciarla.\n(Usa SPAZIO per selezionare, INVIO per confermare)" 15 75 5 \
        "${checklist_options[@]}" 3>&1 1>&2 2>&3)

    if [ -n "$selected_lxcs" ]; then
        selected_lxcs=$(echo "$selected_lxcs" | tr -d '"')
        echo -e "${YELLOW}Spegnimento container in corso...${NC}"
        for vmid in $selected_lxcs; do
            pct stop "$vmid" || true
            echo -e "${GREEN}LXC $vmid fermato.${NC}"
        done
        sleep 2
    fi
}

main_menu() {
    select_gpu

    while true; do
        local menu_items=()
        
        if ! grep -q "iommu=pt" /etc/kernel/cmdline; then
            menu_items+=("1" "Configura Host (IOMMU su ZFS/systemd-boot)")
        else
            menu_items+=("1" "[GIÀ CONFIGURATO] Verifica/Ripeti setup IOMMU")
        fi
        
        menu_items+=("2" "Estrai vBIOS dalla scheda video (DUMP ROM)")
        menu_items+=("3" "Crea VM Cloud-Init (Wizard Completo)")
        menu_items+=("4" "ATTIVA VFIO (Assegna $VENDOR_NAME alla VM)")
        menu_items+=("5" "RIPRISTINA DRIVER (Assegna $VENDOR_NAME agli LXC)")
        menu_items+=("6" "Cambia GPU selezionata")
        menu_items+=("7" "Esci dal programma")

        CHOICE=$(whiptail --title "Proxmox 9 GPU Manager (v1.0.9)" \
            --menu "GPU Selezionata: $GPU_PCI ($VENDOR_NAME)\n\nScegli un'operazione dal menu sottostante:" 22 95 7 \
            "${menu_items[@]}" 3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case $CHOICE in
            1) setup_host_iommu ;;
            2) dump_vbios ;;
            3) create_test_vm ;;
            4) bind_vfio ;;
            5) bind_host ;;
            6) select_gpu ;;
            7) break ;;
        esac
    done
}

setup_host_iommu() {
    clear
    echo -e "${GREEN}Verifica configurazione IOMMU su systemd-boot (ZFS)...${NC}"
    local CHANGED=0
    
    if grep -q "Intel" /proc/cpuinfo; then
        IOMMU_FLAG="intel_iommu=on"
    else
        IOMMU_FLAG="amd_iommu=on"
    fi

    CMDLINE_FILE="/etc/kernel/cmdline"
    if ! grep -q "iommu=pt" "$CMDLINE_FILE"; then
        sed -i "\$ s/\$/ $IOMMU_FLAG iommu=pt/" "$CMDLINE_FILE"
        proxmox-boot-tool refresh
        CHANGED=1
    fi

    MODULES_FILE="/etc/modules"
    for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        if ! grep -q "^$mod" "$MODULES_FILE"; then 
            echo "$mod" >> "$MODULES_FILE"
            CHANGED=1
        fi
    done
    
    if [ $CHANGED -eq 1 ]; then
        echo -e "${YELLOW}Applicazione modifiche a initramfs...${NC}"
        update-initramfs -u -k all
        whiptail --title "Riavvio Necessario" --msgbox "L'host è stato appena configurato per IOMMU.\n\nRIAVVIA PROXMOX prima di tentare l'assegnazione tramite VFIO." 10 70
    else
        whiptail --title "IOMMU Già Attivo" --msgbox "L'host Proxmox è già configurato per il passthrough.\n\nNon è necessario alcun riavvio." 10 70
    fi
}

dump_vbios() {
    clear
    LAST_DUMPED_ROM=""
    
    stop_active_lxcs
    
    echo -e "${YELLOW}Preparazione per l'estrazione del vBIOS...${NC}"
    
    if [ "$VENDOR_NAME" == "NVIDIA" ]; then
        systemctl stop nvidia-persistenced 2>/dev/null || true
    fi
    
    if [ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ]; then
        echo -n "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind || true
    fi

    local ROM_NAME="${VENDOR_NAME}_${GPU_PCI##*:}.rom"
    local ROM_PATH="/usr/share/kvm/${ROM_NAME}"
    
    echo -e "${CYAN}Tentativo di lettura hardware in corso...${NC}"
    
    echo 1 > /sys/bus/pci/devices/$GPU_PCI/rom || true
    if cat /sys/bus/pci/devices/$GPU_PCI/rom > "$ROM_PATH" 2>/dev/null; then
        echo 0 > /sys/bus/pci/devices/$GPU_PCI/rom || true
        
        local ROM_SIZE=$(stat -c%s "$ROM_PATH" 2>/dev/null || echo 0)
        
        if [ "$ROM_SIZE" -gt 50000 ]; then
            LAST_DUMPED_ROM="$ROM_NAME"
            whiptail --title "DUMP COMPLETATO" --msgbox "Il vBIOS è stato estratto con successo!\n\nPercorso: $ROM_PATH\nDimensioni: $ROM_SIZE bytes" 12 75
        else
            rm -f "$ROM_PATH"
            whiptail --title "ERRORE DUMP (Shadowed ROM)" --msgbox "L'estrazione ha prodotto un file vuoto o corrotto.\n\nLa ROM primaria è ombreggiata." 10 75
        fi
    else
        echo 0 > /sys/bus/pci/devices/$GPU_PCI/rom || true
        whiptail --title "ERRORE I/O" --msgbox "Impossibile leggere il file ROM." 10 70
    fi
    
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe || true
}

bind_vfio() {
    clear
    
    stop_active_lxcs
    
    if [ "$VENDOR_NAME" == "NVIDIA" ]; then
        systemctl stop nvidia-persistenced 2>/dev/null || true
    fi
    
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
    
    whiptail --title "VFIO Attivo" --msgbox "GPU associata a vfio-pci. Puoi avviare la VM in sicurezza." 10 70
}

bind_host() {
    clear
    echo -e "${YELLOW}Assicurati che la VM collegata a questa GPU sia completamente SPENTA!${NC}"
    read -p "Premi INVIO per continuare, oppure CTRL+C per annullare..."
    
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
    
    if [ "$VENDOR_NAME" == "NVIDIA" ]; then
        modprobe nvidia_uvm || true
        systemctl start nvidia-persistenced 2>/dev/null || true
        /usr/bin/nvidia-smi >/dev/null 2>&1 || true
    fi

    whiptail --title "Ripristino Completato" --msgbox "GPU riassegnata ai driver host nativi. Ora puoi riaccendere i tuoi container LXC." 10 70
}

create_test_vm() {
    local HOST_CORES=$(nproc)
    local HOST_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    
    VMID=$(whiptail --title "ID Macchina Virtuale" --inputbox "Inserisci un ID per la nuova VM (es. 900):" 10 50 "900" 3>&1 1>&2 2>&3)
    [ -z "$VMID" ] && return
    
    VM_CORES=$(whiptail --title "Assegnazione CPU" --inputbox "Host CPU: $HOST_CORES core logici.\nQuanti vCPU vuoi assegnare alla VM?" 12 60 "4" 3>&1 1>&2 2>&3)
    [ -z "$VM_CORES" ] && return

    VM_RAM=$(whiptail --title "Assegnazione RAM" --inputbox "Host RAM: $HOST_RAM_MB MB disponibili.\nQuanta RAM (in MB) vuoi assegnare alla VM?" 12 60 "8192" 3>&1 1>&2 2>&3)
    [ -z "$VM_RAM" ] && return

    local ST_OPTIONS=()
    while read -r st_name st_type; do
        ST_OPTIONS+=("$st_name" "Tipo: $st_type")
    done < <(pvesm status -content images | awk 'NR>1 {print $1, $2}')
    
    if [ ${#ST_OPTIONS[@]} -eq 0 ]; then
        whiptail --title "Errore Storage" --msgbox "Nessuno storage abilitato per le immagini VM trovato." 10 60
        return
    fi

    STORAGE=$(whiptail --title "Selezione Storage Proxmox" --menu "Seleziona lo storage di destinazione per il disco della VM:" 15 70 5 "${ST_OPTIONS[@]}" 3>&1 1>&2 2>&3)
    [ -z "$STORAGE" ] && return

    VM_DISK=$(whiptail --title "Assegnazione Disco" --inputbox "Quanto spazio su disco (in GB) vuoi assegnare?" 12 60 "40" 3>&1 1>&2 2>&3)
    [ -z "$VM_DISK" ] && return

    OS_CHOICE=$(whiptail --title "Sistema Operativo" --menu "Quale sistema operativo vuoi installare tramite Cloud-Init?" 12 70 2 "1" "Ubuntu 24.04 LTS (Noble)" "2" "Debian 13 (Trixie)" 3>&1 1>&2 2>&3)
    [ -z "$OS_CHOICE" ] && return
    
    CI_USER=$(whiptail --title "Utente Cloud-Init" --inputbox "Inserisci il nome utente per l'accesso (es. ubuntu, debian, sysadmin):" 10 60 "sysadmin" 3>&1 1>&2 2>&3)
    [ -z "$CI_USER" ] && return
    
    CI_PASS=$(whiptail --title "Password Cloud-Init" --passwordbox "Inserisci la password per l'utente '$CI_USER':" 10 60 3>&1 1>&2 2>&3)
    [ -z "$CI_PASS" ] && return

    local ROM_FILE=""
    local ROM_CHOICE=$(whiptail --title "Gestione vBIOS (ROM)" --menu "Come vuoi gestire il vBIOS della GPU per questa VM?" 15 80 3 \
        "1" "Nessun file ROM (Lascia gestire a Proxmox nativamente)" \
        "2" "Esegui il DUMP ora e aggancia automaticamente il file estratto" \
        "3" "Inserisci il nome di un file .rom già presente in /usr/share/kvm/" 3>&1 1>&2 2>&3)
    [ -z "$ROM_CHOICE" ] && return

    if [ "$ROM_CHOICE" = "2" ]; then
        dump_vbios
        if [ -n "$LAST_DUMPED_ROM" ]; then
            ROM_FILE="$LAST_DUMPED_ROM"
        else
            whiptail --title "Attenzione" --msgbox "Il dump è fallito. La VM verrà creata SENZA vBIOS personalizzato." 10 70
        fi
    elif [ "$ROM_CHOICE" = "3" ]; then
        local MAN_ROM=$(whiptail --title "Nome vBIOS" --inputbox "Inserisci SOLO IL NOME del file .rom\n(es. vbios.rom):" 12 70 "" 3>&1 1>&2 2>&3)
        if [ -n "$MAN_ROM" ]; then
            ROM_FILE=$(basename "$MAN_ROM")
        fi
    fi

    cd /var/lib/vz/template/iso
    if [ "$OS_CHOICE" = "1" ]; then
        VM_NAME="Ubuntu24-Test"
        IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
        IMG_FILE="noble-server-cloudimg-amd64.img"
    elif [ "$OS_CHOICE" = "2" ]; then
        VM_NAME="Debian13-Test"
        IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
        IMG_FILE="debian-13-genericcloud-amd64.qcow2"
    fi

    echo -e "${GREEN}Scaricamento immagine in corso...${NC}"
    wget -nc -q --show-progress "$IMG_URL" || true

    qm create $VMID --name $VM_NAME --memory $VM_RAM --cores $VM_CORES --net0 virtio,bridge=vmbr0 --machine q35
    qm importdisk $VMID $IMG_FILE $STORAGE
    
    qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID-disk-0
    qm set $VMID --ide2 $STORAGE:cloudinit
    qm set $VMID --boot c --bootdisk scsi0
    qm set $VMID --agent enabled=1
    
    qm set $VMID --ciuser "$CI_USER" --cipassword "$CI_PASS" --ipconfig0 ip=dhcp
    
    SHORT_PCI=$(echo $GPU_PCI | awk -F':' '{print $2":"$3}')
    
    # Profilo Compute (rombar disabilitato, niente x-vga)
    PT_OPTS="$SHORT_PCI,pcie=1,rombar=0"
    
    if [ -n "$ROM_FILE" ]; then
        PT_OPTS="$SHORT_PCI,pcie=1,romfile=$ROM_FILE"
    fi

    qm set $VMID --hostpci0 "$PT_OPTS"
    qm resize $VMID scsi0 "${VM_DISK}G"

    whiptail --title "Creazione VM Completata" --msgbox "La VM $VMID è pronta!\n\n- Credenziali: $CI_USER / [Nascosta]\n- Rete: DHCP Attivo\n\nRicorda di attivare il VFIO (Opzione 4) se non l'hai già fatto, per sganciare la scheda dall'host prima di fare il boot." 15 75
}

main_menu
