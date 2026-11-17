#!/usr/bin/env bash
# heap-lab: kubeconfig.sh
# Fetch an admin kubeconfig from every node that has one, pointed at that
# node's forwarded API port on the Mac:
#   .state/kube/new.yaml     greene  (context heap-lab)        the new cluster
#   .state/kube/crosby.yaml  crosby  (context heap-lab-crosby) experiment, then new
#   .state/kube/old.yaml     broome  (context heap-lab-old)    the old cluster
# A file whose node no longer serves an API (broome after its teardown) is
# removed. Nothing outside .state/ is written.
set -euo pipefail
_TAG=kubeconfig
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "${KUBE_DIR}"

fetch() {  # node file context
    local n="$1" f="${KUBE_DIR}/$2" ctx="$3" tmp
    tmp=$(mktemp)
    if on "$n" 'sudo test -f /etc/rancher/k3s/k3s.yaml && sudo cat /etc/rancher/k3s/k3s.yaml' >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        sed -e "s#https://127.0.0.1:6443#https://127.0.0.1:$(api_port "$n")#" \
            -e "s/: default\$/: ${ctx}/" "$tmp" > "$f"
        chmod 600 "$f"
    else
        rm -f "$f"
    fi
    rm -f "$tmp"
}
fetch greene new.yaml    heap-lab
fetch crosby crosby.yaml heap-lab-crosby
fetch broome old.yaml    heap-lab-old
ls "${KUBE_DIR}" | sed 's/^/  /'
