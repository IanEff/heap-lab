# heap-lab

Three Lima VMs on a laptop, standing in for RC's Heap cluster, where cluster-config's own playbooks get run against Heap's quirks before they're run on Heap. Each VM is named after the node it plays (greene, crosby and broome), carries that node's leftovers, and gets built by the same `k3s.yml`, `k3s-teardown.yml` and `heap-check.sh` the runbook uses, straight from your cluster-config checkout. Snapshots make an upgrade cheap to try, throw away and try again.

The lab borrows galley's ergonomics: one config file, Taskfile verbs, direnv kubeconfig, fail-fast VM starts and phase timings. It adds three things galley doesn't have: whole-lab snapshots, a disruption probe, and a /data integrity check.

Read "What's true to Heap" and "What isn't" first. Everything a drill tells you depends on those two tables.

## Quick start

```bash
task setup                 # once: checks Lima 2.x and the user-v2 subnet, installs cluster-config's collections into .cache/
task up                    # Heap as it is today (STAGE=old); snapshot old-fresh at the end
task status
task up STAGE=new          # after task destroy: the migration's end state, built by k3s.yml
```

`direnv allow` once. In this directory, `kubectl` reaches the new cluster if there is one and the old one otherwise; `new`, `old` and `crosby` (in `bin/`) are kubectl for each cluster, the same names as the runbook's shell functions, so `old get nodes` and `new get nodes` work as written in heap-migration.md.

## What's true to Heap

