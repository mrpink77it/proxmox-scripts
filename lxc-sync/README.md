# PVE-Zsync Manager

**PVE-Zsync Manager** è una TUI (Text User Interface) avanzata scritta in Bash Shell con interfaccia `whiptail`, progettata specificamente per ambienti **Proxmox VE (PVE)**. Semplifica, automatizza e protegge la gestione, la clonazione, la replica e la migrazione dei container LXC basati su ZFS tra nodi Proxmox VE distinti (sia appartenenti allo stesso cluster che isolati).

---

## 🏛️ Architettura e Principi Operativi

* **Replica ZFS Nativa:** Utilizza il motore `pve-zsync` per eseguire lo snapshot delta e lo stream incrementale dei blocchi via SSH (`zfs send` / `zfs receive`).
* **Allineamento Configurazione:** Oltre ai volumi ZFS (`rootfs:`, `mp0:`, ecc.), trasferisce e adatta automaticamente il file di configurazione `/etc/pve/lxc/<VMID>.conf`.
* **Indipendenza dal Cluster:** Funziona sia tra nodi all'interno dello stesso cluster Proxmox VE, sia tra nodi completamente isolati su rete locale o geografica.

---

## 🚀 Caratteristiche Principali

* **Interfaccia TUI Intuitiva:** Navigazione pulita con pulsanti standardizzati (`<Seleziona>`, `<Avanti>`, `<Indietro>`, `<Esci>`) per evitare uscite accidentali.
* **Scansione Automatica dei Nodi:** Rilevamento dei nodi via API di cluster (`pvesh`) e tramite scansione LAN su porta TCP `8006` per nodi isolati.
* **Wizard Chiavi SSH:** Configurazione guidata per lo scambio di chiavi RSA (`ssh-copy-id`) abilitando la connessione passwordless (necessaria per job pianificati in background).
* **Pre-flight Checks:** Verifiche preliminari dello spazio libero sul pool ZFS target prima dell'invio dei dati.
* **Rilevamento e Mappatura Storage Target:** Interrogazione dinamica via SSH degli storage attivi sul nodo remoto (`pvesm status`) e risoluzione del pool ZFS associato.
* **Rewriting Automatico Configurazione:** Se lo storage o il VMID differiscono sul target, lo script rinomina e adatta i parametri dei volumi nel file `.conf` per garantire l'immediata avviabilità del container.
* **Dashboard in Tempo Reale (Dual-Area):**
  1. *Area Superiore:* Barra di avanzamento percentuale dinamica con polling dei byte scritti (`zfs get written`) e velocità di trasferimento.
  2. *Area Inferiore:* Log live esteso con l'output dei comandi ZFS e `pve-zsync`.
* **Azioni Post-Sincronizzazione:** Opzioni per lo spegnimento della sorgente, switchover completo (stop sorgente + start target) o mantenimento dello stato attuale.
* **Gestione Job `pve-zsync`:** Visualizzazione ed eliminazione rapida dei task schedulati attivi.
* **Confronto Configurazioni:** Download del file `.conf` remoto ed esecuzione di un `diff -u` visivo rispetto alla sorgente.
* **Notifiche Multicanale:** Invio di report di esito tramite **Telegram** (Bot API) ed **Email** (`mailutils`).

---

## 📦 Dipendenze di Sistema

All'avvio, lo script controlla l'ambiente ed esegue l'installazione automatica tramite `apt-get` dei seguenti pacchetti se non presenti:

| Pacchetto | Scopo |
| :--- | :--- |
| `whiptail` | Rendering dell'interfaccia grafica TUI a terminale. |
| `pve-zsync` | Utility nativa Proxmox per la gestione dei job e del sync ZFS. |
| `nmap` | Discovery di rete per individuare altri nodi Proxmox sulla LAN (porta `8006`). |
| `sshpass` | Gestione delle credenziali SSH non interattive tramite password. |
| `diffutils` | Confronto strutturato (`diff -u`) dei file di configurazione LXC. |
| `pv` / `mbuffer` | Controllo del flusso dati e throttling. |
| `mailutils` / `curl` | Invio di notifiche via Email (`mail`) e Telegram API (`curl`). |
| `jq` | Parsing dei dati JSON. |

---

## 🔍 Discovery Nodi e Gestione SSH

