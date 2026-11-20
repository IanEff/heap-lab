# CLAUDE.md

heap-lab is three Lima VMs standing in for RC's Heap cluster, so cluster-config's playbooks can be rehearsed before they run on Heap. The README covers usage and the fidelity tables; this file covers what an agent needs to avoid breaking it.

## Commands

`task up [STAGE=old|new]` · `task status` · `task snap NAME=` · `task restore NAME=` · `task card NODE=` · `task k3s -- <args>` · `task watch` · `task oidc` · `task whoami` · `task destroy FORCE=1`. `task --list` for the rest. Login secrets live only in `.env`; never print them, never pass them on a command line. Inside the repo, direnv sets `KUBECONFIG`; `new`, `old` and `crosby` in `bin/` are kubectl per cluster.

## Invariants

1. **The lab tests cluster-config; it never forks it.** Playbooks, roles and `heap-check.sh` run from `HEAP_REPO` unchanged. If something only works with a change to cluster-config, that's a finding for Ian, not a patch in here. The lab's only overrides are inventory values and the three `-e`/role-param substitutions already in the scripts (`old_cluster_server`, the firewall role's `cluster_network` and `cluster_network_v6`, the version-mismatch and broken-conditionals settings for base.yml).
2. **Every value lives in `config/heap-lab.env`** (`.env` overrides). Inventory reads it with `lookup('env')`; scripts through `scripts/lib.sh`.
3. **Fidelity is the point.** Anything added to the VMs either mirrors something seen on Heap (cite the scan or note it came from) or is the lab's own instrument (canary, watch, data checksum) and is labelled as such. Every departure from Heap goes in the README's "What isn't" table.
4. **One NIC on user-v2, carrying both families.** Don't add a second network; Cilium's device autodetection is part of what's being tested (D-17). Don't change the DHCP address on eth0: Lima's ssh is forwarded to it. IPv6 between nodes works only because `heap-lab-ndp` (in `lima/node.yaml`) sends eth0's IPv6 multicast as broadcast; take it out and neighbour discovery stops.
5. **Nothing outside the repo and `~/.lima`.** No edits to `~/.ssh/config` or `~/.kube/config`.
6. **`heap-k8s/` is a mirror of recursecenter/heap-k8s at `HEAP_K8S_MIRRORED`.** Upstream's bytes except Heap's values (placeholders, filled by `heap_k8s_render`) and the deltas marked `heap-lab:` and listed in `heap-k8s/README.md`. A new delta needs a reason Heap's repo can't go green on the lab, a marker, and a row there; a fix heap-k8s needs is also a finding in the README. Re-mirror when `task argo-drift` fails.
7. **Never point the lab at Heap.** Inventory names end in `.heap-lab` and resolve only through `.state/ssh_config`. Don't add `cluster.recurse.com` names or the real inventory. The lab's IPv6 is a ULA /64 (`LAB_IPV6_PREFIX`); don't put Heap's `2602:fb65:0:90::/64` on a VM.

## Gotchas already paid for

- prometheus.prometheus 0.27.0 (cluster-config's pin) declares ansible-core ≤ 2.18 and has string conditionals 2.19+ rejects. `setup.sh` installs it anyway; `play.sh` relaxes conditionals for base.yml only.
- cluster-config's `nfs_server` role formats the whole device before partitioning it, which only works on a disk that's already partitioned. `base.yml` partitions and formats vdb1 first.
- user-v2's switch drops multicast, so IPv6 neighbour discovery gets no answer. Pinned neighbours don't work either: under vz, Lima ignores `macAddress` on the first user-v2 NIC and derives it from the host's machine id and the instance dir. Hence `heap-lab-ndp`.
- A node with no Cilium sends pod-range packets to Lima's gateway, and enough of them stall every VM's TCP egress. The `unreachable` routes in `lima/node.yaml` (`LAB_UNREACHABLE_*`) stop that; don't remove them.
- `limactl edit --set` has yq's `load()` disabled. To swap a section of a stopped instance's `lima.yaml`, pass it inline as JSON (`yq -o=json -I=0 .provision lima/node.yaml`).
- `limactl snapshot` is QEMU-only. `scripts/snap.sh` clones the vz disks with `cp -c` while all three VMs are stopped.
