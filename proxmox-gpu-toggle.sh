#!/usr/bin/env bash
# ==============================================================================
# Proxmox 9 - Multi-Vendor GPU Passthrough Manager (LXC <-> VM)
# Versione: 1.0.1
# Supporto: NVIDIA, AMD, INTEL su ZFS + systemd-boot
# ==============================================================================
# DESCRIZIONE DETTAGLIATA E FUNZIONAMENTO:
# Questo script automatizza l'assegnazione dinamica di una o più GPU tra
# container LXC (driver caricato sull'host) e Macchine Virtuali (passthrough VFIO).
# Evita la blacklist in /etc/modprobe.d/, permettendo lo switch "a caldo"
# senza riavviare l'host Proxmox 9.
#
# ELENCO DELLE FUNZIONI:
# [1] Selezione Dinamica Hardware:
#     - Identifica in automatico le schede VGA/3D e il Vendor (NVIDIA, AMD, Intel).
# [2] Configura Host (IOMMU):
#     - Configura i flag CPU (Intel/AMD) e iommu=pt in /etc/kernel/cmdline (ZFS).
#     - Aggiorna i moduli vfio in /etc/modules e rigenera initramfs.
# [3] Crea VM (Ubuntu 24 / Debian 13):
#     - Scarica l'immagine ufficiale Cloud-Init corrispondente.
#     - Crea la VM su ZFS (8GB RAM, 4 core, 40GB disco).
#     - Configura il passthrough specifico per vendor (es. x-vga=1 per NVIDIA/AMD).
#     - Permette l'inserimento opzionale di un file vBIOS (.rom) presente in /usr/share/kvm/.
# [4] ATTIVA VFIO (Assegna GPU alla VM):
#     - Esegue l'unbind della GPU (e Audio) dal driver nativo (es. nvidia, amdgpu).
#     - Associa la scheda al driver vfio-pci tramite driver_override.
# [5] RIPRISTINA DRIVER (Assegna GPU agli LXC):
#     - Rimuove l'override vfio-pci.
#     - Ricarica automaticamente i moduli host (nvidia, amdgpu, i915).
#     - Se NVIDIA, riavvia persistenced e ricrea i device node in /dev/nvidia*.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Variabili globali popolate dalla selezione
GPU_PCI=""
AUD_PCI=""
VENDOR=""
VENDOR_NAME=""

select_gpu() {
    # Trova tutti i dispositivi VGA e 3D Controller
    local IFS=$'\n'
    local gpu_list=($(lspci -nn | grep -iE 'vga|3d controller'))
    
    if [ ${#gpu_list[@]} -eq 0 ]; then
        echo -e "${RED}[ERRORE] Nessuna GPU rilevata nel sistema.${NC}"
        exit 1
    fi

    local menu_options=()
    for gpu in "${gpu_list[@]}"; do
        local pci_id=$(echo "$gpu" | awk '{print $1}')
        # Estrae la descrizione, rimuove gli spazi iniziali e taglia la stringa della revisione per fare spazio
        local desc=$(echo "$gpu" | cut -d':' -f3- | sed 's/^[ \t]*//' | sed 's/ (rev [0-9a-z]*)//')
        menu_options+=("$pci_id" "$desc")
    done

    # Descrizione introduttiva mostrata sopra la selezione
    local INTRO_MSG="Questo script automatizza l'assegnazione dinamica delle GPU tra i container LXC (usando i driver dell'host) e le Macchine Virtuali (usando il passthrough diretto VFIO).\n\nPermette lo switch 'a caldo' dell'hardware senza dover riavviare Proxmox.\n\nScegli quale scheda video desideri gestire:"

    # Finestra allargata a 100 colonne per far respirare il testo
    GPU_PCI=$(whiptail --title "Selezione GPU (v1.0.1)" \
        --menu "$INTRO_MSG" 22 100 4 "${menu_options[@]}" 3>&1 1>&2 2>&3)
    
    [ -z "$GPU_PCI" ] && exit 0

    # Rileva il Vendor ID
    VENDOR=$(lspci -n -s "$GPU_PCI" | awk '{print $3}' | cut -d':' -f1)
    case "$VENDOR" in
        10de) VENDOR_NAME="NVIDIA" ;;
        1002) VENDOR_NAME="AMD" ;;
        8086) VENDOR_NAME="INTEL" ;;
        *)    VENDOR_NAME="UNKNOWN" ;;
    esac

    # Cerca l'audio controller associato (stesso bus)
    local base_pci=$(echo "$GPU_PCI" | cut -d'.' -f1)
    AUD_PCI=$(lspci -D -nn | grep "$base_pci" | grep -i audio | awk '{print $1}' || echo "")
    
    # Aggiungi il prefisso di dominio se mancante per i percorsi /sys/
    if [[ "$GPU_PCI" != *":"*":"* ]]; then GPU_PCI="0000:$GPU_PCI"; fi
    if [[ -n "$AUD_PCI" && "$AUD_PCI" != *":"*":"* ]]; then AUD_PCI="0000:$AUD_PCI"; fi
}

