#!/usr/bin/env bash
# heap-lab: setup.sh [collections]
# One-time host checks, and the Ansible collections cluster-config needs,
# installed into .cache/collections (nothing global).
set -euo pipefail
_TAG=setup
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

collections() {
    step "Ansible collections from ${HEAP_REPO}/requirements.yml into .cache/collections"
    # prometheus.prometheus 0.27.0 (pinned by cluster-config) declares
    # ansible-core <= 2.18; it works on newer, so install it anyway.
    ANSIBLE_COLLECTIONS_ON_ANSIBLE_VERSION_MISMATCH=ignore ansible-galaxy collection install -r "${HEAP_REPO}/requirements.yml" -p "${CACHE_DIR}/collections" >/dev/null
}
[ "${1:-}" = collections ] && { collections; exit 0; }

for bin in limactl ansible-playbook kubectl helm gawk task; do
    command -v "$bin" >/dev/null || error "$bin missing: brew install $([ "$bin" = ansible-playbook ] && echo ansible || echo "$bin")"
done
v=$(limactl --version | awk '{print $3}'); [ "${v%%.*}" -ge 2 ] || error "Lima ${v}; need 2.x."
info "Lima ${v}"
[ -f "${HEAP_REPO}/k3s.yml" ] || error "HEAP_REPO=${HEAP_REPO} doesn't look like cluster-config with k3s.yml. Set it in .env."
info "cluster-config at ${HEAP_REPO}, $(repo_ref)"
NET="${HOME}/.lima/_config/networks.yaml"
[ -f "$NET" ] || limactl sudoers >/dev/null 2>&1 || true
grep -A3 -E '^\s+user-v2:' "$NET" 2>/dev/null | grep -q "${LAB_SUBNET_PREFIX}\." \
    || error "Lima's user-v2 network in ${NET} isn't ${LAB_SUBNET_PREFIX}.0/24. The lab's fixed addresses live there."
info "user-v2 is ${LAB_SUBNET_PREFIX}.0/24"
collections
info "Setup complete. Next: task up"
