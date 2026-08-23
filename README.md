# 🛠️ Proxmox Tools & Scripts

![Status](https://img.shields.io/badge/Status-Work_in_Progress-orange)
![Language](https://img.shields.io/badge/Language-Bash-4EAA25)
![License](https://img.shields.io/badge/License-MIT-blue)

Una raccolta di utilità shell e script di automazione per **Proxmox Virtual Environment (VE)**.

Questo repository nasce come "raccoglitore" personale di strumenti, snippet e script creati per automatizzare compiti specifici, velocizzare il workflow e risolvere necessità pratiche sui miei nodi Proxmox. 

⚠️ **Stato del progetto: Sempre in WIP (Work in Progress).**
Non si tratta di una suite software statica e preconfezionata, ma di una cassetta degli attrezzi in continua espansione. Gli script vengono aggiunti, affinati o aggiornati man mano che ne ho bisogno per amministrare le mie macchine.

## 🚀 Cosa contiene

La raccolta si arricchisce col tempo. Attualmente include strumenti per:
- **LXC & Host Auto-Updater**: Uno script Bash che si occupa di aggiornare l'host Proxmox e, in cascata, tutti i container LXC basati sui *Proxmox VE Helper-Scripts*, gestendo eccezioni custom (come l'esclusione di Nginx) con un output visuale in ASCII art.
- **Multi-Vendor GPU Passthrough Manager (`proxmox-gpu-toggle.sh`)**: Un tool interattivo con interfaccia da terminale (`whiptail`) per automatizzare e semplificare l'assegnazione delle schede video (NVIDIA, AMD, Intel) tra l'host e le VM. Le funzionalità principali includono:
    - **Switch Dinamico**: Passaggio rapido dai driver nativi host (necessari per i container LXC) all'isolamento VFIO-PCI (per il passthrough su VM) senza dover riavviare il nodo Proxmox.
    - **Safe Stop LXC**: Rilevamento dei container attualmente in esecuzione e spegnimento interattivo assistito prima di sganciare i driver della GPU.
    - **Wizard VM Cloud-Init**: Creazione al volo di macchine virtuali di test (Ubuntu 24.04 LTS o Debian 13) completamente autonome, pre-configurate con chipset `q35` per un aggancio PCI Express nativo ottimale.
    - **DUMP vBIOS**: Utility integrata per forzare la lettura e l'estrazione sicura del file ROM direttamente dalla scheda video fisica.
    - **Setup IOMMU**: Verifica e configurazione automatizzata dei parametri di avvio per ambienti basati su ZFS e systemd-boot.

## 💻 Tecnologie e Requisiti

- **Linguaggio principale:** Bash / Shell Scripting.
- **Ambiente di esecuzione:** Progettati per essere eseguiti direttamente dalla shell di root dell'host Proxmox VE.
- Alcuni script gestiscono autonomamente l'installazione o richiedono piccole dipendenze visive preinstallate nel sistema (es. `figlet`, `whiptail`).

## ⚠️ Disclaimer

Tutti gli script sono forniti "così come sono" (AS IS). Sebbene siano utilizzati e testati regolarmente nel mio ambiente, **sei caldamente invitato a leggere e comprendere il codice sorgente** prima di eseguirlo sui tuoi server, specialmente se in produzione. Non mi assumo alcuna responsabilità per eventuali malfunzionamenti o perdite di dati.

## 📄 Licenza

Questo progetto è distribuito sotto licenza **MIT**. Sei libero di utilizzare, modificare e distribuire il codice, anche per scopi commerciali, mantenendo l'attribuzione originale.
