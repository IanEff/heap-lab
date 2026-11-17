# CLAUDE.md

heap-lab is three Lima VMs standing in for RC's Heap cluster, so cluster-config's playbooks can be rehearsed before they run on Heap. The README covers usage and the fidelity tables; this file covers what an agent needs to avoid breaking it.

## Commands

`task up [STAGE=old|new]` · `task status` · `task snap NAME=` · `task restore NAME=` · `task card NODE=` · `task k3s -- <args>` · `task watch` · `task oidc` · `task whoami` · `task destroy FORCE=1`. `task --list` for the rest. Login secrets live only in `.env`; never print them, never pass them on a command line. Inside the repo, direnv sets `KUBECONFIG`; `new`, `old` and `crosby` in `bin/` are kubectl per cluster.

## Invariants

1. **The lab tests cluster-config; it never forks it.** Playbooks, roles and `heap-check.sh` run from `HEAP_REPO` unchanged. If something only works with a change to cluster-config, that's a finding for Ian, not a patch in here. The lab's only overrides are inventory values and the three `-e`/role-param substitutions already in the scripts (`old_cluster_server`, `cluster_network`, the version-mismatch and broken-conditionals settings for base.yml).
2. **Every value lives in `config/heap-lab.env`** (`.env` overrides). Inventory reads it with `lookup('env')`; scripts through `scripts/lib.sh`.
3. **Fidelity is the point.** Anything added to the VMs either mirrors something seen on Heap (cite the scan or note it came from) or is the lab's own instrument (canary, watch, data checksum) and is labelled as such. Every departure from Heap goes in the README's "What isn't" table.
4. **One NIC on user-v2.** Don't add a second network; Cilium's device autodetection is part of what's being tested (D-17). Don't change the DHCP address on eth0: Lima's ssh is forwarded to it.
5. **Nothing outside the repo and `~/.lima`.** No edits to `~/.ssh/config` or `~/.kube/config`.
6. **Never point the lab at Heap.** Inventory names end in `.heap-lab` and resolve only through `.state/ssh_config`. Don't add `cluster.recurse.com` names or the real inventory.

## Gotchas already paid for

- prometheus.prometheus 0.27.0 (cluster-config's pin) declares ansible-core ≤ 2.18 and has string conditionals 2.19+ rejects. `setup.sh` installs it anyway; `play.sh` relaxes conditionals for base.yml only.
- cluster-config's `nfs_server` role formats the whole device before partitioning it, which only works on a disk that's already partitioned. `base.yml` partitions and formats vdb1 first.
- `limactl snapshot` is QEMU-only. `scripts/snap.sh` clones the vz disks with `cp -c` while all three VMs are stopped.
