#!/bin/bash

# Interrompi lo script in caso di errore
set -e

# Assicurati di essere eseguito come root
if [ "$EUID" -ne 0 ]; then
  echo "Per favore, esegui questo script con i privilegi di root (sudo)."
  exit 1
fi

SERVICE_NAME="tika-service"
STATE_DIR="/var/lib/tika"
INSTALL_DIR="/opt/tika"
JAR_PATH="${INSTALL_DIR}/tika-server.jar"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Versione di Tika da scaricare (compatibile con Java 21)
TIKA_VERSION="3.3.2"
TIKA_URL="https://archive.apache.org/dist/tika/${TIKA_VERSION}/tika-server-standard-${TIKA_VERSION}.jar"

echo "=== Controllo installazioni precedenti ==="

# 1. Rimozione vecchio servizio systemd
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

# 2. Rimozione vecchia cartella dati/log
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

# --- Installazione di Java 21 e dipendenze ---
echo ""
echo "=== Installazione Java 21 e curl (se mancanti) ==="
apt-get update
apt-get install -y openjdk-21-jdk-headless curl

# --- Download di Apache Tika Server ---
echo ""
echo "=== Download di Apache Tika v${TIKA_VERSION} ==="
mkdir -p "$INSTALL_DIR"

if [ -f "$JAR_PATH" ]; then
    echo "Il file tika-server.jar esiste già in ${INSTALL_DIR}."
    read -p "Vuoi scaricarlo nuovamente/aggiornarlo? (s/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        curl -L -o "$JAR_PATH" "$TIKA_URL"
        echo "✓ Tika JAR aggiornato."
    fi
else
    echo "Scaricamento di Tika in corso..."
    curl -L -o "$JAR_PATH" "$TIKA_URL"
    echo "✓ Download completato."
fi

# --- Configurazione Interattiva ---
echo ""
read -p "Inserire porta (default: 9998): " PORT
PORT=${PORT:-9998}

read -p "Indirizzo IP da bindare (0.0.0.0 per tutti, localhost per locale): " BIND
BIND=${BIND:-0.0.0.0}

# --- Configurazione Ambiente e Utente ---
mkdir -p "$STATE_DIR"

if ! id "tika" &>/dev/null; then
    useradd -r -s /bin/false tika
    echo "Creato utente di sistema 'tika'."
fi

chown -R tika:tika "$STATE_DIR"
chown -R tika:tika "$INSTALL_DIR"

# --- Creazione Unit File Systemd ---
cat > "$UNIT_FILE" << EOF
[Unit]
Description=Apache Tika Full-Text Search Service
After=network.target

[Service]
Type=simple
User=tika
Group=tika
ExecStart=/usr/bin/java -jar ${JAR_PATH} -h ${BIND} -p ${PORT}
ExecStop=/bin/kill -15 \$MAINPID
StandardOutput=append:${STATE_DIR}/tika.log
StandardError=append:${STATE_DIR}/tika.log
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Ricarica systemd
systemctl daemon-reload

# --- Avvio e Test ---
echo ""
echo "=== Avvio servizio Tika ==="
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}

echo "Attendo l'avvio del servizio..."
sleep 5

if systemctl is-active --quiet ${SERVICE_NAME}; then
    echo -e "\n✓ Servizio avviato con successo!"
    
    echo "=== Test di Funzionamento ==="
    if curl -s -o /dev/null -w "%{http_code}" http://${BIND}:${PORT}/ | grep -q "200"; then
        echo "✓ Tika è raggiungibile e risponde correttamente sulla porta ${PORT}!"
        
        echo -e "\n--- URL di accesso ---"
        echo "URL locale:   http://localhost:${PORT}"
        echo "URL rete:     http://${BIND}:${PORT}"
        
        echo -e "\n--- Verifica stato servizio ---"
        systemctl status ${SERVICE_NAME} --no-pager
    else
        echo "✗ Avviso: Il servizio è attivo ma la root HTTP non ha risposto con 200 OK (potrebbe essere in fase di warm-up)."
    fi
else
    echo "✗ Errore: Il servizio non si è avviato!"
    echo "Controllo log di systemd:"
    journalctl -u ${SERVICE_NAME} --no-pager -n 50
fi

echo -e "\n--- Fine configurazione Tika ---"
