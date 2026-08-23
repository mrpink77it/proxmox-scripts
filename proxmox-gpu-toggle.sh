#!/usr/bin/env bash
# ==============================================================================
# Proxmox 9 - Dynamic GPU Passthrough Manager (LXC <-> VM)
# Supporto specifico per ZFS + systemd-boot
# ==============================================================================
# DESCRIZIONE DETTAGLIATA E FUNZIONAMENTO:
# Questo script automatizza l'assegnazione dinamica di una GPU NVIDIA tra
# container LXC (che richiedono il driver caricato sull'host e i nodi in /dev/)
# e Macchine Virtuali (che richiedono il passthrough PCIe diretto tramite VFIO).
# Evita l'uso della blacklist in /etc/modprobe.d/, permettendo lo switch "a caldo"
# senza riavviare Proxmox 9.
#
# ELENCO DELLE FUNZIONI:
# [1] Configura Host (IOMMU):
#     - Rileva l'architettura CPU (Intel/AMD) e configura i flag corretti
#       (intel_iommu=on / amd_iommu=on e iommu=pt).
#     - Scrive i parametri in /etc/kernel/cmdline (specifico per boot su ZFS).
#     - Inserisce i moduli vfio, vfio_iommu_type1, vfio_pci, vfio_virqfd in /etc/modules.
#     - Esegue proxmox-boot-tool refresh e update-initramfs.
# [2] Crea VM Ubuntu 24.04:
#     - Scarica l'immagine ufficiale Cloud-Init di Ubuntu 24.04.
#     - Crea una VM configurando RAM (8GB), CPU (4 core) e disco su ZFS (40GB).
#     - Collega automaticamente la GPU rilevata come dispositivo hostpci0.
#     - Prepara il Cloud-Init per l'inserimento di utente/password da Web GUI.
# [3] ATTIVA VFIO (Assegna GPU alla VM):
#     - Ferma systemd-persistenced (che tiene occupata la scheda).
#     - Esegue l'unbind a caldo della GPU (e del controller Audio) dai driver NVIDIA host.
#     - Esegue il bind tramite driver_override al modulo vfio-pci.
#     - (A questo punto la VM può essere accesa e avrà il controllo hardware esclusivo).
# [4] RIPRISTINA NVIDIA (Assegna GPU agli LXC):
#     - Esegue l'unbind della GPU e del controller Audio da vfio-pci.
#     - Ricarica i moduli kernel nvidia e nvidia_uvm sull'host.
#     - Riavvia il servizio nvidia-persistenced.
#     - Esegue nvidia-smi "silenziosamente" per forzare la ricreazione immediata
#       dei nodi /dev/nvidia* (dev0, nvidiactl, uvm, caps) usati dai container LXC.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Rileva automaticamente la GPU NVIDIA
GPU_PCI=$(lspci -D -nn | grep -i nvidia | grep -i vga | awk '{print $1}')
AUD_PCI=$(lspci -D -nn | grep -i nvidia | grep -i audio | awk '{print $1}' || echo "")

if [ -z "$GPU_PCI" ]; then
    echo -e "${RED}[ERRORE] Nessuna GPU NVIDIA rilevata nel sistema.${NC}"
    exit 1
fi

main_menu() {
    while true; do
        CHOICE=$(whiptail --title "Proxmox 9 GPU Passthrough Manager" \
            --menu "GPU Rilevata: $GPU_PCI\nScegli un'operazione:" 20 70 6 \
            "1" "Configura Host (IOMMU su ZFS/systemd-boot)" \
            "2" "Crea VM Ubuntu 24.04 (Cloud-Init + Passthrough)" \
            "3" "ATTIVA VFIO (Assegna GPU alla VM)" \
            "4" "RIPRISTINA NVIDIA (Assegna GPU agli LXC)" \
            "5" "Esci" 3>&1 1>&2 2>&3)
            
        if [ $? -ne 0 ]; then break; fi

        case $CHOICE in
            1) setup_host_iommu ;;
            2) create_test_vm ;;
            3) bind_vfio ;;
            4) bind_nvidia ;;
            5) break ;;
        esac
    done
}

setup_host_iommu() {
    clear
    echo -e "${GREEN}Configurazione IOMMU su systemd-boot (ZFS)...${NC}"
    
    # Determina CPU per flag IOMMU
    if grep -q "Intel" /proc/cpuinfo; then
        IOMMU_FLAG="intel_iommu=on"
    else
        IOMMU_FLAG="amd_iommu=on"
    fi

    # Configura cmdline per systemd-boot (ZFS)
    CMDLINE_FILE="/etc/kernel/cmdline"
    if ! grep -q "iommu=pt" "$CMDLINE_FILE"; then
        echo -e "${YELLOW}Aggiungo i parametri IOMMU a $CMDLINE_FILE...${NC}"
        sed -i "\$ s/\$/ $IOMMU_FLAG iommu=pt/" "$CMDLINE_FILE"
        proxmox-boot-tool refresh
    else
        echo -e "${GREEN}Parametri IOMMU già presenti in $CMDLINE_FILE.${NC}"
    fi

    # Configura moduli VFIO
    MODULES_FILE="/etc/modules"
    for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        if ! grep -q "^$mod" "$MODULES_FILE"; then
            echo "$mod" >> "$MODULES_FILE"
        fi
    done
    update-initramfs -u -k all

    whiptail --title "Riavvio Necessario" --msgbox "L'host è configurato per IOMMU. Se è la prima volta che abiliti questi parametri nel kernel, DEVI RIAVVIARE PROXMOX 9 prima di poter usare il passthrough." 10 65
}

