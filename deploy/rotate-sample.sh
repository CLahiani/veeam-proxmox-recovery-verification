#!/usr/bin/env bash
# Daily rotation: verify 3 different VMs each day from a list (one name per line in vms.txt).
# Use as ExecStart in the systemd unit instead of a fixed --vm list:
#   ExecStart=/opt/veeam-recovery-verification/deploy/rotate-sample.sh
set -euo pipefail
cd /opt/veeam-recovery-verification
mapfile -t ALL < <(grep -v '^\s*#' vms.txt | grep -v '^\s*$')
N=${#ALL[@]}; D=$(date +%j); ARGS=()
for i in 0 1 2; do ARGS+=(--vm "${ALL[$(( (D*3 + i) % N ))]}"); done
exec /usr/bin/python3 ./pve_backup_boot.py --config ./RecoveryVerification.json --secrets-file /root/.veeam-rv-secrets.json \
     --report-dir /var/lib/veeam-recovery-verification/reports --cleanup "${ARGS[@]}"
