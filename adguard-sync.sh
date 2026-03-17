#!/bin/bash
set -euo pipefail

# CONFIG
MASTER_CONFIG="/opt/AdGuardHome/AdGuardHome.yaml"
MASTER_FILTER_DIR="/opt/AdGuardHome/data"
SLAVE="adguard-sync@192.168.178.246"
SLAVE_BASE="/opt/AdGuardHome"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

LOGFILE="/var/log/adguard-sync.log"
MAIL="root"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

fail_mail() {
  echo "$1" | mail -s "AdGuard Sync Fehler" "$MAIL"
}

log "=== Sync gestartet ==="

# 1. Filter-Daten (Listen) synchronisieren
log "Sync filter data..."
rsync -avz --delete -e "ssh $SSH_OPTS" \
  --exclude 'stats*' --exclude 'querylog*' --exclude '*.log' \
  "$MASTER_FILTER_DIR/" "$SLAVE:$SLAVE_BASE/data/" > /dev/null

# 2. Master Config zum Slave übertragen (als temporäre Datei)
log "Transfer Master YAML..."
rsync -az -e "ssh $SSH_OPTS" \
  "$MASTER_CONFIG" \
  "$SLAVE:/tmp/adguard_master.yaml"

# 3. Merge + Validation auf dem Slave
log "Merge and validate on Slave..."

ssh $SSH_OPTS "$SLAVE" << 'EOF'
set -euo pipefail

CFG="/opt/AdGuardHome/AdGuardHome.yaml"
BIN="/opt/AdGuardHome/AdGuardHome"

# Backup der aktuellen Slave-Config erstellen
cp "$CFG" "${CFG}.backup"

# Lokale Slave-Identität sichern (Netzwerk, User UND Schema-Version)
# Wir speichern das in einer Hilfsdatei
yq eval '
{
  "http": .http, 
  "users": .users, 
  "schema_version": .schema_version, 
  "dns": {
    "bind_host": .dns.bind_host, 
    "bind_hosts": .dns.bind_hosts, 
    "port": .dns.port
  }
}' "$CFG" > /tmp/adguard_local.yaml

# Master-Config strippen (alles entfernen, was wir vom Slave behalten wollen)
yq eval '
  del(.http) | 
  del(.users) | 
  del(.schema_version) | 
  del(.dns.bind_host) | 
  del(.dns.bind_hosts) | 
  del(.dns.port)
' /tmp/adguard_master.yaml > /tmp/adguard_master_stripped.yaml

# Zusammenführen: Master-Daten bilden die Basis, Slave-Spezifika überschreiben diese
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' /tmp/adguard_master_stripped.yaml /tmp/adguard_local.yaml > "$CFG"

# Konfiguration auf Validität prüfen
if ! "$BIN" --check-config -c "$CFG" > /tmp/adguard_config_test.log 2>&1; then
  echo "AdGuard Config ungueltig. Rollback wird ausgefuehrt."
  cp "${CFG}.backup" "$CFG"
  # Fehlermeldung per Mail versenden (lokal auf Slave)
  mail -s "AdGuard Sync Fehler auf $(hostname)" root < /tmp/adguard_config_test.log
  exit 1
fi

# Dienst neu starten, falls Test erfolgreich
systemctl restart AdGuardHome

# Temporäre Dateien aufräumen
rm -f /tmp/adguard_master.yaml /tmp/adguard_master_stripped.yaml /tmp/adguard_local.yaml /tmp/adguard_config_test.log

echo "AdGuardHome erfolgreich zusammengefuehrt und neu gestartet."
EOF

log "=== Sync erfolgreich beendet ==="
