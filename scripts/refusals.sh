#!/usr/bin/env bash
# heap-lab: refusals.sh [old|new|all]
# The lab's instrument, not Heap's: trigger every refusal in cluster-config's
# k3s role and k3s-teardown.yml, and expect each to stop the play with its own
# message. A case passes only when the play fails AND its log has that
# message; a play that succeeds, or fails for another reason, is a FAIL.
#
#   old (from REFUSAL_OLD_SNAP, default old-fresh)
#     confirm        teardown with the wrong teardown_confirm
#     old-k3s        k3s.yml on a node whose k3s the role didn't install
#     bare-pod       teardown whose drain meets a pod with no controller
#     mount          teardown with an NFS mount under /var/lib/kubelet
#     flannel        k3s.yml with flannel.1 left behind
#     cilium         k3s.yml with cilium_host left behind
#   new (from REFUSAL_NEW_SNAP, default new-dualstack)
#     new-node       teardown of a node the role installed
#     version        k3s.yml with a different k3s_version, no k3s_allow_upgrade
#
# Restores a snapshot before each group and between cases that change a node,
# so it's rerunnable and leaves the lab at the last snapshot it restored.
# Rerun whenever the branch changes.
set -uo pipefail
_TAG=refusals
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WHAT="${1:-all}"
OLD_SNAP="${REFUSAL_OLD_SNAP:-old-fresh}"
NEW_SNAP="${REFUSAL_NEW_SNAP:-new-dualstack}"
mkdir -p "${STATE_DIR}/runs"
results=()

restore() { info "Restoring $1"; bash "${LAB_ROOT}/scripts/snap.sh" restore "$1" >/dev/null || error "Restore of $1 failed."; }
teardown() {  # node confirm
    bash "${LAB_ROOT}/scripts/play.sh" k3s-teardown.yml \
        -e "teardown_host=$(fqdn "$1")" -e "teardown_confirm=$2" -e "old_cluster_server=$(fqdn broome)"
}
k3s_play() { bash "${LAB_ROOT}/scripts/play.sh" k3s.yml "$@"; }

expect_refusal() {  # name message command...
    local name="$1" msg="$2"; shift 2
    local log="${STATE_DIR}/runs/$(date +%Y%m%dT%H%M%S)-refusal-${name}.log"
    step "${name}: expecting \"${msg}\""
    "$@" > "$log" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ] && grep -qF -- "$msg" "$log"; then
        results+=("PASS  ${name}: refused (\"${msg}\")")
    elif [ "$rc" -eq 0 ]; then
        results+=("FAIL  ${name}: the play succeeded; log ${log#"${LAB_ROOT}/"}")
    else
        results+=("FAIL  ${name}: exit ${rc} without \"${msg}\"; log ${log#"${LAB_ROOT}/"}")
    fi
}

old_cases() {
    restore "$OLD_SNAP"
    expect_refusal confirm "Pass -e teardown_confirm=greene" teardown greene crosby
    expect_refusal old-k3s "has a k3s install this role didn't make" k3s_play -l "$(fqdn greene)"

    # A pod with no controller on greene: the drain stops on it.
    old_kubectl run heap-lab-refusal --image=busybox:1.37 --restart=Never \
        --overrides='{"spec":{"nodeName":"greene"}}' -- sleep 3600 >/dev/null
    old_kubectl wait --for=condition=Ready pod/heap-lab-refusal --timeout=3m >/dev/null
    expect_refusal bare-pod "declare no controller" teardown greene greene

    # Read-only, so even a teardown that ignored it couldn't delete through it.
    # Outside /var/lib/kubelet/pods, so k3s-killall.sh leaves it mounted.
    restore "$OLD_SNAP"
    on greene "sudo mkdir -p /var/lib/kubelet/heap-lab-refusal && \
        sudo mount -t nfs4 -o ro ${LAB_IP_BROOME}:/data /var/lib/kubelet/heap-lab-refusal"
    expect_refusal mount "Still mounted under k3s's directories" teardown greene greene

    # A clean teardown, then the leftovers the role's preflight looks for.
    restore "$OLD_SNAP"
    teardown greene greene > "${STATE_DIR}/runs/$(date +%Y%m%dT%H%M%S)-refusal-setup-teardown.log" 2>&1 \
        || error "greene's teardown failed; the leftover cases need a clean node."
    on greene 'sudo ip link add flannel.1 type dummy'
    expect_refusal flannel "flannel.1 or cni0 still exists" k3s_play -l "$(fqdn greene)"
    on greene 'sudo ip link del flannel.1 && sudo ip link add cilium_host type dummy'
    expect_refusal cilium "cilium_host still exists" k3s_play -l "$(fqdn greene)"
}

new_cases() {
    restore "$NEW_SNAP"
    expect_refusal new-node "runs a k3s installed by roles/k3s" teardown greene greene
    expect_refusal version "Set k3s_allow_upgrade=true" k3s_play -e k3s_version=v1.36.5+k3s1
}

case "$WHAT" in
    old) old_cases ;;
    new) new_cases ;;
    all) old_cases; new_cases ;;
    *) error "usage: refusals.sh [old|new|all]" ;;
esac

echo
info "Refusals (cluster-config $(repo_ref)):"
failed=0
for r in "${results[@]}"; do echo "  $r"; case "$r" in FAIL*) failed=1 ;; esac; done
exit "$failed"
