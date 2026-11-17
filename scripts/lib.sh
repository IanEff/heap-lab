#!/usr/bin/env bash
# heap-lab: shared helpers for the host-side scripts. Source, don't execute.

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${LAB_ROOT}/.state"
CACHE_DIR="${LAB_ROOT}/.cache"
SNAP_DIR="${LAB_ROOT}/.snapshots"

_TAG="${_TAG:-heap-lab}"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[${_TAG}]${NC} $*"; }
step()  { echo -e "${CYAN}[${_TAG}]${NC} $*"; }
warn()  { echo -e "${YELLOW}[${_TAG}]${NC} $*"; }
error() { echo -e "${RED}[${_TAG}]${NC} $*" >&2; exit 1; }

# config/heap-lab.env, then .env on top. Exported so Ansible's lookup('env')
# and child scripts see the same values.
set -a
# shellcheck disable=SC1091
source "${LAB_ROOT}/config/heap-lab.env"
# shellcheck disable=SC1091
[ -f "${LAB_ROOT}/.env" ] && source "${LAB_ROOT}/.env"
LAB_ROOT="${LAB_ROOT}"
set +a

mkdir -p "${STATE_DIR}"

case "$(uname -m)" in
    arm64)  LIMA_ARCH="aarch64"; GUEST_ARCH="arm64" ;;
    x86_64) LIMA_ARCH="x86_64";  GUEST_ARCH="amd64" ;;
    *) error "Unsupported host arch: $(uname -m)" ;;
esac

# Per-node values. bash 3.2 on macOS has no ${x^^}, hence the case tables.
upper()     { echo "$1" | tr '[:lower:]' '[:upper:]'; }
node_var()  { local v="$1_$(upper "$2")"; echo "${!v}"; }
node_ip()   { node_var LAB_IP "$1"; }
node_mem()  { node_var LAB_MEMORY "$1"; }
api_port()  { node_var LAB_API_PORT "$1"; }
vm_name()   { echo "heap-$1"; }
fqdn()      { echo "$1.${LAB_DOMAIN}"; }
data_disk() { echo "heap-broome-data"; }

vm_status() { limactl list --format '{{.Status}}' "$1" 2>/dev/null || true; }
vm_exists() { limactl list --quiet 2>/dev/null | grep -qx "$1"; }
disk_exists() { limactl disk list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1"; }

# ssh to a node by its short name, through the generated ssh_config.
SSH_CONFIG="${STATE_DIR}/ssh_config"
on() { local n="$1"; shift; ssh -F "${SSH_CONFIG}" "$(fqdn "$n")" "$@"; }

# kubectl for each cluster. The files are written by scripts/kubeconfig.sh.
KUBE_DIR="${STATE_DIR}/kube"
new_kubectl() { KUBECONFIG="${KUBE_DIR}/new.yaml" kubectl "$@"; }
old_kubectl() { KUBECONFIG="${KUBE_DIR}/old.yaml" kubectl "$@"; }

current_stage() { cat "${STATE_DIR}/stage" 2>/dev/null || echo none; }

# Timeline: one CSV row per phase, so slow phases show up across runs.
RUN_ID="${RUN_ID:-$(date +%Y%m%dT%H%M%S)}"
export RUN_ID
_phase_start=0
phase_begin() { _phase_name="$1"; _phase_start=$(date +%s); step "$1"; }
phase_end() {
    local s=$(( $(date +%s) - _phase_start ))
    [ -f "${STATE_DIR}/timeline.csv" ] || echo "run_id,phase,seconds" > "${STATE_DIR}/timeline.csv"
    echo "${RUN_ID},${_phase_name},${s}" >> "${STATE_DIR}/timeline.csv"
    info "${_phase_name}: ${s}s"
}

# The cluster-config checkout, described for logs: branch, commit, dirty.
repo_ref() {
    echo "$(git -C "${HEAP_REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null)@$(git -C "${HEAP_REPO}" describe --always --dirty 2>/dev/null)"
}

# Lima's user-v2 NAT drops outbound HTTPS for a few minutes after the VMs
# restart (seen 2026-11-17, on every node at once, while the Mac's own
# connections were fine). k3s.yml's installer download and image pulls fail
# inside that window, so anything that restarts the VMs waits it out.
wait_egress() {
    local n i ok
    for n in ${LAB_NODES}; do
        ok=0
        for i in $(seq 1 40); do
            if on "$n" 'curl -s -m4 -o /dev/null https://get.k3s.io' 2>/dev/null; then
                ok=$((ok + 1)); [ "$ok" -ge 3 ] && break
            else
                ok=0
            fi
            sleep 1
        done
        [ "$ok" -ge 3 ] || warn "${n} still can't reach the internet reliably; installs may time out."
    done
}
