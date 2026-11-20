#!/usr/bin/env bash
# heap-lab: up.sh [old|new]
# Build the lab to a stage, or resume it if it's already there.
#   1. Preflight: tools, cluster-config checkout, Lima's user-v2 network.
#   2. Three VMs in parallel (broome gets a second disk for /data).
#   3. playbooks/base.yml: configure.yml's roles plus Heap's hand edits.
#   4. old: playbooks/old.yml, Cilium on crosby, stand-in workloads.
#      new: cluster-config's k3s.yml, csi-driver-nfs, heap-nfs, the canary.
#   5. Record /data's checksum, snapshot "<stage>-fresh".
set -euo pipefail
_TAG=up
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
START=$(date +%s)
elapsed() { local s=$(( $(date +%s) - START )); printf '%dm%02ds' $((s / 60)) $((s % 60)); }

STAGE="${1:-${STAGE:-$LAB_STAGE}}"
case "$STAGE" in old|new) ;; *) error "Stage is old or new, not '${STAGE}'." ;; esac
HAVE=$(current_stage)
if [ "$HAVE" != none ] && [ "$HAVE" != "$STAGE" ]; then
    error "The lab is at stage '${HAVE}'. task rebuild STAGE=${STAGE}, or task restore NAME=${STAGE}-fresh."
fi

# ── Preflight ────────────────────────────────────────────────────────────────
for bin in limactl ansible-playbook ansible-galaxy kubectl helm; do
    command -v "$bin" >/dev/null || error "$bin not found on PATH. Run: task setup"
done
[ -f "${HEAP_REPO}/k3s.yml" ] || error "HEAP_REPO=${HEAP_REPO} has no k3s.yml. Set it in .env."
grep -A3 -E '^\s+user-v2:' "${HOME}/.lima/_config/networks.yaml" 2>/dev/null | grep -q "${LAB_SUBNET_PREFIX}\." \
    || error "Lima's user-v2 network isn't ${LAB_SUBNET_PREFIX}.0/24. Run: task setup"
[ -d "${CACHE_DIR}/collections/ansible_collections/prometheus" ] || bash "${LAB_ROOT}/scripts/setup.sh" collections
info "Testing cluster-config at $(repo_ref) (${HEAP_REPO})"

# ── VMs ──────────────────────────────────────────────────────────────────────
phase_begin "VMs"
IMAGE="https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release/ubuntu-${UBUNTU_RELEASE}-server-cloudimg-${GUEST_ARCH}.img"
PIDS=()
start_vm() {
    local n="$1" name; name=$(vm_name "$1")
    local sets=(
        --set ".param.NodeIP = \"$(node_ip "$n")\""
        --set ".param.Hostname = \"${n}\""
        --set ".param.Gateway = \"${LAB_GATEWAY}\""
        --set ".param.NodeIPv6 = \"$(node_ipv6 "$n")\""
        --set ".param.UnreachablePodCIDR = \"${LAB_UNREACHABLE_POD_CIDR}\""
        --set ".param.UnreachableServiceCIDR = \"${LAB_UNREACHABLE_SERVICE_CIDR}\""
        --set ".cpus = ${LAB_CPUS}"
        --set ".memory = \"$(node_mem "$n")\""
        --set ".disk = \"${LAB_DISK}\""
        --set ".images = [{\"location\": \"${IMAGE}\", \"arch\": \"${LIMA_ARCH}\"}]"
        --set ".portForwards = [{\"guestPort\": 6443, \"hostPort\": $(api_port "$n")}, {\"ignore\": true, \"proto\": \"any\", \"guestIP\": \"0.0.0.0\"}]"
    )
    if [ "$n" = broome ]; then
        disk_exists "$(data_disk)" || limactl disk create "$(data_disk)" --size "${LAB_DATA_DISK}" --format raw >/dev/null
        sets+=(--set ".additionalDisks = [{\"name\": \"$(data_disk)\", \"format\": false}]")
    fi
    case "$(vm_status "$name")" in
        "")      step "Creating ${name} ($(node_ip "$n"), $(node_ipv6 "$n"), $(node_mem "$n"))"
                 limactl create -y --name="${name}" "${sets[@]}" "${LAB_ROOT}/lima/node.yaml" >/dev/null ;;
        Running) info "${name} already running."; return 0 ;;
    esac
    step "Starting ${name}"
    limactl start -y --timeout 10m "${name}" >"${STATE_DIR}/${name}.start.log" 2>&1 &
    PIDS+=("$!:${name}")
}
wait_started() {
    for p in "${PIDS[@]+"${PIDS[@]}"}"; do
        wait "${p%%:*}" || { tail -20 "${STATE_DIR}/${p#*:}.start.log" >&2; error "${p#*:} failed to start. Log: .state/${p#*:}.start.log"; }
    done
    PIDS=()
}
# broome first, then the others together. greene and crosby mount broome:/data
# hard with no nofail, as on Heap; on 2026-11-20 a greene that booted before
# broome's NFS server was up never finished booting.
for n in ${LAB_NODES}; do [ "$n" = broome ] && start_vm "$n"; done
wait_started
for n in ${LAB_NODES}; do [ "$n" = broome ] || start_vm "$n"; done
wait_started
bash "${LAB_ROOT}/scripts/ssh_config.sh"
wait_egress
phase_end

