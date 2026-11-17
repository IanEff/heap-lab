#!/usr/bin/env bash
# heap-lab: destroy.sh [-f]
# Delete the VMs, broome's data disk, .state/ and .snapshots/. Keeps .cache/.
set -euo pipefail
_TAG=destroy
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "${1:-}" != "-f" ]; then
    read -r -p "Delete the heap-lab VMs, their disks and all snapshots? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "Aborted."; exit 1; }
fi
for n in ${LAB_NODES}; do
    vm=$(vm_name "$n")
    vm_exists "$vm" && { step "Deleting ${vm}"; limactl delete --force "$vm" >/dev/null & }
done
wait
disk_exists "$(data_disk)" && { step "Deleting disk $(data_disk)"; limactl disk delete "$(data_disk)" >/dev/null; }
rm -rf "${STATE_DIR}" "${SNAP_DIR}"
info "heap-lab destroyed."
