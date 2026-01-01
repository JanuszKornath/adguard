#!/bin/bash
set -euo pipefail

#####################################
# CONFIG
#####################################

MASTER_CONFIG="/opt/AdGuardHome/AdGuardHome.yaml"
MASTER_FILTER_DIR="/opt/AdGuardHome/data"

SLAVE="root@192.168.178.246"
SLAVE_BASE="/opt/AdGuardHome"
SLAVE_CONFIG="$SLAVE_BASE/AdGuardHome.yaml"
SLAVE_FILTER_DIR="$SLAVE_BASE/data"

SSH_KEY="/root/.ssh/id_ed25519_adguard"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
RSYNC_SSH="ssh $SSH_OPTS"

LOGFILE="/var/log/adguard-sync.log"

#####################################
# FUNCTIONS
#####################################

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

fatal() {
  log "FATAL: $*"
  exit 1
}

#####################################
# START
#####################################

log "=============================="
log "AdGuard sync start"

log "Check yq version"
yq --version 2>&1 | tee -a "$LOGFILE"

log "Check SSH connectivity"
ssh $SSH_OPTS "$SLAVE" "echo SSH_OK" || fatal "SSH connection failed"

#####################################
# SYNC FILTER DATA
#####################################

log "Sync filter data files (excluding stats and logs)"
rsync -av --delete \
  -e "$RSYNC_SSH" \
  --exclude 'stats*' \
  --exclude 'querylog*' \
  --exclude '*.log' \
  "$MASTER_FILTER_DIR/" \
  "$SLAVE:$SLAVE_FILTER_DIR/" \
  | tee -a "$LOGFILE"

log "Filter data sync finished"

#####################################
# COPY MASTER YAML TO SLAVE
#####################################

log "Copy master YAML to slave temp location"
rsync -av -e "$RSYNC_SSH" \
  "$MASTER_CONFIG" \
  "$SLAVE:/tmp/adguard_master.yaml" \
  | tee -a "$LOGFILE"

log "Verify master YAML on slave"
ssh $SSH_OPTS "$SLAVE" "
  set -e
  ls -l /tmp/adguard_master.yaml
  yq eval '.schema_version' /tmp/adguard_master.yaml
" | tee -a "$LOGFILE"

#####################################
# MERGE YAML ON SLAVE
#####################################

log "Merge YAML on slave (keep http, dns, users local)"
ssh $SSH_OPTS "$SLAVE" <<"EOF"
set -euo pipefail

echo "[MERGE] Backup current YAML"
cp /opt/AdGuardHome/AdGuardHome.yaml \
   /opt/AdGuardHome/AdGuardHome.yaml.bak.$(date +%F_%H-%M-%S)

echo "[MERGE] Extract local sections (http,dns,users)"
# Neue Syntax ohne geschweifte Klammern
yq eval '. | pick(["http", "dns", "users"])' \
  /opt/AdGuardHome/AdGuardHome.yaml \
  > /tmp/adguard_local.yaml

echo "[MERGE] Remove local sections from master YAML"
yq eval 'del(.http) | del(.dns) | del(.users)' \
  /tmp/adguard_master.yaml \
  > /tmp/adguard_master_stripped.yaml

echo "[MERGE] Merge master with local sections"
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
  /tmp/adguard_master_stripped.yaml /tmp/adguard_local.yaml \
  > /tmp/AdGuardHome.yaml.new

echo "[MERGE] Validate merged YAML"
yq eval '.schema_version' /tmp/AdGuardHome.yaml.new >/dev/null

echo "[MERGE] Install merged YAML"
cp /tmp/AdGuardHome.yaml.new /opt/AdGuardHome/AdGuardHome.yaml

echo "[MERGE] Cleanup temporary files"
rm -f /tmp/adguard_master.yaml /tmp/adguard_master_stripped.yaml \
      /tmp/adguard_local.yaml /tmp/AdGuardHome.yaml.new

echo "[MERGE] Cleanup old backups: Keeping only the 7 most recent"
ls -1tr /opt/AdGuardHome/AdGuardHome.yaml.bak.* 2>/dev/null | head -n -7 | xargs -d '\n' rm -f || true

echo "[MERGE] Done"
EOF

#####################################
# RESTART ADGUARD
#####################################

log "Restart AdGuardHome on slave"
ssh $SSH_OPTS "$SLAVE" "
  systemctl restart AdGuardHome
  systemctl is-active AdGuardHome
" | tee -a "$LOGFILE"

log "AdGuard sync finished successfully"
