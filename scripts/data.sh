#!/usr/bin/env bash
# heap-lab: data.sh record|check
# Prove broome's /data wasn't touched. Records the file count and one
# checksum over every file's path and contents, leaving out the directories
# the migration writes on purpose (k8s, k8s-migration, lab-canary). `check`
# compares against the last `record` (up.sh records after every build).
# Stronger than heap-check.sh's baseline, which counts entries; run both.
set -euo pipefail
_TAG=data
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

measure() {
    on broome 'sudo bash -s' <<'EOF'
set -euo pipefail
cd /data
sums=$(find . \( -path ./k8s -o -path ./k8s-migration -o -path ./lab-canary -o -path ./lost+found \) -prune \
    -o -type f -print0 | sort -z | xargs -0 sha256sum)
echo "$(printf '%s\n' "$sums" | grep -c .) files, $(printf '%s\n' "$sums" | sha256sum | cut -c1-16)"
EOF
}

case "${1:-check}" in
    record)
        measure > "${STATE_DIR}/data.baseline"
        info "/data baseline: $(cat "${STATE_DIR}/data.baseline")" ;;
    check)
        [ -f "${STATE_DIR}/data.baseline" ] || error "No baseline. task data-record first."
        now=$(measure); was=$(cat "${STATE_DIR}/data.baseline")
        if [ "$now" = "$was" ]; then echo "PASS  /data unchanged ($now)"
        else echo "FAIL  /data changed: was ($was), now ($now)"; exit 1
        fi ;;
    *) error "usage: data.sh record|check" ;;
esac