| Heap | Lab | How |
|---|---|---|
| Ubuntu 24.04.5, kernel 6.8.0 | Ubuntu 24.04.5 cloud image, kernel 6.8.0-147 (crosby's running kernel on 2026-11-16) | `lima/node.yaml` |
| One NIC per node, all four on one /27, L2 neighbours, MTU 1500 | One NIC per VM on Lima's `user-v2` network, L2 neighbours; addresses .138, .132, .133 as on Heap | user-v2, plus a fixed address set by netplan |
| greene `cluster-init`, crosby second server, broome agent; two-member etcd | Same three roles; same etcd arithmetic | `inventory/hosts.yml`, cluster-config's `k3s.yml` |
| Old cluster: broome v1.31.2 server on sqlite with `--flannel-backend=vxlan`; greene v1.31.6 agent with the GPU labels | Same versions, installed with the commands from master's `roles/k3s/tasks/{head,worker}.yaml` | `playbooks/old.yml` |
| crosby: Atty's standalone v1.36.6 with Cilium 1.20.4 (cluster-pool), containerd bind-mounted from `/home/k3s-containerd`, an `lxc+` ufw rule | Same, with crosby's k3s flags reconstructed (see below) | `playbooks/old.yml`, `scripts/up.sh` |
| configure.yml's host roles: firewall, fail2ban, host, env, metrics (node_exporter on 9100), oomd, nfs_server on broome | The same roles from your checkout | `playbooks/base.yml` |
| ufw: deny in, allow from the cluster /27, ssh and 443 from anywhere, drift on broome and crosby | The firewall role with the lab subnet as the cluster network, plus the drift rules | `playbooks/base.yml` |
| broome's `/data`: ext4 on sdb1, `defaults`, exported `*(rw,sync,no_subtree_check,no_root_squash)`, 0777, 12 entries, 73 archived homes | ext4 on vdb1 from the nfs_server role, seeded with the same counts | `playbooks/base.yml` |
| `broome` is 127.0.0.1 on broome, so `ray-pv` mounts it over loopback | The host role writes the same line; a `ray-pv` stand-in mounts it on broome | `manifests/old/workloads.yaml` |
| The other nodes mount broome:/data `hard` | Same, over IPv4 | `playbooks/base.yml` |
| local-path volumes on greene and broome, gpu-feature-discovery's subPath of `/etc`, an Ingress on traefik through servicelb | Stand-ins for each, with known bytes in every volume | `manifests/old/workloads.yaml` |
| podman's conflist on greene and broome; Calico's conflist and kubeconfig on broome; setuid calico binaries on broome and greene | Same files (the binaries are inert) | `playbooks/base.yml` |
| Swap on, `/swap.img`; inotify instances at Ubuntu's 128 | 1 GiB `/swap.img`, same fstab line; 128 | `playbooks/base.yml` |

crosby's experiment is the weakest row. The scan recorded what Atty ended up with, not the command he ran. `playbooks/old.yml` uses `flannel-backend: none`, `disable-network-policy`, CIDRs 10.44/10.45 and kube-proxy left on; the 10.44 comes from his ufw rule, the rest is a guess.

## What isn't

| Difference | What it means for a drill |
|---|---|
| arm64 (Apple silicon), Heap is amd64 | k3s, Cilium and the busybox stand-ins are multi-arch. An app image that's amd64-only (JupyterHub's `treylawrence/jupyter-ray:latest` is a candidate) won't start here. |
| No GPUs, no `gpu` group | `default-runtime: nvidia`, the device plugin and the GPU labels from the new role go untested. The old stand-in carries the old role's labels only. |
| `system-reserved` 512Mi and eviction at 100Mi, against Heap's 6-10Gi and 1Gi | The reservations can't be sized here. Everything else the role renders is unchanged. |
| 4 GiB per VM, 2 vCPUs | Memory pressure arrives sooner than on Heap; it isn't a test of Heap's headroom. |
| Lima's DHCP address stays on eth0 as a secondary | Lima's ssh needs it. Routes, k3s and Cilium use the fixed primary. |
| IPv4 only | Heap's workers mount /data over tcp6. The new StorageClass uses broome's IPv4 address, so the new cluster matches; the old NFS path doesn't. |
| A 20 GiB virtual disk under /data, not a failing 10 TB one | No pending sectors. The fstab line has no `nofail`, as on Heap, so a missing disk would stop the boot. |
| No mercer | A second old agent and a second bind mount, both covered by greene and crosby. vllm's pin to mercer has nowhere to go. |
| Left out: users, svc-accts, sshd, ansible-pull, network, nix, popular_software, motd, gpu, nomad, mercer's and crosby's `/home` exports | None of it sits under k3s. `playbooks/base.yml` says why for each role. |
| unattended-upgrades off | So a snapshot stays the same snapshot. OS upgrades get drilled deliberately. |
| No public IPs or upstream filter | Ingress is tested from inside the lab, as the runbook does from broome. |
| `/opt/cni/bin` holds only the inert calico stand-ins | Heap's broome and greene also have `bandwidth`, `flannel`, `host-local`, `loopback`, `portmap` and `tuning` there from 2025. Not copied: a fake `loopback` would break what a real one makes work. |
| Argo CD syncs a copy of heap-k8s, served from broome | `task argo` clones `HEAP_K8S` (`IanEff/heap-k8s` for now), swaps three values (the repo's own URL, `heap-nfs`'s NFS server, Prometheus's node targets, with mercer's dropped), commits that on top and serves it from broome on 8418, the lab's own git server. It stops if a Heap address is left in anything Argo CD applies. Nothing else changes, and `bootstrap/bootstrap.sh` runs as written. `task up STAGE=new` still installs csi-driver-nfs with Helm from `scripts/addons.sh`; don't run both. |
| No sealed secrets, no Cloudflare token | Grafana waits for `grafana-admin` and the ClusterIssuer can't solve DNS01, as on a fresh Heap until someone seals them. |
| Logins go through the real batchmate.id, with your own clients | There's nothing to stand in for: the API servers and Argo CD trust `https://batchmate.id` exactly as Heap will, so a login needs the internet and Chandler's gateway up. `task oidc` patches Argo CD's settings onto the live cluster and keeps its client secret in a Secret it creates from `.env`; heap-k8s carries the same settings and still has to seal that secret. Admins come from `LAB_OIDC_ADMINS`, the lab's own instrument; on Heap they belong in heap-k8s. |

## What has been run (2026-11-17)

Against cluster-config `k3s-ha-cilium` at `db38bb4`, uncommitted. Lima 2.2.1, ansible-core 2.21.5, an M1 Max with 32 GiB.

- `task up` (old) builds in about 3 minutes from cached images. Every stand-in comes up; `heap-check.sh baseline` reports 12 entries, 73 archive entries and exactly one NFS mount under kubelet, `ray-pv` on broome, which is what it reports on Heap.
- The whole migration, one card at a time: greene (old-agent path), crosby (standalone path), then broome (old-server path, with the old workloads and `ray-pv`'s loopback mount still in place, so Phase 7's gate was skipped on purpose). Each teardown copied its local-path volumes to `/data/k8s-migration/<node>/` and passed `heap-check clean`, and `/data`'s checksum never moved. All three nodes joined v1.36.6+k3s1 with Cilium 1.20.4 and passed `heap-check joined`, apart from the two crosby failures under Findings.
- csi-driver-nfs 4.13.6 and `heap-nfs`: a PVC provisioned `/data/k8s/lab-canary/heartbeat` on broome, and the canary answered through Cilium's ingress on all three nodes.
- `task watch` through `systemctl restart k3s` on crosby: crosby's API was out for 7 s (5 s with no answer, then 2 s answering 503); greene's API and the canary on every node never dropped.
- Snapshot and restore: after deleting a namespace, adding a file on greene and changing a file in `/data`, restoring `old-fresh` took 2m05s and brought back all three. `task data-check` caught the `/data` change before the restore.