if [ "$HAVE" = "$STAGE" ]; then
    bash "${LAB_ROOT}/scripts/kubeconfig.sh"
    info "Resumed stage ${STAGE} in $(elapsed)."
    exit 0
fi

# ── Host ─────────────────────────────────────────────────────────────────────
phase_begin "base"
bash "${LAB_ROOT}/scripts/play.sh" base.yml
phase_end

wait_nodes() {  # kubeconfig-file count
    local f="$1" want="$2" i
    for i in $(seq 1 60); do
        [ "$(KUBECONFIG="$f" kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" -ge "$want" ] && return 0
        sleep 5
    done
    KUBECONFIG="$f" kubectl get nodes -o wide >&2 || true
    error "Expected ${want} Ready nodes in ${f#"${LAB_ROOT}/"}."
}

if [ "$STAGE" = old ]; then
    phase_begin "old k3s"
    bash "${LAB_ROOT}/scripts/play.sh" old.yml
    bash "${LAB_ROOT}/scripts/kubeconfig.sh"
    phase_end

    phase_begin "crosby's Cilium"
    KUBECONFIG="${KUBE_DIR}/crosby.yaml" helm upgrade --install cilium cilium \
        --repo https://helm.cilium.io --version "${EXPERIMENT_CILIUM}" -n kube-system \
        --set ipam.mode=cluster-pool \
        --set 'ipam.operator.clusterPoolIPv4PodCIDRList={10.44.0.0/16}' \
        --set k8sServiceHost=crosby --set k8sServicePort=6443 \
        --set operator.replicas=1 \
        --set hubble.relay.enabled=true --set hubble.ui.enabled=true \
        --wait --timeout 10m >/dev/null
    wait_nodes "${KUBE_DIR}/crosby.yaml" 1
    phase_end

    phase_begin "old workloads"
    wait_nodes "${KUBE_DIR}/old.yaml" 2
    old_kubectl apply -f "${LAB_ROOT}/manifests/old/workloads.yaml" >/dev/null
    old_kubectl -n michael rollout status sts/concourse-postgresql --timeout=5m >/dev/null
    old_kubectl -n jupyterhub rollout status deploy/hub --timeout=5m >/dev/null
    old_kubectl -n jupyterhub wait --for=condition=complete job/seed-trey --timeout=5m >/dev/null
    old_kubectl -n ray-system rollout status deploy/rc-ray-head --timeout=5m >/dev/null
    old_kubectl -n gpu-operator rollout status ds/gpu-feature-discovery --timeout=5m >/dev/null
    phase_end
else
    phase_begin "k3s.yml"
    bash "${LAB_ROOT}/scripts/play.sh" k3s.yml
    bash "${LAB_ROOT}/scripts/kubeconfig.sh"
    wait_nodes "${KUBE_DIR}/new.yaml" 3
    phase_end

    phase_begin "storage and canary"
    bash "${LAB_ROOT}/scripts/addons.sh"
    bash "${LAB_ROOT}/scripts/canary.sh" new
    phase_end
fi

echo "$STAGE" > "${STATE_DIR}/stage"
bash "${LAB_ROOT}/scripts/data.sh" record

if [ "${SNAP:-1}" = 1 ]; then
    phase_begin "snapshot"
    bash "${LAB_ROOT}/scripts/snap.sh" save "${STAGE}-fresh"
    phase_end
fi

echo
info "Stage ${STAGE} is up in $(elapsed)."
info "  kubectl: in this directory (direnv) it just works; old and new are wrappers in bin/."
info "  Next: task status | task watch | task snap NAME=... | README, \"Drills\""
