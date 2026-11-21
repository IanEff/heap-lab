#!/usr/bin/env bash
# heap-lab: snap.sh save|restore|list|delete [NAME]
# Whole-lab snapshots, for trying an upgrade, throwing it away and trying
# again. All three VMs stop together (a clean shutdown, so etcd and sqlite
# are consistent), their disks and broome's /data disk are cloned with APFS
# clonefile (cp -c: instant, and only blocks that later change take space),
# then the VMs start again. Restore is the same in reverse. .state/'s stage,
# kubeconfigs and /data baseline travel with the snapshot.
#
# limactl snapshot only works for QEMU; the lab runs on vz, hence this.
set -euo pipefail
_TAG=snap
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LIMA_HOME="${LIMA_HOME:-$HOME/.lima}"
DATA_DISK_DIR="${LIMA_HOME}/_disks/$(data_disk)"
STATE_FILES=(stage data.baseline kube)

stop_all() {
    local n pids=()
    for n in ${LAB_NODES}; do
        [ "$(vm_status "$(vm_name "$n")")" = Running ] && { limactl stop "$(vm_name "$n")" >/dev/null 2>&1 & pids+=($!); }
    done
    for p in "${pids[@]+"${pids[@]}"}"; do wait "$p"; done
}
start_all() {
    local n pids=()
    # All three at once: each node's k3s waits for its peers (see up.sh).
    for n in ${LAB_NODES}; do limactl start -y --timeout 10m "$(vm_name "$n")" >"${STATE_DIR}/$(vm_name "$n").start.log" 2>&1 & pids+=($!); done
    for p in "${pids[@]}"; do wait "$p" || error "A VM failed to start; see .state/*.start.log"; done
    bash "${LAB_ROOT}/scripts/ssh_config.sh"
    step "Waiting for internet access from every node"
    wait_egress
}
# Clone src to dst, replacing dst. clonefile won't overwrite, so remove first.
clone() { rm -f "$2"; cp -c "$1" "$2"; }
# The files that make up a VM's state on vz. Lima 2.2 calls the root disk
# `disk`; older Lima called it `diffdisk`. Whichever exists is cloned, and a
# VM with neither stops the save.
vm_files() { echo disk diffdisk vz-efi; }

name="${2:-}"
case "${1:-list}" in
    save)
        [ -n "$name" ] || error "usage: snap.sh save NAME"
        for n in ${LAB_NODES}; do vm_exists "$(vm_name "$n")" || error "$(vm_name "$n") doesn't exist."; done
        dest="${SNAP_DIR}/${name}"
        rm -rf "${dest}.tmp"; mkdir -p "${dest}.tmp/state"
        step "Stopping the VMs"
        stop_all
        step "Cloning disks to .snapshots/${name}"
        for n in ${LAB_NODES}; do
            vm=$(vm_name "$n"); dir=$(limactl list --format '{{.Dir}}' "$vm")
            mkdir -p "${dest}.tmp/${vm}"
            for f in $(vm_files); do [ -f "${dir}/${f}" ] && clone "${dir}/${f}" "${dest}.tmp/${vm}/${f}"; done
            [ -f "${dest}.tmp/${vm}/disk" ] || [ -f "${dest}.tmp/${vm}/diffdisk" ] \
                || { start_all; error "No root disk found in ${dir}; snapshot not saved."; }
        done
        clone "${DATA_DISK_DIR}/datadisk" "${dest}.tmp/datadisk"
        for f in "${STATE_FILES[@]}"; do [ -e "${STATE_DIR}/${f}" ] && cp -R "${STATE_DIR}/${f}" "${dest}.tmp/state/"; done
        {
            echo "taken: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "stage: $(current_stage)"
            echo "cluster-config: $(repo_ref)"
            echo "note: ${NOTE:-}"
        } > "${dest}.tmp/meta"
        rm -rf "${dest}"; mv "${dest}.tmp" "${dest}"
        step "Starting the VMs"
        [ "${NOSTART:-0}" = 1 ] || start_all
        info "Saved ${name}." ;;

    restore)
        [ -n "$name" ] || error "usage: snap.sh restore NAME"
        src="${SNAP_DIR}/${name}"
        [ -f "${src}/meta" ] || error "No snapshot ${name}. task snaps lists them."
        step "Stopping the VMs"
        stop_all
        step "Restoring disks from .snapshots/${name}"
        for n in ${LAB_NODES}; do
            vm=$(vm_name "$n"); dir=$(limactl list --format '{{.Dir}}' "$vm")
            [ -f "${src}/${vm}/disk" ] || [ -f "${src}/${vm}/diffdisk" ] || error "${name} has no root disk for ${vm}; not restoring."
            for f in $(vm_files); do [ -f "${src}/${vm}/${f}" ] && clone "${src}/${vm}/${f}" "${dir}/${f}"; done
        done
        clone "${src}/datadisk" "${DATA_DISK_DIR}/datadisk"
        for f in "${STATE_FILES[@]}"; do rm -rf "${STATE_DIR:?}/${f}"; [ -e "${src}/state/${f}" ] && cp -R "${src}/state/${f}" "${STATE_DIR}/"; done
        step "Starting the VMs"
        start_all
        info "Restored ${name}:"; sed 's/^/  /' "${src}/meta" ;;

    list)
        [ -d "${SNAP_DIR}" ] || { info "No snapshots."; exit 0; }
        for d in "${SNAP_DIR}"/*/; do
            [ -f "${d}meta" ] || continue
            printf '%-24s %s\n' "$(basename "$d")" "$(paste -sd'|' "${d}meta" | sed 's/|note: $//; s/|/  /g')"
        done ;;

    delete)
        [ -n "$name" ] && [ -d "${SNAP_DIR}/${name}" ] || error "No snapshot ${name}."
        rm -rf "${SNAP_DIR:?}/${name}"; info "Deleted ${name}." ;;

    *) error "usage: snap.sh save|restore|list|delete [NAME]" ;;
esac
