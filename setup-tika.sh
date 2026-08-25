#!/bin/bash

# Interrompi lo script in caso di errore
set -e

SERVICE_NAME="tika-service"
STATE_DIR="/var/lib/tika"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "=== Controllo installazioni precedenti ==="

# 1. Controllo ed eventuale rimozione del servizio systemd esistente
if [ -f "$UNIT_FILE" ] || systemctl list-unit-files | grep -q "^${SERVICE_NAME}\.service"; then
    echo "Trovato un servizio systemd esistente (${SERVICE_NAME})."
    read -p "Vuoi rimuoverlo e sovrascriverlo? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        echo "Arresto e disinstallazione del vecchio servizio..."
        systemctl stop ${SERVICE_NAME} 2>/dev/null || true
        systemctl disable ${SERVICE_NAME} 2>/dev/null || true
        rm -f "$UNIT_FILE"
        systemctl daemon-reload
        systemctl reset-failed
        echo "✓ Vecchio servizio rimosso."
    else
        echo "Operazione annullata dall'utente."
        exit 1
    fi
fi

# 2. Controllo ed eventuale rimozione della cartella di stato/log esistente
if [ -d "$STATE_DIR" ]; then
    echo "Trovata la directory dei dati esistente (${STATE_DIR})."
    read -p "Vuoi eliminare anche i dati e i log esistenti? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        rm -rf "$STATE_DIR"
        echo "✓ Directory ${STATE_DIR} eliminata."
    else
        echo "Mantenimento della directory esistente."
    fi
fi

# --- Configurazione Interattiva ---
echo ""
read -p "Inserire porta (default: 9998): " PORT
PORT=${PORT:-9998}

read -p "Indirizzo IP da bindare (0.0.0.0 per tutti, localhost per locale): " BIND
BIND=${BIND:-0.0.0.0}

# --- Configurazione del Servizio Tika ---
LOG_FILE="${STATE_DIR}/tika.log"
JAR_PATH="/opt/tika/tika-server.jar" # Modifica con il percorso reale del tuo jar

# Creazione directory di stato
mkdir -p "$STATE_DIR"

# Creazione utente di sistema dedicato (se non esiste)
if ! id "tika" &>/dev/null; then
    useradd -r -s /bin/false tika
    echo "Creato utente di sistema 'tika'."
fi

chown -R tika:tika "$STATE_DIR"

# --- Creazione Unit File Systemd ---
cat > "$UNIT_FILE" << 'EOF'
[Unit]
Description=Apache Tika Full-Text Search Service
After=network.target

[Service]
Type=simple
User=tika
Group=tika
ExecStart=/usr/bin/java -jar /opt/tika/tika-server.jar -h ${BIND} -p ${PORT}
ExecStop=/bin/kill -15 $MAINPID
StandardOutput=append:/var/lib/tika/tika.log
StandardError=append:/var/lib/tika/tika.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Ricarica systemd per recepire il nuovo servizio
systemctl daemon-reload

# --- Test di Funzionamento ---
echo "=== Avvio servizio Tika ==="
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}

echo "Attendo l'avvio del servizio..."
sleep 5

if systemctl is-active --quiet ${SERVICE_NAME}; then
    echo -e "\n✓ Servizio avviato con successo!"
    
    echo "=== Test di Funzionamento ==="
    if curl -s -o /dev/null -w "%{http_code}" http://${BIND}:${PORT}/ | grep -q "200"; then
        echo "✓ Tika è raggiungibile!"
        
        echo -e "\n--- URL di accesso ---"
        echo "URL locale:   http://localhost:${PORT}"
        echo "URL rete:     http://${BIND}:${PORT}"
        
        echo -e "\n--- Verifica stato servizio ---"
        systemctl status ${SERVICE_NAME} --no-pager
    else
        echo "✗ Avviso: Il servizio è attivo ma non risponde ancora alla HTTP GET sulla root (potrebbe richiedere un endpoint specifico o essere in fase di warm-up)."
    fi
else
    echo "✗ Errore: Il servizio non si è avviato!"
    echo "Controllo log di systemd:"
    journalctl -u ${SERVICE_NAME} --no-pager -n 50
fi

echo -e "\n--- Fine configurazione Tika ---"
