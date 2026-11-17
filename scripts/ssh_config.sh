#!/usr/bin/env bash
# heap-lab: ssh_config.sh
# Write .state/ssh_config from each instance's own Lima ssh.config, renamed
# so that `greene.heap-lab`, `greene` and `heap-greene` all reach the VM.
# Ansible, heap-check.sh and the scripts use it with -F. ~/.ssh/config is
# never touched.
set -euo pipefail
_TAG=ssh
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

out="${SSH_CONFIG}.tmp"
: > "$out"
for n in ${LAB_NODES}; do
    vm=$(vm_name "$n")
    dir=$(limactl list --format '{{.Dir}}' "$vm")
    [ -f "${dir}/ssh.config" ] || error "No ${dir}/ssh.config; is ${vm} running?"
    sed -e "s/^Host .*/Host $(fqdn "$n") ${n} ${vm}/" "${dir}/ssh.config" >> "$out"
    echo >> "$out"
done
mv "$out" "${SSH_CONFIG}"
