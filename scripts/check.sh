#!/usr/bin/env bash
# heap-lab: check.sh baseline | clean <node> | joined <node>
# cluster-config's scripts/heap-check.sh, unchanged, pointed at the lab: the
# same checks the runbook runs on Heap. The expected k3s version is read from
# the checkout's role defaults, so after a bump it checks the new one.
set -uo pipefail
_TAG=check
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export HEAP_DOMAIN="${LAB_DOMAIN}"
export HEAP_NODES="${LAB_NODES}"
export HEAP_BIND_MOUNT_NODES="crosby$([ "${LAB_MERCER:-0}" = 1 ] && echo " mercer")"
export HEAP_SSH="ssh -F ${SSH_CONFIG} -o BatchMode=yes -o ConnectTimeout=10"
export HEAP_K3S_VERSION="${HEAP_K3S_VERSION:-$(sed -n 's/^k3s_version: *//p' "${HEAP_REPO}/roles/k3s/defaults/main.yml")}"
export KUBECONFIG="${KUBE_DIR}/new.yaml"
exec bash "${HEAP_REPO}/scripts/heap-check.sh" "$@"
