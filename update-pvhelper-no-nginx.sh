#!/usr/bin/env bash

# ==============================================================================
# Proxmox Host & LXC Auto-Updater (Menu Interattivo + Locale Check + Verbose Scan)
# ==============================================================================

# Assicuriamoci che figlet sia installato
if ! command -v figlet &> /dev/null; then
    echo "Installazione di 'figlet' sull'host per i font ASCII Art..."
    apt-get update >/dev/null 2>&1
    apt-get install -y figlet >/dev/null 2>&1
fi

# Colori
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

clear
echo -e "${BLUE}=====================================================================${NC}"
figlet -f slant "PVE Updater"
echo -e "${BLUE}=====================================================================${NC}\n"

# ==============================================================================
# 1. AGGIORNAMENTO HOST PROXMOX (Opzionale)
# ==============================================================================
echo -e "${YELLOW}Vuoi eseguire l'aggiornamento dell'Host Proxmox prima degli LXC? [y/N]${NC}"
read -p "Risposta: " update_host
if [[ "${update_host,,}" == "y" ]]; then
    echo -e "\n${YELLOW}[*] Avvio aggiornamento dell'Host Proxmox...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update && apt-get dist-upgrade -y; then
        echo -e "${GREEN}[✔] Aggiornamento dell'Host Proxmox completato.${NC}\n"
    else
        echo -e "${RED}[!] Errore durante l'aggiornamento dell'Host.${NC}\n"
    fi
fi

# ==============================================================================
# 2. SCANSIONE CONTAINER E TABELLA RIASSUNTIVA (Verbose)
# ==============================================================================
echo -e "\n${CYAN}=====================================================================${NC}"
echo -e "${CYAN}Scansione dei container LXC in corso (ricerca Helper-Scripts)...${NC}"
echo -e "${CYAN}=====================================================================${NC}\n"

declare -A LXC_NAMES
declare -A LXC_STATUS
declare -A LXC_OS
declare -A LXC_IP
helper_running=()
helper_all=()

all_lxcs=$(pct list | awk 'NR>1 {print $1}')

