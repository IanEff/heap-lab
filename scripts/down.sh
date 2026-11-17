#!/usr/bin/env bash
# heap-lab: down.sh: stop every VM, keeping all state. `task up` resumes.
set -euo pipefail
_TAG=down
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
for n in ${LAB_NODES}; do
    vm=$(vm_name "$n")
    [ "$(vm_status "$vm")" = Running ] && { step "Stopping ${vm}"; limactl stop "$vm" >/dev/null 2>&1 & }
done
wait
info "Stopped."