### Scansione Rete
Lo script individua i nodi Proxmox target attraverso due meccanismi paralleli:
1. **Cluster Proxmox VE:** Interroga l'API locale tramite `pvesh get /nodes` per estrarre la lista di tutti i nodi del cluster.
2. **Scansione LAN (Nodi Isolati):** Rileva la subnet locale (`ip addr`) ed esegue una scansione con `nmap` per identificare gli host con la porta `8006/tcp` (servizio `pveproxy`) aperta.
3. **Selezione Manuale:** Permette l'inserimento diretto di IP o Hostname per nodi remoti non raggiungibili via multicast o fuori subnet.

### Autenticazione SSH
* **Password (sshpass):** Adatta per operazioni "one-shot" estemporanee.
* **Chiavi SSH Passwordless (Consigliato):** Il wizard genera una coppia di chiavi RSA (`~/.ssh/id_rsa`) sul nodo locale e la distribuisce sul nodo target tramite `ssh-copy-id`. Questa modalità è raccomandata per i job di sincronizzazione ricorsiva in background.

---

## ⚙️ Installazione e Avvio

1. Salvare lo script sul nodo Proxmox (es. `/usr/local/bin/pve-zsync-manager.sh`).
2. Rendere lo script eseguibile:
   ```bash
   chmod +x /usr/local/bin/pve-zsync-manager.sh
   ```
3. Eseguire lo script con i privilegi di root:
   ```bash
   sudo /usr/local/bin/pve-zsync-manager.sh
   ```

---

## 🤖 Configurazione delle Notifiche

I parametri delle notifiche vengono salvati permanentemente nel file di configurazione `/etc/pve-zsync-tui.conf`.

### 1. Bot Telegram
1. **Creazione Bot:** Aprire Telegram, cercare **`@BotFather`**, inviare `/newbot` e seguire la procedura per ottenere il **HTTP API Token** (es. `123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ`).
2. **Ottenimento Chat ID:** Cercare su Telegram **`@userinfobot`** e inviare `/start` per leggere il proprio **ID numerico** (es. `987654321`).
3. **Integrazione:** Selezionare l'opzione *Configura Notifiche* dal menu principale dello script e inserire Token e Chat ID.

### 2. Email
Le notifiche email si basano sul sottosistema di posta locale di Proxmox VE. Assicurarsi che Postfix o l'MTA di sistema sul nodo sia configurato per l'inoltro di posta verso l'indirizzo inserito nel menu dello script.

---

## 🛠️ Dettaglio Menu e Funzionalità

```
════════════════════════════════════════════════════════════
                 PVE-ZSYNC MANAGER - TUI                    
════════════════════════════════════════════════════════════
  1. Sincronizza / Clona Container LXC
  2. Wizard Chiavi SSH Passwordless
  3. Gestisci / Elimina Job pve-zsync
  4. Confronta Configurazione (Sorgente vs Target)
  5. Configura Notifiche (Telegram & Email)
  6. Guida e Help
  7. Esci
════════════════════════════════════════════════════════════
```

1. **Sincronizza / Clona Container LXC:**
   * Recupera la lista LXC estraendo l'hostname da `/etc/pve/lxc/<VMID>.conf`.
   * Esegue il *Pre-flight check* dello spazio su ZFS target (`zfs get available`).
   * Supporta modalità **One-shot** (`sync`) o **Ricorsiva** (`create` tramite cron).
   * Applica le azioni post-migrazione selezionate (*Nessuna azione*, *Switchover completo* con `pct stop/start`, o *Shutdown sorgente*).
2. **Wizard Chiavi SSH Passwordless:** Genera ed esporta le chiavi SSH pubbliche verso il nodo target.
3. **Gestisci / Elimina Job pve-zsync:** Legge i task attivi con `pve-zsync list` e consente la rimozione pulita tramite `pve-zsync destroy --name <job_name>`.
4. **Confronta Configurazione:** Scarica `/tmp/<VMID>_remote.conf` dal target via SCP ed esegue un `diff -u` rispetto alla configurazione locale mostrandone le discrepanze (RAM, CPU, storage, ecc.).
5. **Configura Notifiche (Telegram & Email):** Interfaccia per l'impostazione dei parametri di alert.
6. **Guida e Help:** Consultazione rapida della documentazione e delle istruzioni integrate.
7. **Esci:** Chiusura pulita della TUI.