- Logins through batchmate.id, against cluster-config `k3s-ha-cilium` at `2c6fe8f` plus the k3s role's OIDC change, uncommitted. `task k3s -l` on greene, then crosby, restarted each API server with `authentication-config`; v1 of `AuthenticationConfiguration` was accepted. `task whoami` came back `batchmate:sub_fbb0…` after a browser login. RBAC as that user: refused everything with no bindings; with `view` bound in `monitoring`, pods there yes, `kube-system`, Secrets and delete no; with cluster-admin, `can-i '*' '*'` yes. Argo CD's "Log in via Recurse" failed with `invalid_request` until `enablePKCEAuthentication` (finding 3 below), then worked. As `role:recurser` you can get and sync but not delete; `LAB_OIDC_ADMINS` makes you admin in both, and an empty list takes it away again. Snapshot `new-oidc`.

Not run yet: `task up STAGE=new` in one go (its pieces ran inside the migration), the k3s and Cilium upgrade drills, the OS upgrade drill.

## Findings for cluster-config

These came out of the runs above. The lab doesn't work around them; they're for the PR.

1. **heap-check.sh can't read crosby's `/etc/cni/net.d`.** Cilium created the directory as 0700 (no podman conflist made it first on crosby), and the check runs `ls` without sudo, so two `joined` checks fail on crosby with "Permission denied". The real crosby probably has the same mode. The checks pass when run with sudo by hand.
2. **The node goes Ready before Cilium exists.** On greene, k3s v1.36 marked the node Ready about 6 s after starting, because containerd accepts podman's `87-podman-bridge.conflist` in `/etc/cni/net.d`. Pods scheduled in that window fail sandbox creation (no `bridge` plugin in `/opt/cni/bin`, here or on Heap) and wait for Cilium, so no pod landed on podman's network. Anything that waits for Ready, such as a check or the role, is waiting for the wrong thing.
3. **crosby's teardown leaves Cilium interfaces only some of the time.** On the first run `cilium_host`, `cilium_net`, the `CILIUM_` chains and the tc programs were all gone after `k3s-teardown.yml`, with no reboot. On the second (2026-11-17, 12:10) `cilium_host`, `cilium_net` and `cilium_vxlan` were still there, as the vault's 2026-11-16 note says. Plan on the 3.3 reboot.
4. **prometheus.prometheus 0.27.0**, pinned in `requirements.yml`, refuses to install on ansible-core above 2.18, and its `_common` role fails on 2.19+'s strict conditionals. Anyone running `configure.yml` from a current laptop hits this. The lab installs it anyway and relaxes conditionals for `base.yml` only.
5. **roles/nfs_server** formats the whole device and then partitions it, so it fails on a blank disk. Harmless on Heap, where sdb already has a partition.
6. **`heap-check clean` fails on crosby after the 3.3 reboot.** fstab line 14 bind-mounts `/home/k3s-containerd` back over `/var/lib/rancher/k3s/agent/containerd` at boot, so "nothing mounted under k3s's directories" lists it. The teardown allowlists that target and the runbook's crosby table expects the mount (P-9), so card step c can't pass on crosby as written. mercer has the same line. The lab's `card.sh` stops there; on 2026-11-17 crosby's card was finished by hand from step d.

## Findings for heap-k8s

From the first `task argo`, 2026-11-17, against `IanEff/heap-k8s` at 66b7a83. Both stop a fresh bootstrap on Heap too. The lab unblocked them by hand on the live cluster (snapshot `new-argo` has both); the repo is unchanged.