bind_vfio() {
    clear
    echo -e "${YELLOW}ATTENZIONE: Assicurati di aver fermato tutti i container LXC che stanno utilizzando la GPU!${NC}"
    read -p "Premi INVIO se hai fermato gli LXC, oppure CTRL+C per annullare..."
    
    echo -e "\n${GREEN}Scollegamento GPU dal driver NVIDIA (Host)...${NC}"
    
    systemctl stop nvidia-persistenced 2>/dev/null || true
    
    # Unbind VGA
    echo -n "$GPU_PCI" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || true
    echo "vfio-pci" > /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    
    # Unbind Audio (se presente)
    if [ -n "$AUD_PCI" ]; then
        echo -n "$AUD_PCI" > /sys/bus/pci/drivers/snd_hda_intel/unbind 2>/dev/null || true
        echo "vfio-pci" > /sys/bus/pci/devices/$AUD_PCI/driver_override
        echo "$AUD_PCI" > /sys/bus/pci/drivers_probe
    fi
    
    whiptail --title "Assegnazione VFIO Completata" --msgbox "GPU ($GPU_PCI) correttamente sganciata dall'host e agganciata a vfio-pci. Ora puoi avviare in sicurezza la tua VM di test." 8 60
}

bind_nvidia() {
    clear
    echo -e "${YELLOW}ATTENZIONE: Assicurati che la VM con il passthrough sia completamente SPENTA!${NC}"
    read -p "Premi INVIO per continuare, oppure CTRL+C per annullare..."
    
    echo -e "\n${GREEN}Ripristino GPU al driver NVIDIA (LXC)...${NC}"
    
    # Unbind VGA da vfio
    echo -n "$GPU_PCI" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    echo "" > /sys/bus/pci/devices/$GPU_PCI/driver_override
    echo "$GPU_PCI" > /sys/bus/pci/drivers_probe
    
    # Unbind Audio da vfio
    if [ -n "$AUD_PCI" ]; then
        echo -n "$AUD_PCI" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        echo "" > /sys/bus/pci/devices/$AUD_PCI/driver_override
        echo "$AUD_PCI" > /sys/bus/pci/drivers_probe
    fi
    
    # Ricarica moduli NVIDIA host
    modprobe nvidia
    modprobe nvidia_uvm
    systemctl start nvidia-persistenced 2>/dev/null || true
    
    # Forza la ricreazione dei nodi in /dev/nvidia per permettere agli LXC di vedere la GPU
    if [ ! -c /dev/nvidia0 ]; then
        echo -e "${YELLOW}Rigenerazione device node in /dev/...${NC}"
        /usr/bin/nvidia-smi >/dev/null 2>&1 || true
    fi

    whiptail --title "Ripristino Completato" --msgbox "GPU ($GPU_PCI) riassegnata ai moduli NVIDIA nativi. I nodi in /dev/ sono stati rigenerati. Ora puoi riavviare i tuoi container LXC." 9 65
}

create_test_vm() {
    VMID=$(whiptail --inputbox "Inserisci un ID per la nuova VM (es. 900):" 8 40 "900" 3>&1 1>&2 2>&3)
    [ -z "$VMID" ] && return
    
    STORAGE=$(whiptail --inputbox "Inserisci lo storage ZFS di destinazione (es. local-zfs):" 8 40 "local-zfs" 3>&1 1>&2 2>&3)
    [ -z "$STORAGE" ] && return

    echo -e "${GREEN}Scaricamento immagine Ubuntu 24.04 Cloud-Init...${NC}"
    cd /var/lib/vz/template/iso
    wget -nc -q --show-progress https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

    echo -e "${GREEN}Creazione VM $VMID...${NC}"
    qm create $VMID --name Ubuntu-AI-Test --memory 8192 --cores 4 --net0 virtio,bridge=vmbr0
    qm importdisk $VMID noble-server-cloudimg-amd64.img $STORAGE
    
    # Setup scsi controller e aggancio disco
    qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$VMID-disk-0
    qm set $VMID --ide2 $STORAGE:cloudinit
    qm set $VMID --boot c --bootdisk scsi0
    qm set $VMID --serial0 socket --vga serial0
    qm set $VMID --agent enabled=1
    
    # Iniezione GPU PCI Passthrough diretto
    SHORT_PCI=$(echo $GPU_PCI | cut -d':' -f2-)
    qm set $VMID --hostpci0 $SHORT_PCI,pcie=1,x-vga=1
    
    # Espansione del disco per i test (40GB)
    qm resize $VMID scsi0 40G

    whiptail --title "Creazione VM Completata" --msgbox "La VM $VMID è pronta sull'host Proxmox 9.\n\nSTEP SUCCESSIVI:\n1. Apri la Web GUI di Proxmox.\n2. Seleziona la VM -> Cloud-Init e imposta User, Password e/o chiavi SSH.\n3. Clicca su 'Regenerate Image'.\n\nAttenzione: Prima di accenderla, esegui l'Opzione 3 dello script per assegnarle la GPU!" 16 65
}

main_menu