main_menu() {
    select_gpu

    while true; do
        CHOICE=$(whiptail --title "Proxmox 9 GPU Manager (v1.0.1)" \
            --menu "GPU Selezionata: $GPU_PCI ($VENDOR_NAME)\n\nScegli un'operazione dal menu sottostante:" 22 95 6 \
            "1" "Configura Host (IOMMU su ZFS/systemd-boot)" \
            "2" "Crea VM Cloud-Init (Scelta Ubuntu 24 o Debian 13)" \
            "3" "ATTIVA VFIO (Assegna $VENDOR_NAME alla VM)" \
            "4" "RIPRISTINA DRIVER (Assegna $VENDOR_NAME agli LXC)" \
            "5" "Cambia GPU selezionata" \
            "6" "Esci dal programma" 3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case $CHOICE in
            1) setup_host_iommu ;;
            2) create_test_vm ;;
            3) bind_vfio ;;
            4) bind_host ;;
            5) select_gpu ;;
            6) break ;;
        esac
    done
}

setup_host_iommu() {
    clear
    echo -e "${GREEN}Configurazione IOMMU su systemd-boot (ZFS)...${NC}"
    
    if grep -q "Intel" /proc/cpuinfo; then
        IOMMU_FLAG="intel_iommu=on"
    else
        IOMMU_FLAG="amd_iommu=on"
    fi

    CMDLINE_FILE="/etc/kernel/cmdline"
    if ! grep -q "iommu=pt" "$CMDLINE_FILE"; then
        sed -i "\$ s/\$/ $IOMMU_FLAG iommu=pt/" "$CMDLINE_FILE"
        proxmox-boot-tool refresh
    fi

    MODULES_FILE="/etc/modules"
    for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        if ! grep -q "^$mod" "$MODULES_FILE"; then echo "$mod" >> "$MODULES_FILE"; fi
    done
    update-initramfs -u -k all

    whiptail --title "Riavvio Necessario" --msgbox "L'host è configurato per IOMMU.\n\nRIAVVIA PROXMOX 9 prima di tentare l'assegnazione tramite VFIO." 10 70
}

bind_vfio() {
    clear
    echo -e "${YELLOW}Ferma i container LXC che usano la GPU $GPU_PCI prima di procedere!${NC}"
    read -p "Premi INVIO per continuare, oppure CTRL+C per annullare..."
    
    # Se è NVIDIA, ferma il persistenced
    if [ "$VENDOR_NAME" == "NVIDIA" ]; then
        systemctl stop nvidia-persistenced 2>/dev/null || true
    fi
    
    # Unbind generico
    if [ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ]; then
        echo -n "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind
    fi
    echo "vfio-pci" > /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    
    # Unbind Audio
    if [ -n "$AUD_PCI" ]; then
        if [ -e "/sys/bus/pci/devices/$AUD_PCI/driver" ]; then
            echo -n "$AUD_PCI" > /sys/bus/pci/devices/$AUD_PCI/driver/unbind
        fi
        echo "vfio-pci" > /sys/bus/pci/devices/$AUD_PCI/driver_override
        echo "$AUD_PCI" > /sys/bus/pci/drivers_probe
    fi
    
    whiptail --title "VFIO Attivo" --msgbox "La GPU $GPU_PCI è stata sganciata dall'host e associata a vfio-pci.\n\nOra puoi avviare la VM in sicurezza." 10 70
}