1. **The root app deadlocks on its first sync.** `platform/argocd` is wave -3 and uses project `platform`; `projects/*.yaml` have no wave, so they're wave 0. With the Application health check in `argocd-cm`, root waits for `argocd` to be healthy, and it can't be while its project doesn't exist ("Application referencing project platform which does not exist"). Fix: `argocd.argoproj.io/sync-wave: "-4"` on both AppProjects. The lab applied `projects/` with kubectl.
2. **Every Ingress stays Progressing.** Cilium's ingress on the host network never fills in `status.loadBalancer`, and Argo CD's built-in Ingress health check waits for it. `argocd-server`'s Ingress kept `platform/argocd` Progressing, which blocked root again at wave -3, and any community app with an Ingress would never go Healthy. Fix: a `resource.customizations.health.networking.k8s.io_Ingress` check in `platform/argocd/values.yaml` that returns Healthy. The lab patched that key into the live `argocd-cm`; `platform/argocd` is manual sync, so nothing reverts it.
3. **batchmate.id refuses any login without PKCE, confidential clients included.** Its `AuthorizationRequest` requires `code_challenge` with `S256`, so Argo CD's server-side login came back `invalid_request`. Argo CD 3.6 sends PKCE from the server only with `enablePKCEAuthentication: true` in `oidc.config`. Fixed in heap-k8s; Grafana (`use_pkce`), JupyterHub (`enable_pkce`) and Concourse's Dex will each need the same. kubelogin does it unasked.
4. **Argo CD logs every user's claims.** argocd-server logs the whole id token at info on each API call: email, name, pronouns, picture. On Heap that's the email of every Recurser who logs in, in the pod's logs. Decide whether that's fine or lower the log level.

## Findings for batchmate.id

From the same run; for Chandler, not for a PR.

