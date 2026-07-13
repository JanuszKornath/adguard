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

on_error() {
  log "FEHLER: Sync abgebrochen (Zeile $1)"
  fail_mail "AdGuard Sync auf $(hostname) fehlgeschlagen (Zeile $1). Details: $LOGFILE"
}
trap 'on_error $LINENO' ERR

log "=== Sync gestartet ==="

# 1. Filter-Daten (Listen) synchronisieren
# sessions.db und leases* sind slave-spezifisch (Web-Logins, DHCP) und bleiben lokal
log "Sync filter data..."
rsync -az --delete -e "ssh $SSH_OPTS" \
  --exclude 'stats*' --exclude 'querylog*' --exclude '*.log' \
  --exclude 'sessions.db' --exclude 'leases*' \
  "$MASTER_FILTER_DIR/" "$SLAVE:$SLAVE_BASE/data/"

# 2. Master Config zum Slave übertragen (in privates Temp-Verzeichnis statt
# vorhersagbarer /tmp-Pfade)
log "Transfer Master YAML..."
REMOTE_TMP=$(ssh $SSH_OPTS "$SLAVE" 'mktemp -d')
# Remote-Tempdir auch aufräumen, wenn das Master-Skript vor dem
# Remote-Teil abbricht (dessen eigener EXIT-Trap greift dann nie)
trap 'ssh $SSH_OPTS "$SLAVE" "rm -rf \"$REMOTE_TMP\"" 2>/dev/null || true' EXIT
rsync -az -e "ssh $SSH_OPTS" \
  "$MASTER_CONFIG" \
  "$SLAVE:$REMOTE_TMP/adguard_master.yaml"

# 3. Merge + Validation auf dem Slave
log "Merge and validate on Slave..."

ssh $SSH_OPTS "$SLAVE" "REMOTE_TMP='$REMOTE_TMP' bash -s" << 'EOF' 2>&1 | tee -a "$LOGFILE"
set -euo pipefail

# Nicht-interaktive SSH-Sitzungen haben oft einen minimalen PATH ohne
# /usr/local/bin (üblicher Ort für manuell installiertes yq)
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

CFG="/opt/AdGuardHome/AdGuardHome.yaml"
BIN="/opt/AdGuardHome/AdGuardHome"

# Temp-Verzeichnis auch bei Fehlschlag aufräumen
trap 'rm -rf "$REMOTE_TMP"' EXIT

# Master-Body passt nur zur gleichen Schema-Version; bei Drift nicht mergen
MASTER_SCHEMA=$(yq eval '.schema_version' "$REMOTE_TMP/adguard_master.yaml")
SLAVE_SCHEMA=$(yq eval '.schema_version' "$CFG")
if [ "$MASTER_SCHEMA" != "$SLAVE_SCHEMA" ]; then
  echo "Schema-Version Master ($MASTER_SCHEMA) != Slave ($SLAVE_SCHEMA). Abbruch." >&2
  printf 'Schema-Version Master (%s) != Slave (%s). AdGuardHome-Versionen angleichen.\n' \
    "$MASTER_SCHEMA" "$SLAVE_SCHEMA" | mail -s "AdGuard Sync Fehler auf $(hostname)" root
  exit 1
fi

# Backup der aktuellen Slave-Config erstellen
cp "$CFG" "${CFG}.backup"

# Lokale Slave-Identität sichern (Netzwerk, User UND Schema-Version).
# Keys, die auf dem Slave fehlen (z. B. bind_host vs. bind_hosts je nach
# Schema-Version), würden als null gemergt und die Config zerschießen —
# deshalb null-Werte entfernen.
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
} | del(.. | select(. == null))' "$CFG" > "$REMOTE_TMP/adguard_local.yaml"

# Master-Config strippen (alles entfernen, was wir vom Slave behalten wollen)
yq eval '
  del(.http) |
  del(.users) |
  del(.schema_version) |
  del(.dns.bind_host) |
  del(.dns.bind_hosts) |
  del(.dns.port)
' "$REMOTE_TMP/adguard_master.yaml" > "$REMOTE_TMP/adguard_master_stripped.yaml"

# Zusammenführen: Master-Daten bilden die Basis, Slave-Spezifika überschreiben diese
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
  "$REMOTE_TMP/adguard_master_stripped.yaml" "$REMOTE_TMP/adguard_local.yaml" \
  > "$REMOTE_TMP/adguard_merged.yaml"

# Erst validieren, dann die aktive Config ersetzen — so bleibt sie bei
# jedem Fehler unangetastet
if ! "$BIN" --check-config -c "$REMOTE_TMP/adguard_merged.yaml" > "$REMOTE_TMP/config_test.log" 2>&1; then
  echo "AdGuard Config ungueltig. Aktive Config bleibt unveraendert." >&2
  mail -s "AdGuard Sync Fehler auf $(hostname)" root < "$REMOTE_TMP/config_test.log"
  exit 1
fi

# cat statt mv/cp, damit Inode, Owner und Rechte von $CFG erhalten bleiben
if ! cat "$REMOTE_TMP/adguard_merged.yaml" > "$CFG"; then
  cp "${CFG}.backup" "$CFG"
  echo "Schreiben der Config fehlgeschlagen. Backup wiederhergestellt." >&2
  exit 1
fi

# Dienst neu starten; schlägt das trotz gültiger Config fehl, Backup
# zurückspielen und erneut starten — DNS ist kritische Infrastruktur
if ! systemctl restart AdGuardHome; then
  echo "Neustart fehlgeschlagen. Rollback auf Backup..." >&2
  cp "${CFG}.backup" "$CFG"
  systemctl restart AdGuardHome
  exit 1
fi

echo "AdGuardHome erfolgreich zusammengefuehrt und neu gestartet."
EOF

log "=== Sync erfolgreich beendet ==="
