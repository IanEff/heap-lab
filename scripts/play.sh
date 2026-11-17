#!/usr/bin/env bash
# heap-lab: play.sh <playbook> [ansible-playbook args...]
# Run a playbook against the lab. A name in playbooks/ is the lab's own;
# anything else is looked up in HEAP_REPO (k3s.yml, k3s-teardown.yml, ...).
# Roles come from HEAP_REPO/roles either way. Every run is logged to
# .state/runs/ with the cluster-config commit it ran.
set -euo pipefail
_TAG=play
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pb="${1:?usage: play.sh <playbook> [args]}"; shift
if   [ -f "${LAB_ROOT}/playbooks/${pb}" ]; then path="${LAB_ROOT}/playbooks/${pb}"
elif [ -f "${HEAP_REPO}/${pb}" ];          then path="${HEAP_REPO}/${pb}"
else error "No ${pb} in playbooks/ or ${HEAP_REPO}."
fi

mkdir -p "${STATE_DIR}/runs"
log="${STATE_DIR}/runs/$(date +%Y%m%dT%H%M%S)-$(basename "${pb}" .yml).log"
export ANSIBLE_CONFIG="${LAB_ROOT}/ansible.cfg"
export ANSIBLE_ROLES_PATH="${HEAP_REPO}/roles"
export ANSIBLE_LOG_PATH="${log}"
# base.yml runs cluster-config's metrics role, which uses prometheus.prometheus
# 0.27.0. Its _common role has string conditionals that ansible-core 2.19+
# rejects. Relaxed for that playbook only: k3s.yml and k3s-teardown.yml run
# under the same strict rules as on Ian's laptop.
[ "${pb}" = base.yml ] && export ANSIBLE_ALLOW_BROKEN_CONDITIONALS=true
echo "# ${path} $* | cluster-config $(repo_ref)" > "${log}"
info "${pb} (cluster-config $(repo_ref)) → ${log#"${LAB_ROOT}/"}"
cd "${LAB_ROOT}"
exec ansible-playbook "${path}" "$@"