1. **No CORS on `/oauth/token`.** A preflight gets `405`, so a browser-side PKCE flow (Argo CD's UI mode, for one) can't read the token response. Server-side flows are unaffected.
2. **No `federated_claims` yet.** Both systems key on the gateway's `sub`, so every binding made today is rewritten when the RC id arrives. The role's username expression switches to `rc:<id>` on its own; Argo CD does too only if the claim uses Dex's shape, `{"user_id": "<id as a string>"}`.
3. **The identity-provider slug is `www.recurse.com`.** The gateway's upstream callback is `https://batchmate.id/oauth/broker/www.recurse.com/callback`.

## Known issues

- **Fix for the egress outages below:** stop all three VMs so `limactl usernet` exits, then start them (`task snap` does both). On 2026-11-17 the outage ran past 25 minutes and took guest-to-Mac traffic down with it; a restart of usernet cleared it at once. Its outbound connections were leaving from ProtonVPN's tunnel address (10.2.0.2).

- **Egress through Lima's user-v2 NAT drops for minutes at a time.** Three windows on 2026-11-17, two of them starting right after a snapshot restarted the VMs; the longest ran about ten minutes. `get.k3s.io` and docker.io timed out from every node at once (18 of 20 tries failing), while the Mac reached both 60 of 60 times. A k3s.yml run inside the window fails at the installer download; rerun it. `up` and `snap` now wait until every node gets three answers in a row before handing back. The cause isn't known; the Mac had Tailscale and ProtonVPN up. A pull-through cache on the Mac (galley's) would take the image pulls off this path, and is the next thing to add.
- **pod CIDR traffic to the gateway.** While a node has no Cilium (crosby between its join and its agent starting), its API server's calls to pod IPs on other nodes go to the default gateway, and Lima's NAT tries to carry them out through the Mac. On Heap they'd die at the upstream router. Harmless, but it shows up as SYN_SENT sockets in `limactl usernet`.

## Stages

`task up` builds one of two stages, chosen by `STAGE` or `LAB_STAGE` in `config/heap-lab.env`.

| Stage | Is | Built by |
|---|---|---|
| `old` (default) | Heap on 2026-11-16 | `playbooks/base.yml`, `playbooks/old.yml`, Cilium on crosby with Helm, `manifests/old/` |
| `new` | The migration's end state | `playbooks/base.yml`, cluster-config's `k3s.yml`, `scripts/addons.sh`, the canary |

Flip the default to `new` once Heap's Phase 7 is done. Getting from old to new inside the lab is the migration itself, one node card at a time (Drills, 1).

Both stages finish by recording `/data`'s checksum and taking a snapshot named `<stage>-fresh`. `SNAP=0 task up` skips the snapshot.

## Drills

Each one starts from a snapshot and ends with `task restore`.

### 1. The migration, node by node

```bash
task restore NAME=old-fresh
task canary CLUSTER=old         # optional: something to watch through the move
task watch                      # in a second terminal
task card NODE=greene           # Phase 2: teardown (old-agent path), join as cluster-init
task card NODE=crosby           # Phase 3: teardown (standalone path), reboot, join as server
# Phase 5 by hand: move the stand-in apps' data from /data/k8s-migration/
task card NODE=broome           # Phase 7: teardown (old-server path), join as agent
task check -- baseline
task data-check
```

`task card` is the runbook's node card, steps b to m: `k3s-teardown.yml`, `heap-check clean`, the /data checks, the copied volumes, crosby's reboot and ufw rule (3.3, 3.4), `k3s.yml -l`, `heap-check joined`. It stops at the first check that fails. Phase 7's gate (7.g1 to 7.g6) is yours to check before broome's card; the lab doesn't enforce it, so it can show what happens when the gate is skipped.

### 2. A k3s upgrade

```bash
task restore NAME=new-fresh
# in cluster-config: bump k3s_version in roles/k3s/defaults/main.yml
task watch                                  # second terminal
task k3s -- -e k3s_allow_upgrade=true       # init server, then crosby, then broome, serially
task check -- joined greene                 # heap-check reads the expected version from the checkout
```

The watch shows each API server's gap and whether ingress on any node blinked. Run it once without `k3s_allow_upgrade` first: the role should refuse.

### 3. A Cilium upgrade

Bump `k3s_cilium_version` (or change `k3s_cilium_values`) in the checkout and run `task k3s`. The HelmChart in each server's manifests directory changes; k3s's helm-controller does the rest without a k3s restart. `rollOutCiliumPods` restarts the agents, which is where ingress drops would show in the watch.

### 4. Losing broome, or one etcd member

`limactl stop heap-broome` with the watch running shows what every pod with an NFS volume does while /data is gone (a `hard` mount hangs; it doesn't error). `limactl stop heap-crosby` shows the two-member etcd losing quorum, the cost D-2 accepted.

### 5. An OS upgrade

`task ssh NODE=crosby`, then `sudo apt-get update && sudo apt-get -y full-upgrade && sudo reboot`. The question is whether k3s, Cilium and ufw come back on the new kernel without help. Snapshot first.

## Tasks

| Task | Does |
|---|---|
| `task up [STAGE=old\|new]` | Build to a stage, or start stopped VMs if it's already there |
| `task down` / `task destroy [FORCE=1]` / `task rebuild [STAGE=]` | Stop, delete (snapshots too), delete and build |
| `task status` | VMs, stage, each cluster's nodes and stuck pods, snapshots, `/data` check |
| `task snap NAME= [NOTE=]` / `task restore NAME=` / `task snaps` | Whole-lab snapshots |
| `task k3s -- <args>` | cluster-config's `k3s.yml` |
| `task teardown NODE=` | cluster-config's `k3s-teardown.yml`, with the lab's old server |
| `task card NODE=` | The runbook's node card |
| `task check -- baseline\|clean N\|joined N` | cluster-config's `heap-check.sh`, pointed at the lab |
| `task play -- <playbook> <args>` | Any playbook from `playbooks/` or the checkout |
| `task argo` / `task argo-status` / `task argo-ui` | Phase 4 from `HEAP_K8S`: bootstrap Argo CD, or push the repo's latest commit and refresh; list Applications; the UI on localhost:8080 |
| `task oidc` / `task whoami` | batchmate.id logins: check the API servers, write `.state/kube/login.yaml`, configure Argo CD, apply `LAB_OIDC_ADMINS`; `kubectl auth whoami` as yourself |
| `task watch` | Disruption probe until Ctrl-C, then outages per target |
| `task canary [CLUSTER=new\|old\|delete-new\|delete-old]` | The probe's target app |
| `task data-check` / `task data-record` | `/data` unchanged since the baseline |
| `task ssh [NODE=]` / `task kubeconfig` / `task timeline` | Shell; re-fetch kubeconfigs and ssh config; seconds per build phase |

## How it works

**Testing a checkout.** `HEAP_REPO` in `config/heap-lab.env` names the cluster-config working tree. `scripts/play.sh` runs a playbook from it with the lab's `ansible.cfg` and inventory and its `roles/` on the path, and logs each run to `.state/runs/` with the branch and commit it ran. To rehearse a branch, check it out there, or point `HEAP_REPO` at a second worktree in `.env`.

**Inventory.** Hosts are `greene.heap-lab`, `crosby.heap-lab` and `broome.heap-lab`, so `inventory_hostname_short` is the Heap node name and k3s's node names match Heap's. The domain resolves only through `.state/ssh_config`, which `scripts/ssh_config.sh` writes from Lima's own per-instance ssh config. Ansible, `heap-check.sh` and the scripts all pass it with `-F`. The groups match cluster-config's `inventory/hosts`, plus `old_server`, `old_agents` and `experiment` for the old stage.

**Network.** Lima's `user-v2` network gives each VM one NIC on 192.168.104.0/24, with the VMs as L2 neighbours. The provision step in `lima/node.yaml` adds a fixed address that netplan brings up before DHCP, so it becomes eth0's primary, and points the default route at it. Changing the DHCP address instead hangs `limactl shell`: Lima's ssh is forwarded to that address. Tested 2026-11-17: the fixed address survives a restart, reaches the internet and the other VMs, and Lima's ssh keeps working.

**APIs.** Each VM forwards its 6443 to the Mac: greene 16443, crosby 16444, broome 16445. `scripts/kubeconfig.sh` fetches whichever admin kubeconfigs exist into `.state/kube/` and drops ones whose node no longer runs a server.

**Snapshots.** `limactl snapshot` is QEMU-only, and the lab runs on vz. `scripts/snap.sh` stops all three VMs (a clean shutdown, so etcd and sqlite are consistent), clones each VM's root `disk` (`diffdisk` on Lima before 2.2) and `vz-efi`, and broome's data disk with `cp -c` (APFS clonefile: instant, and blocks only take space once they diverge), and starts them again. Restore reverses it. `.state/`'s stage, kubeconfigs and /data baseline go with the snapshot.

**The watch.** `scripts/watch.sh` probes each API server's `/readyz` from the Mac through its forward (any HTTP answer counts as up) and, from a shell on broome, each Ingress host on every node's port 80 (`scripts/guest/probe.sh`). The canary's writer stamps the time into an NFS volume every second, and its web pods serve the stamp, so one probe covers ingress, the pod network, Services and NFS: an answer more than 5 s old is reported as stale. Rows go to `.state/watch/<time>.csv`; Ctrl-C prints each target's outages as offsets from the start.

**Logins.** cluster-config's k3s role does the API servers' half: with `LAB_OIDC_KUBECTL_CLIENT_ID` in `.env`, the inventory hands it the issuer and client, and `task k3s` writes `/etc/rancher/k3s/authentication.yaml` and adds `authentication-config` to each server's flags. `scripts/oidc.sh` does the rest. It writes `.state/kube/login.yaml`, whose user runs kubelogin (`kubectl krew install oidc-login`) with its token cache in `.state/kube/oidc-cache`, so nothing lands in `~/.kube`. It patches `oidc.config` and `url: http://localhost:8080` into the live `argocd-cm` and puts the client secret in Secret `argocd-oidc`, passed through a file descriptor so it never appears on a command line. Last, it rewrites one ClusterRoleBinding and one marked block of `policy.csv` from `LAB_OIDC_ADMINS`. The clients need `http://localhost:8000` (kubectl) and `http://localhost:8080/auth/callback` (Argo CD) as redirect URIs.

**/data.** `scripts/data.sh` checksums every file under broome's `/data` except `k8s/`, `k8s-migration/` and `lab-canary/`, which the migration writes on purpose. `heap-check.sh baseline` counts entries; this proves the bytes.

## Layout

```
config/heap-lab.env      every value: HEAP_REPO, stage, sizes, addresses, versions (.env overrides)
lima/node.yaml           the VM template; address and hostname are parameters
inventory/               hosts.yml shaped like cluster-config's, group_vars, host_vars
playbooks/base.yml       configure.yml's roles plus Heap's hand edits and leftovers
playbooks/old.yml        the old cluster and crosby's experiment
manifests/old/           old-cluster stand-ins; manifests/new/ heap-nfs; manifests/canary.yaml
scripts/                 up, down, destroy, snap, play, card, check, watch, data, ...
scripts/guest/probe.sh   the watch's broome side, fed over ssh
bin/                     new, old, crosby: kubectl per cluster
.state/                  ssh_config, kube/ (admin kubeconfigs, login.yaml, oidc-cache/), runs/, watch/, timeline.csv (gitignored)
.snapshots/              whole-lab snapshots (gitignored; destroy removes them)
.cache/collections/      cluster-config's Ansible collections (gitignored; kept)
```

## Host changes

None outside the repo and Lima's own directories: the three instances and the `heap-broome-data` disk under `~/.lima`. `~/.ssh/config` and `~/.kube/config` aren't touched. It needs about 12 GiB of free memory for the default sizes; on a 32 GiB laptop that leaves room for everything else.
