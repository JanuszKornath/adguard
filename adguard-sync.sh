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

# 1. Filter-Daten synchronisieren
log "Sync filter data..."

rsync -avz --delete -e "ssh $SSH_OPTS" \
  --exclude 'stats*' --exclude 'querylog*' --exclude '*.log' \
  "$MASTER_FILTER_DIR/" "$SLAVE:$SLAVE_BASE/data/" > /dev/null

# 2. Master Config übertragen
log "Transfer Master YAML..."

rsync -az -e "ssh $SSH_OPTS" \
  "$MASTER_CONFIG" \
  "$SLAVE:/tmp/adguard_master.yaml"

# 3. Merge + Validation auf Slave
log "Merge and validate on Slave..."

ssh $SSH_OPTS "$SLAVE" << 'EOF'
set -euo pipefail

CFG="/opt/AdGuardHome/AdGuardHome.yaml"
BIN="/opt/AdGuardHome/AdGuardHome"

# Backup erstellen
cp "$CFG" "${CFG}.backup"

# Lokale Netzwerk / User Config sichern
yq eval '
.http +
{dns:{bind_host:.dns.bind_host,bind_port:.dns.bind_port}} +
{users:.users}
' "$CFG" > /tmp/adguard_local.yaml

# Master Config vorbereiten (lokale + schema entfernen)
yq eval '
del(.http) |
del(.dns.bind_hosts) |
del(.dns.port) |
del(.users) |
del(.schema_version)
' /tmp/adguard_master.yaml > /tmp/adguard_master_stripped.yaml

# Zusammenführen
yq eval-all '
select(fileIndex == 0) * select(fileIndex == 1)
' /tmp/adguard_master_stripped.yaml /tmp/adguard_local.yaml > "$CFG"

# Config testen
if ! "$BIN" --check-config > /tmp/adguard_config_test.log 2>&1; then

  echo "AdGuard Config ungültig. Rollback." 

  cp "${CFG}.backup" "$CFG"

  mail -s "AdGuard Sync Fehler auf $(hostname)" root < /tmp/adguard_config_test.log

  exit 1
fi

# Restart nur wenn Config ok
systemctl restart AdGuardHome

# Aufräumen
rm -f /tmp/adguard_master.yaml
rm -f /tmp/adguard_master_stripped.yaml
rm -f /tmp/adguard_local.yaml
rm -f /tmp/adguard_config_test.log

echo "AdGuardHome restarted."

EOF
log "=== Sync erfolgreich beendet ==="
