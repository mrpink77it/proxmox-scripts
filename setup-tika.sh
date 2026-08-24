#!/bin/bash

# Script di configurazione Tika con systemd
# --- Configurazione Interattiva ---

read -p "Inserire porta (default: 9998) [Tika usa spesso HTTP port]: " PORT
PORT=${PORT:-9998}

read -p "Indirizzo IP da bindare (0.0.0.0 per tutti, localhost per locale, IP specifico): " BIND
BIND=${BIND:-0.0.0.0}

# --- Configurazione del Servizio Tika ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="tika-service"
STATE_DIR="/var/lib/tika"
LOG_FILE="${STATE_DIR}/tika.log"

mkdir -p "$STATE_DIR"

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Tika Full-Text Search Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/usr/bin/java -jar tika-server.jar --port ${PORT} --http.address ${BIND}
ExecStop=/bin/kill -15 \$MAINPID
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- Test di Funzionamento ---

echo "=== Avvio servizio Tika ==="
systemctl enable ${SERVICE_NAME} 2>/dev/null || echo "Abilitato automaticamente se systemd è attivo"

systemctl start ${SERVICE_NAME}
sleep 5

if systemctl is-active --quiet ${SERVICE_NAME}; then
    echo ""
    echo "✓ Servizio avviato con successo!"
    
    echo "=== Test di Funzionamento ==="
    # Verifica che il servizio sia rispondente
    if curl -s -o /dev/null -w "%{http_code}" http://\${BIND}:\${PORT}/; then
        echo "✓ Tika è raggiungibile!"
        echo ""
        echo "=== Istruzioni per Collegamento a Tika ==="
        
        echo ""
        echo "--- URL di accesso ---"
        echo "URL locale:   http://localhost:${PORT}"
        echo "URL rete:     http://${BIND}:${PORT}"
        echo ""
        
        echo "--- API REST ---"
        echo "Health check:  http://\${BIND}:\${PORT}/health"
        echo "Analyze file:  http://\${BIND}:\${PORT}/service/analyze?file=/path/to/file"
        echo "Extract text:  http://\${BIND}:\${PORT}/extract"
        echo ""
        
        echo "--- Esempio di chiamata API ---"
        echo 'curl -X POST http://localhost:${PORT}/analyze \\\\"content=yourtext\\\""'
        echo ""
        
        echo "--- Verifica stato servizio ---"
        systemctl status ${SERVICE_NAME} --no-pager
        echo ""
        echo "--- Logs in tempo reale (tail) ---"
        tail -f ${LOG_FILE} 2>/dev/null || echo "Log non disponibili"
        
    else
        echo "✗ Errore: Tika non risponde!"
        echo "Controllare log:"
        journalctl -u ${SERVICE_NAME} --no-pager -n 50 || cat ${LOG_FILE} 2>/dev/null
    fi
    
else
    echo "✗ Errore: Il servizio non si è avviato!"
    echo "Controllare log:"
    journalctl -u ${SERVICE_NAME} --no-pager -n 50 || tail -f /var/log/syslog | grep tika 2>/dev/null || cat ${LOG_FILE} 2>/dev/null
fi

echo ""
echo "--- Fine configurazione Tika ---"
