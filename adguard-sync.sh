#!/bin/bash
set -euo pipefail

# CONFIG
MASTER_CONFIG="/opt/AdGuardHome/AdGuardHome.yaml"
MASTER_FILTER_DIR="/opt/AdGuardHome/data"
SLAVE="adguard-syn@192.168.178.246"
SLAVE_BASE="/opt/AdGuardHome"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

LOGFILE="/var/log/adguard-sync.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

log "=== Sync gestartet ==="

# 1. Filter-Daten (Listen-Inhalte) spiegeln
log "Sync filter data..."
rsync -avz --delete -e "ssh $SSH_OPTS" \
  --exclude 'stats*' --exclude 'querylog*' --exclude '*.log' \
  "$MASTER_FILTER_DIR/" "$SLAVE:$SLAVE_BASE/data/" > /dev/null

# 2. Master-Config auf Slave werfen
log "Transfer Master YAML..."
rsync -az -e "ssh $SSH_OPTS" "$MASTER_CONFIG" "$SLAVE:/tmp/adguard_master.yaml"

# 3. Mergen und Restart auf dem Slave
log "Merge and Restart on Slave..."
ssh $SSH_OPTS "$SLAVE" << 'EOF'
  set -euo pipefail
  # Lokale Sektionen sichern (damit IP/Web-Port des Slaves erhalten bleiben)
  yq eval '. | pick(["http", "dns", "users"])' /opt/AdGuardHome/AdGuardHome.yaml > /tmp/adguard_local.yaml
  # Master-Config vorbereiten (Lokales entfernen)
  yq eval 'del(.http) | del(.dns) | del(.users)' /tmp/adguard_master.yaml > /tmp/adguard_master_stripped.yaml
  # Zusammenfügen
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
    /tmp/adguard_master_stripped.yaml /tmp/adguard_local.yaml > /opt/AdGuardHome/AdGuardHome.yaml
  
  # Aufräumen & Restart
  rm -f /tmp/adguard_master.yaml /tmp/adguard_master_stripped.yaml /tmp/adguard_local.yaml
  systemctl restart AdGuardHome
  echo "AdGuardHome restarted."
EOF

log "=== Sync erfolgreich beendet ==="
