# PVE-Zsync Manager

**PVE-Zsync Manager** è uno script Bash avanzato con interfaccia TUI (`whiptail`) progettato specificamente per ambienti **Proxmox VE (PVE)**. Semplifica, automatizza e protegge la gestione, la clonazione e la sincronizzazione dei container LXC sfruttando l'utility nativa `pve-zsync` e i volumi ZFS.

---

## 🚀 Caratteristiche Principali

* **Interfaccia TUI Intuitiva:** Navigazione pulita con pulsanti standardizzati (`<Seleziona>`, `<Avanti>`, `<Indietro>`, `<Esci>`) per evitare uscite accidentali.
* **Scansione Automatica dei Nodi:** Rilevamento dei nodi sia all'interno di un cluster Proxmox (`pvesh`) sia tramite scansione di rete LAN sulla porta `8006` per nodi isolati.
* **Wizard Chiavi SSH:** Configurazione automatica e assistita dello scambio di chiavi RSA (`ssh-copy-id`) per abilitare connessioni sicure e passwordless.
* **Pre-flight Checks:** Verifiche preliminari dello spazio libero disponibile sul pool ZFS del nodo di destinazione prima di avviare il trasferimento dei dati.
* **Rilevamento e Mappatura Storage Target:** Interrogazione dinamica via SSH degli storage attivi sul nodo remoto (`pvesm status`) e risoluzione automatica del pool ZFS associato.
* **Adattamento Automatico del File `.conf` (Rewriting):** Se lo storage o il VMID sul target differiscono, lo script modifica automaticamente i parametri dei volumi (`rootfs:`, `mp0:`, ecc.) nel file di configurazione per garantire la coerenza e l'immediata avviabilità del container.
* **Dashboard in Tempo Reale (Dual-Area):** Monitoraggio avanzato durante le sincronizzazioni lunghe diviso in due sezioni:
  1. *Area Superiore:* Barra di avanzamento percentuale dinamica calcolata tramite polling dei byte scritti (`zfs get written`) e statistiche dei dati trasferiti.
  2. *Area Inferiore:* Log esteso in tempo reale con le ultime righe di esecuzione dei comandi ZFS e `pve-zsync`.
* **Azioni Post-Sincronizzazione:** Opzioni per spegnere il container sorgente, avviare il container sul target (Switchover) o non effettuare alcuna azione.
* **Gestione Job `pve-zsync`:** Visualizzazione ed eliminazione rapida dei job di sincronizzazione schedulati attivi.
* **Confronto Configurazioni:** Download del file `.conf` remoto ed esecuzione di un `diff -u` per evidenziare differenze rispetto alla sorgente.
* **Notifiche Multicanale:** Invio automatico di report dettagliati di successo o errore tramite **Telegram** (tramite Bot personalizzato) ed **Email** (`mailutils`).

---

## 📦 Requisiti di Sistema

Lo script richiede un nodo **Proxmox VE** basato su storage **ZFS** ed esegue automaticamente l'installazione delle dipendenze necessarie se non presenti:
* `whiptail`
* `pve-zsync`
* `nmap`
* `sshpass`
* `diffutils`
* `pv`
* `mbuffer`
* `mailutils`
* `curl`
* `jq`

---

## ⚙️ Installazione e Configurazione

1. Salvare lo script sul nodo Proxmox (ad esempio come `/usr/local/bin/pve-zsync-manager.sh`).
2. Rendere lo script eseguibile:
   ```bash
   chmod +x /usr/local/bin/pve-zsync-manager.sh
   ```
3. Eseguire lo script con i privilegi di root:
   ```bash
   sudo /usr/local/bin/pve-zsync-manager.sh
   ```

---

## 🤖 Configurazione delle Notifiche Telegram

Per abilitare le notifiche istantanee via Telegram:
1. Aprire Telegram e cercare l'utente **`@BotFather`**.
2. Inviare il comando `/newbot` e seguire le istruzioni per assegnare un nome al bot.
3. Copiare il **Token HTTP API** fornito da BotFather.
4. Per recuperare il proprio **Chat ID** numerico, cercare su Telegram **`@userinfobot`**, avviarlo con `/start` e copiare l'ID numerico restituito.
5. All'interno dello script, accedere alla voce di menu **"Configura Notifiche (Telegram & Email)"** e inserire i dati richiesti (verranno salvati in `/etc/pve-zsync-tui.conf`).

---

## 🛠️ Struttura del Menu Principale

1. **Sincronizza / Clona Container LXC:** Avvia il wizard guidato di selezione container, connessione target, selezione storage, mapping VMID, pre-flight checks, scelta della modalità (one-shot o job periodico) e visualizza la dashboard in tempo reale.
2. **Wizard Chiavi SSH Passwordless:** Configura l'accesso SSH senza password tra il nodo locale e il target.
3. **Gestisci / Elimina Job pve-zsync:** Mostra l'elenco dei job attivi e consente la rimozione pulita dei job non più necessari.
4. **Confronta Configurazione (Sorgente vs Target):** Esegue il diff tra il file `.conf` locale e quello remoto.
5. **Configura Notifiche (Telegram & Email):** Gestisce i parametri di invio dei report.
6. **Guida e Help:** Mostra la documentazione integrata e le istruzioni di configurazione del bot Telegram.
7. **Esci:** Termina l'esecuzione dello script ripulendo l'interfaccia.