for vmid in $all_lxcs; do
    app_name=$(pct config "$vmid" | awk '/^hostname:/ {print $2}')
    [ -z "$app_name" ] && app_name="LXC-$vmid"

    # Stampa l'inizio dell'analisi senza andare a capo (per l'output in linea)
    echo -ne "${GRAY}Analisi VMID ${vmid} [${app_name}] -> ${NC}"

    # Esclusione automatica Nginx
    if [[ "${app_name,,}" == *"nginx"* ]]; then
        echo -e "${CYAN}Saltato (Regola Nginx)${NC}"
        continue
    fi

    status=$(pct status "$vmid" | awk '{print $2}')
    
    echo -ne "Verifica config... "
    is_helper=$(grep -iE "tteck|helper-scripts" "/etc/pve/lxc/${vmid}.conf" 2>/dev/null)
    
    # Se è in esecuzione ma non ha il tag nel conf, controlliamo se ha il comando update
    if [[ -z "$is_helper" && "$status" == "running" ]]; then
        echo -ne "Verifica comando interno... "
        # Timeout inserito nel caso in cui pct exec si blocchi su un container instabile
        has_update=$(timeout 5 pct exec "$vmid" -- bash -c "command -v update" 2>/dev/null)
        [[ -n "$has_update" ]] && is_helper="yes"
    fi

    if [[ -n "$is_helper" ]]; then
        echo -ne "Recupero IP e OS... "
        ostype=$(pct config "$vmid" | awk '/^ostype:/ {print $2}')
        [ -z "$ostype" ] && ostype="N/D"

        # Recupera IP
        if [[ "$status" == "running" ]]; then
            ip=$(timeout 5 pct exec "$vmid" -- ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
        else
            # Tenta di leggere l'IP dal file di configurazione se il CT è spento
            ip=$(pct config "$vmid" | grep -w "ip" | sed -E 's/.*ip=([^,]+).*/\1/' | cut -d/ -f1)
        fi
        [ -z "$ip" ] || [[ "$ip" == *"dhcp"* ]] && ip="DHCP / N/D"

        LXC_NAMES[$vmid]=$app_name
        LXC_STATUS[$vmid]=$status
        LXC_OS[$vmid]=$ostype
        LXC_IP[$vmid]=$ip
        
        helper_all+=("$vmid")
        [[ "$status" == "running" ]] && helper_running+=("$vmid")

        echo -e "${GREEN}Trovato Helper-Script!${NC}"
    else
        echo -e "${YELLOW}Non compatibile.${NC}"
    fi
done

if [ ${#helper_all[@]} -eq 0 ]; then
    echo -e "\n${RED}Nessun container derivato da Proxmox Helper-Scripts trovato.${NC}"
    exit 0
fi

echo -e "\n${YELLOW}=== CONTAINER HELPER-SCRIPTS RILEVATI ===${NC}"
printf "${CYAN}%-6s | %-20s | %-8s | %-15s | %s${NC}\n" "VMID" "HOSTNAME" "OS" "STATO" "INDIRIZZO IP"
echo "-------------------------------------------------------------------------------"
for vmid in "${helper_all[@]}"; do
    if [[ "${LXC_STATUS[$vmid]}" == "running" ]]; then
        stat_color="${GREEN}In Esecuzione${NC}"
    else
        stat_color="${RED}Fermo${NC}        "
    fi
    printf "%-6s | %-20s | %-8s | %-24b | %s\n" "$vmid" "${LXC_NAMES[$vmid]}" "${LXC_OS[$vmid]}" "$stat_color" "${LXC_IP[$vmid]}"
done
echo "-------------------------------------------------------------------------------"

# ==============================================================================
# 3. MENU DI SELEZIONE
# ==============================================================================
echo -e "\n${BLUE}Scegli quali container aggiornare:${NC}"
echo "  1) Solo gli LXC attualmente in esecuzione (${#helper_running[@]} trovati)"
echo "  2) Tutti gli LXC compatibili (avvierà temporaneamente quelli fermi per aggiornarli)"
echo "  3) Selezione manuale multipla (tra quelli attivi)"
echo "  0) Esci"
read -p "Selezione [0-3]: " menu_choice

target_vmids=()

case $menu_choice in
    1) target_vmids=("${helper_running[@]}") ;;
    2) target_vmids=("${helper_all[@]}") ;;
    3)
        if [ ${#helper_running[@]} -eq 0 ]; then
            echo -e "${RED}Nessun LXC attivo disponibile per la selezione manuale.${NC}"
            exit 0
        fi
        echo -e "\n${YELLOW}Seleziona i container dall'elenco (separati da spazio):${NC}"
        idx=1
        declare -A select_map
        for vmid in "${helper_running[@]}"; do
            echo "  $idx) [VMID: $vmid] ${LXC_NAMES[$vmid]}"
            select_map[$idx]=$vmid
            ((idx++))
        done
        echo ""
        read -p "Inserisci i numeri (es. 1 3 4): " user_sel
        for num in $user_sel; do
            if [[ -n "${select_map[$num]}" ]]; then
                target_vmids+=("${select_map[$num]}")
            fi
        done
        ;;
    0|*) echo "Uscita."; exit 0 ;;
esac

if [ ${#target_vmids[@]} -eq 0 ]; then
    echo -e "${RED}Nessun container selezionato. Uscita.${NC}"
    exit 0
fi

# ==============================================================================
# 4. CICLO DI AGGIORNAMENTO
# ==============================================================================
for vmid in "${target_vmids[@]}"; do
    app_name="${LXC_NAMES[$vmid]}"
    
    echo -e "\n====================================================================="
    figlet -f slant "$app_name"
    figlet -f small "VMID: $vmid"
    echo -e "=====================================================================\n"

    # Gestione avvio temporaneo se il container è fermo
    was_stopped=0
    if [[ "${LXC_STATUS[$vmid]}" != "running" ]]; then
        echo -e "${YELLOW}[*] Il container $vmid è fermo. Avvio in corso per l'aggiornamento...${NC}"
        pct start "$vmid"
        was_stopped=1
        echo "Attendere 5 secondi per l'inizializzazione dei servizi di rete..."
        sleep 5
    fi

    # --- CONTROLLO LOCALE ---
    LOCALE_CURRENT=$(pct exec "$vmid" -- bash -c "source /etc/default/locale 2>/dev/null; echo \$LANG")
    
    if [[ -z "$LOCALE_CURRENT" || "$LOCALE_CURRENT" == "C" || "$LOCALE_CURRENT" == "POSIX" ]]; then
        echo -e "${RED}[!] Locale non configurato o base (Attuale: '${LOCALE_CURRENT}') in ${app_name}.${NC}"
        echo -e "Scegli un'opzione:"
        echo "  1) Imposta Italia (it_IT.UTF-8) e Fuso Orario Roma (Europe/Rome) [DEFAULT]"
        echo "  2) Configurazione Custom"
        echo "  3) Salta la configurazione del Locale"
        read -p "Selezione [1-3]: " loc_choice
        loc_choice=${loc_choice:-1}
        
        TARGET_LANG=""
        TARGET_TZ=""

        if [ "$loc_choice" -eq 1 ]; then
            TARGET_LANG="it_IT.UTF-8"
            TARGET_TZ="Europe/Rome"
        elif [ "$loc_choice" -eq 2 ]; then
            read -p "  -> Lingua (es. en_US.UTF-8): " TARGET_LANG
            read -p "  -> Fuso orario (es. America/New_York): " TARGET_TZ
        fi

        if [[ -n "$TARGET_LANG" && -n "$TARGET_TZ" ]]; then
            echo -e "${YELLOW}[*] Installazione e configurazione di $TARGET_LANG ($TARGET_TZ)...${NC}"
            pct exec "$vmid" -- bash -c "
                export DEBIAN_FRONTEND=noninteractive
                apt-get update >/dev/null 2>&1
                apt-get install -y locales tzdata >/dev/null 2>&1
                sed -i \"/^# *$TARGET_LANG/s/^# //\" /etc/locale.gen
                locale-gen $TARGET_LANG >/dev/null 2>&1
                update-locale LANG=$TARGET_LANG LC_ALL=$TARGET_LANG
                ln -fs /usr/share/zoneinfo/$TARGET_TZ /etc/localtime
                dpkg-reconfigure --frontend noninteractive tzdata >/dev/null 2>&1
            "
            echo -e "${GREEN}[✔] Variabili locali impostate.${NC}\n"
        else
            echo -e "-> Configurazione locale saltata.\n"
        fi
    else
        echo -e "${GREEN}[✔] Locale già impostato (${LOCALE_CURRENT}).${NC}\n"
    fi
    # ------------------------

    echo -e "${YELLOW}[*] Avvio aggiornamenti apt e custom update per ${app_name}...${NC}\n"

    pct exec "$vmid" -- bash -c "source /etc/default/locale 2>/dev/null; export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get upgrade -y && update"
    
    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}[✔] Aggiornamento completato con successo per ${app_name} (${vmid}).${NC}"
    else
        echo -e "\n${RED}[!] Attenzione: Errore durante l'aggiornamento di ${app_name} (${vmid}).${NC}"
    fi

    # Se lo avevamo acceso noi per aggiornarlo, lo rispegniamo
    if [[ "$was_stopped" -eq 1 ]]; then
        echo -e "\n${YELLOW}[*] Spegnimento del container $vmid (era fermo originariamente)...${NC}"
        pct stop "$vmid"
    fi
    
    echo -e "=====================================================================\n"
done

echo -e "${BLUE}Procedura di aggiornamento completata!${NC}\n"
