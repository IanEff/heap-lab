#!/usr/bin/env bash
# heap-lab: status.sh: VMs, stage, both clusters, snapshots, /data.
set -uo pipefail
_TAG=status
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limactl list 2>/dev/null | grep -E '^(NAME|heap-)'
echo; info "stage: $(current_stage)   cluster-config: $(repo_ref)"
for f in new crosby old; do
    [ -f "${KUBE_DIR}/${f}.yaml" ] || continue
    echo; info "${f}.yaml ($(sed -n 's/^current-context: //p' "${KUBE_DIR}/${f}.yaml"))"
    KUBECONFIG="${KUBE_DIR}/${f}.yaml" kubectl get nodes -o wide --request-timeout=5s 2>&1 | cut -c1-140
    KUBECONFIG="${KUBE_DIR}/${f}.yaml" kubectl get pods -A --request-timeout=5s \
        --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | sed 's/^/  not running: /'
done
echo; info "snapshots"; bash "${LAB_ROOT}/scripts/snap.sh" list
echo; bash "${LAB_ROOT}/scripts/data.sh" check 2>/dev/null || true