bind_host() {
    clear
    echo -e "${YELLOW}Assicurati che la VM di test sia completamente SPENTA!${NC}"
    read -p "Premi INVIO per continuare, oppure CTRL+C per annullare..."
    
    # Rimuovi VFIO override e lascia che il kernel carichi il driver corretto
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
    
    # Procedure post-bind specifiche
    if [ "$VENDOR_NAME" == "NVIDIA" ]; then
        modprobe nvidia_uvm || true
        systemctl start nvidia-persistenced 2>/dev/null || true
        /usr/bin/nvidia-smi >/dev/null 2>&1 || true
    fi

    whiptail --title "Ripristino Completato" --msgbox "GPU $GPU_PCI riassegnata ai driver host nativi.\nI nodi in /dev/ sono stati rigenerati (se previsti).\n\nPuoi riavviare i container LXC." 10 70
}

create_test_vm() {
    VMID=$(whiptail --inputbox "Inserisci un ID per la nuova VM (es. 900):" 10 50 "900" 3>&1 1>&2 2>&3)
    [ -z "$VMID" ] && return
    
    STORAGE=$(whiptail --inputbox "Inserisci lo storage ZFS di destinazione:" 10 50 "local-zfs" 3>&1 1>&2 2>&3)
    [ -z "$STORAGE" ] && return

    OS_CHOICE=$(whiptail --menu "Quale sistema operativo vuoi installare?" 12 70 2 "1" "Ubuntu 24.04 LTS (Noble)" "2" "Debian 13 (Trixie)" 3>&1 1>&2 2>&3)
    [ -z "$OS_CHOICE" ] && return

    # Richiesta ROM opzionale
    ROM_FILE=$(whiptail --inputbox "Se hai caricato un file vBIOS in /usr/share/kvm/, scrivine il nome (es. vbios.rom).\nAltrimenti premi semplicemente INVIO:" 12 70 "" 3>&1 1>&2 2>&3)

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

    qm create $VMID --name $VM_NAME --memory 8192 --cores 4 --net0 virtio,bridge=vmbr0
    qm importdisk $VMID $IMG_FILE $STORAGE
    
    qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID-disk-0
    qm set $VMID --ide2 $STORAGE:cloudinit
    qm set $VMID --boot c --bootdisk scsi0
    qm set $VMID --serial0 socket --vga serial0
    qm set $VMID --agent enabled=1
    
    # Logica di Passthrough per Vendor
    SHORT_PCI=$(echo $GPU_PCI | awk -F':' '{print $2":"$3}')
    PT_OPTS="$SHORT_PCI,pcie=1"

    if [[ "$VENDOR_NAME" == "NVIDIA" || "$VENDOR_NAME" == "AMD" ]]; then
        PT_OPTS="${PT_OPTS},x-vga=1"
    fi
    
    if [ -n "$ROM_FILE" ]; then
        PT_OPTS="${PT_OPTS},romfile=$ROM_FILE"
    fi

    qm set $VMID --hostpci0 "$PT_OPTS"
    qm resize $VMID scsi0 40G

    whiptail --title "Creazione VM Completata" --msgbox "La VM $VMID è stata creata con il seguente passthrough:\n$PT_OPTS\n\nRicordati di impostare la password in Cloud-Init dall'interfaccia web di Proxmox e di usare il menu VFIO (Opzione 3) prima di accenderla." 12 75
}

main_menu
