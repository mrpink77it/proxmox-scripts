#!/usr/bin/env bash

# ==============================================================================
# Proxmox Host & LXC Auto-Updater (Helper-Scripts Compatibile)
# ==============================================================================

# Assicuriamoci che figlet sia installato per stampare l'ASCII Art
if ! command -v figlet &> /dev/null; then
    echo "Installazione di 'figlet' sull'host per i font ASCII Art..."
    apt-get update >/dev/null 2>&1
    apt-get install -y figlet >/dev/null 2>&1
fi

# Colori per il terminale
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ==============================================================================
# 1. AGGIORNAMENTO HOST PROXMOX
# ==============================================================================
echo -e "\n====================================================================="
figlet -f slant "Proxmox Host"
echo -e "=====================================================================\n"
echo -e "${YELLOW}[*] Avvio aggiornamento dell'Host Proxmox...${NC}\n"

# Utilizziamo dist-upgrade come raccomandato dalla documentazione ufficiale di Proxmox
export DEBIAN_FRONTEND=noninteractive
if apt-get update && apt-get dist-upgrade -y; then
    echo -e "\n${GREEN}[✔] Aggiornamento dell'Host Proxmox completato con successo.${NC}"
else
    echo -e "\n${RED}[!] Attenzione: Si è verificato un errore durante l'aggiornamento dell'Host.${NC}"
fi
echo -e "=====================================================================\n"

# ==============================================================================
# 2. AGGIORNAMENTO CONTAINER LXC
# ==============================================================================
echo -e "${BLUE}Ricerca di container LXC attivi...${NC}\n"

# Recupera solo gli ID dei container attualmente in esecuzione (running)
lxc_list=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

if [ -z "$lxc_list" ]; then
    echo "Nessun container LXC in esecuzione trovato."
    exit 0
fi

for vmid in $lxc_list; do
    # Estrae l'hostname (nome applicazione) dalla configurazione di Proxmox
    app_name=$(pct config "$vmid" | awk '/^hostname:/ {print $2}')
    [ -z "$app_name" ] && app_name="LXC-$vmid"

    # --- REGOLA DI ESCLUSIONE NGINX ---
    # Converte app_name in minuscolo (,,) e controlla se contiene "nginx"
    if [[ "${app_name,,}" == *"nginx"* ]]; then
        echo -e "-> Salto ${app_name} (${vmid}): Escluso esplicitamente dallo script."
        continue
    fi
    # ----------------------------------

    # CONTROLLI HELPER-SCRIPTS:
    # 1. Cerca tracce di tteck/helper-scripts nella descrizione/configurazione di Proxmox
    is_helper=$(grep -iE "tteck|helper-scripts" "/etc/pve/lxc/${vmid}.conf" 2>/dev/null)
    # 2. Verifica se esiste fisicamente il comando "update" all'interno
    has_update_cmd=$(pct exec "$vmid" -- bash -c "command -v update" 2>/dev/null)

    if [[ -n "$is_helper" ]] || [[ -n "$has_update_cmd" ]]; then
        
        # --- ASCII ART OUTPUT ---
        echo -e "\n====================================================================="
        figlet -f slant "$app_name"
        figlet -f small "VMID: $vmid"
        echo -e "=====================================================================\n"
        
        echo -e "${YELLOW}[*] Avvio aggiornamenti apt e custom update per ${app_name}...${NC}\n"

        # Esecuzione della catena di comandi all'interno dell'LXC.
        pct exec "$vmid" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y && update"
        
        # Verifica dell'esito
        if [ $? -eq 0 ]; then
            echo -e "\n${GREEN}[✔] Aggiornamento completato con successo per ${app_name} (${vmid}).${NC}"
        else
            echo -e "\n${RED}[!] Attenzione: Si è verificato un errore durante l'aggiornamento di ${app_name} (${vmid}).${NC}"
        fi
        
        echo -e "=====================================================================\n"
    else
        echo -e "-> Salto ${app_name} (${vmid}): Non sembra derivare da Proxmox Helper-Scripts."
    fi
done

echo -e "\n${BLUE}Procedura completata su tutto il sistema (Host + Container compatibili).${NC}\n"
