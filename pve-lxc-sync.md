# Guida Tecnica e Architettura: PVE-Zsync Manager per Proxmox VE

## 1. Introduzione e Architettura
**PVE-Zsync Manager** è una TUI (Text User Interface) scritta in Bash Shell per automatizzare la replica, sincronizzazione e migrazione di container LXC basati su ZFS tra nodi Proxmox VE distinti (clusterizzati o isolati).

### Principi Operativi:
- **Replica ZFS Nativa:** Utilizza il motore `pve-zsync` per eseguire lo snapshot delta e lo stream incrementale dei blocchi via SSH (`zfs send` / `zfs receive`).
- **Allineamento Configurazione:** Oltre al volume ZFS, trasferisce via SCP il file di configurazione `/etc/pve/lxc/<VMID>.conf`.
- **Indipendenza dal Cluster:** Funziona sia tra nodi appartenenti allo stesso cluster Proxmox VE, sia tra nodi completamente isolati su rete locale o geografica.

---

## 2. Dipendenze di Sistema
All'avvio, lo script controlla l'ambiente ed esegue l'installazione automatica dei seguenti pacchetti tramite `apt-get`:

| Pacchetto | Scopo |
| :--- | :--- |
| `whiptail` | Rendering dell'interfaccia grafica TUI a terminale. |
| `pve-zsync` | Utility nativa Proxmox per la gestione dei job e del sync ZFS. |
| `nmap` | Discovery di rete per individuare altri nodi Proxmox sulla LAN (porta 8006). |
| `sshpass` | Gestione delle credenziali SSH non interattive tramite password. |
| `diffutils` | Confronto strutturato (`diff -u`) dei file di configurazione LXC. |
| `pv` / `mbuffer` | Controllo del flusso dati e throttling (se abilitato). |
| `mailutils` / `curl` | Invio di notifiche via Email (`mail`) e Telegram API (`curl`). |

---

## 3. Scansione Rete e Rilevamento Nodi
Lo script individua i nodi Proxmox target attraverso due meccanismi paralleli:
1. **Cluster Proxmox VE:** Interroga l'API locale tramite `pvesh get /nodes` per estrarre la lista di tutti i nodi del cluster.
2. **Scansione LAN (Nodi Isolati):** Rileva la subnet locale (`ip addr`) ed esegue una scansione veloce con `nmap` per identificare tutti gli host con la porta `8006/tcp` (servizio `pveproxy`) aperta.
3. **Selezione Manuale:** Permette l'inserimento manuale di IP/Hostname per nodi remoti non raggiungibili via multicast o fuori subnet.

---

## 4. Gestione Credenziali e Connessioni SSH
Per consentire operazioni sicure o automatizzate, lo script supporta due modalità di autenticazione:
- **Autenticazione via Password:** Sfrutta `sshpass` per le operazioni SCP e SSH su nodi remoti.
- **Wizard Chiavi SSH Passwordless (Consigliato):** Genera una coppia di chiavi RSA (`~/.ssh/id_rsa`) sul nodo locale e la distribuisce sul nodo target tramite `ssh-copy-id`. Questa modalità è obbligatoria per eseguire i job di sincronizzazione ricorsiva in background.

---

## 5. Dettaglio delle Funzionalità

### A. Sincronizzazione / Clonazione LXC
1. **Selezione Container:** Recupera la lista dei container ed estrae l'hostname effettivo dal parametro `hostname:` in `/etc/pve/lxc/<VMID>.conf`.
2. **Pre-flight Check:** Interroga il pool ZFS del nodo target via SSH (`zfs get available`) per assicurarsi che vi sia spazio disco sufficiente prima dell'invio dei dati.
3. **Modalità di Esecuzione:**
   - **One-shot (`sync`):** Esegue una singola sincronizzazione al momento.
   - **Ricorsiva (`create`):** Pianifica un job cron interno tramite `pve-zsync` per repliche periodiche.
4. **Azioni Post-Migrazione:**
   - *Nessuna azione:* Sincronizza solo i dati e la configurazione.
   - *Switchover completo:* Spegne il container sul nodo sorgente (`pct stop`) e lo avvia sul nodo target (`pct start`).
   - *Shutdown Sorgente:* Spegne solo il container locale mantenendo il target pronto all'uso.

### B. Confronto Configurazioni
Scarica in un file temporaneo `/tmp/<VMID>_remote.conf` la configurazione del nodo remoto tramite SCP e lancia una `diff -u` rispetto alla versione locale. Viene mostrato un resoconto visivo con le discrepanze (es. RAM, CPU, percorsi di rete o storage).

### C. Gestione Job `pve-zsync`
Legge ed elenca tutti i task schedulati via `pve-zsync list`. Permette la selezione e la rimozione atomica tramite `pve-zsync destroy --name <job_name>`.

---

## 6. Guida alla Configurazione Notifiche (Telegram & Email)

### Creazione e Configurazione Bot Telegram

1. **Creazione del Bot con `@BotFather`:**
   - Apri Telegram e cerca l'utente ufficiale `@BotFather`.
   - Avvia la chat e invia il comando `/newbot`.
   - Inserisci il nome del bot (es. `Proxmox Sync Bot`).
   - Inserisci lo username del bot (deve terminare in `bot`, es. `my_pve_sync_bot`).
   - Copia il **HTTP API Token** fornito da BotFather (formato: `123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ`).

2. **Ottenimento del Chat ID con `@userinfobot`:**
   - Cerca su Telegram l'utente `@userinfobot`.
   - Avvia la chat o invia un qualsiasi messaggio.
   - Il bot risponderà indicando il tuo `Id` numerico (es. `987654321`).

3. **Integrazione nello Script:**
   - Avvia lo script e seleziona l'opzione `5` (**Configura Notifiche**).
   - Inserisci il **Bot Token** e il **Chat ID**.
   - I dati verranno salvati permanentemente nel file `/etc/pve-zsync-tui.conf`.

### Configurazione Email
Le notifiche email si basano sul sottosistema di posta locale di Proxmox VE. Assicurati che Postfix o il Mail Transfer Agent (MTA) sul nodo sia correttamente configurato per inoltrare i messaggi verso l'indirizzo inserito nel menù di configurazione.