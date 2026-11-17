#!/usr/bin/env bash
# heap-lab: card.sh <node>
# heap-migration.md's node card, steps b to m, for one node, with every
# check. Stops at the first failed check, as the runbook says to.
#   b  k3s-teardown.yml        c  heap-check clean      d  /data unchanged
#   e  the copied volumes      f  reboot (lab: only when Cilium left interfaces)
#   g  skipped: no GPUs        h  k3s.yml -l <node>     i-m heap-check joined
# crosby also gets runbook step 3.4 (Atty's lxc+ ufw rule) before h.
set -euo pipefail
_TAG=card
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
N="${1:?usage: card.sh <node>}"
case " ${LAB_NODES} " in *" $N "*) ;; *) error "No node $N." ;; esac
H=$(fqdn "$N")
s() { echo; step "$N, step $*"; }

s "b: k3s-teardown.yml"
bash "${LAB_ROOT}/scripts/play.sh" k3s-teardown.yml \
    -e "teardown_host=${H}" -e "teardown_confirm=${N}" -e "old_cluster_server=$(fqdn broome)"

s "c: heap-check clean"
if ! bash "${LAB_ROOT}/scripts/check.sh" clean "$N"; then
    if on "$N" 'ip -o link show' | grep -q cilium_; then
        s "f: Cilium left interfaces behind; rebooting (runbook 3.3)"
        limactl restart "$(vm_name "$N")" >/dev/null
        bash "${LAB_ROOT}/scripts/ssh_config.sh"
        bash "${LAB_ROOT}/scripts/check.sh" clean "$N" || error "Still not clean after a reboot."
    else
        error "Not clean; the runbook stops here."
    fi
fi

s "d: /data unchanged"
bash "${LAB_ROOT}/scripts/data.sh" check
bash "${LAB_ROOT}/scripts/check.sh" baseline

s "e: what the teardown copied"
on "$N" "sudo ls -la /data/k8s-migration/${N}/ 2>/dev/null || echo '(no local-path volumes on ${N})'"

if [ "$N" = crosby ] && on crosby 'sudo ufw status' | grep -q 'lxc'; then
    s "3.4: delete Atty's lxc+ rule"
    on crosby 'sudo ufw delete allow in on lxc+ from 10.44.0.0/16'
fi

s "h: k3s.yml -l ${H}"
bash "${LAB_ROOT}/scripts/play.sh" k3s.yml -l "${H}"
bash "${LAB_ROOT}/scripts/kubeconfig.sh" >/dev/null

s "i-m: heap-check joined"
# Ready isn't enough: with podman's conflist in /etc/cni/net.d the node goes
# Ready seconds after k3s starts, before Cilium exists. Wait for this node's
# Cilium agent to be Ready and the not-ready taint to be gone (5 min max).
for i in $(seq 1 60); do
    taints=$(new_kubectl get node "$N" -o jsonpath='{.spec.taints}' 2>/dev/null || echo x)
    cilium=$(new_kubectl -n kube-system get pod -l k8s-app=cilium --field-selector "spec.nodeName=$N" \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ -z "$taints" ] && [ "$cilium" = True ] && break
    sleep 5
done
bash "${LAB_ROOT}/scripts/check.sh" joined "$N"
echo
info "$N's card is done."
