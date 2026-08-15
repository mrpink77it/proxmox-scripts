# 🛠️ Proxmox Tools & Scripts

![Status](https://img.shields.io/badge/Status-Work_in_Progress-orange)
![Language](https://img.shields.io/badge/Language-Bash-4EAA25)
![License](https://img.shields.io/badge/License-MIT-blue)

Una raccolta di utilità shell e script di automazione per **Proxmox Virtual Environment (VE)**.

## 📖 Descrizione del Progetto

Questo repository nasce come "raccoglitore" personale di strumenti, snippet e script creati per automatizzare compiti specifici, velocizzare il workflow e risolvere necessità pratiche sui miei nodi Proxmox. 

⚠️ **Stato del progetto: Sempre in WIP (Work in Progress).**
Non si tratta di una suite software statica e preconfezionata, ma di una cassetta degli attrezzi in continua espansione. Gli script vengono aggiunti, affinati o aggiornati man mano che ne ho bisogno per amministrare le mie macchine.

## 🚀 Cosa contiene

La raccolta si arricchisce col tempo. Attualmente include strumenti per:
- **LXC & Host Auto-Updater**: Uno script Bash che si occupa di aggiornare l'host Proxmox e, in cascata, tutti i container LXC basati sui *Proxmox VE Helper-Scripts*, gestendo eccezioni custom (come l'esclusione di Nginx) con un output visuale in ASCII art.


## 💻 Tecnologie e Requisiti

- **Linguaggio principale:** Bash / Shell Scripting.
- **Ambiente di esecuzione:** Progettati per essere eseguiti direttamente dalla shell di root dell'host Proxmox VE.
- Alcuni script gestiscono autonomamente l'installazione di piccole dipendenze visive (es. `figlet`).

## ⚠️ Disclaimer

Tutti gli script sono forniti "così come sono" (AS IS). Sebbene siano utilizzati e testati regolarmente nel mio ambiente, **sei caldamente invitato a leggere e comprendere il codice sorgente** prima di eseguirlo sui tuoi server, specialmente se in produzione. Non mi assumo alcuna responsabilità per eventuali malfunzionamenti o perdite di dati.

## 📄 Licenza

Questo progetto è distribuito sotto licenza **MIT**. Sei libero di utilizzare, modificare e distribuire il codice, anche per scopi commerciali, mantenendo l'attribuzione originale.


