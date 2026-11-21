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
| One NIC per node, all four on one /27 and one /64 (`2602:fb65:0:90::/64`), L2 neighbours, MTU 1500 | One NIC per VM on Lima's `user-v2` network carrying both families, L2 neighbours; addresses .138, .132, .133 and `::11`, `::3`, `::4` as on Heap, with neighbour discovery and DAD working | user-v2, plus fixed addresses set by netplan and `heap-lab-ndp` (How it works, Network) |
| greene `cluster-init`, crosby second server, broome agent; two-member etcd | Same three roles; same etcd arithmetic | `inventory/hosts.yml`, cluster-config's `k3s.yml` |
| Old cluster: broome v1.31.2 server on sqlite with `--flannel-backend=vxlan`; greene v1.31.6 agent with the GPU labels | Same versions, installed with the commands from master's `roles/k3s/tasks/{head,worker}.yaml` | `playbooks/old.yml` |
| crosby: a standalone v1.36.6 with Cilium 1.20.4 (cluster-pool), containerd bind-mounted from `/home/k3s-containerd`, an `lxc+` ufw rule | Same, with crosby's k3s flags reconstructed (see below) | `playbooks/old.yml`, `scripts/up.sh` |
| configure.yml's host roles: firewall, fail2ban, host, env, metrics (node_exporter on 9100), oomd, nfs_server on broome | The same roles from your checkout | `playbooks/base.yml` |
| ufw: deny in, allow from the cluster /27 and /64, plus hand-added rules on broome and crosby | The firewall role with the lab's /24 and /64 as `cluster_network` and `cluster_network_v6`, plus the drift rules | `playbooks/base.yml` |
| broome's `/data`: ext4 on sdb1, exported over NFS, 12 top-level entries, 73 in the archive | ext4 on vdb1 from the nfs_server role, seeded with the same counts | `playbooks/base.yml` |
| `broome` is 127.0.0.1 on broome, so `ray-pv` mounts it over loopback | The host role writes the same line; a `ray-pv` stand-in mounts it on broome | `manifests/old/workloads.yaml` |
| The other nodes mount broome:/data `hard` | Same, over IPv4 | `playbooks/base.yml` |
| local-path volumes on greene and broome, gpu-feature-discovery's subPath of `/etc`, an Ingress on traefik through servicelb | Stand-ins for each, with known bytes in every volume | `manifests/old/workloads.yaml` |
| podman's conflist on greene and broome; Calico's conflist and kubeconfig on broome; setuid calico binaries on broome and greene | Same files (the binaries are inert) | `playbooks/base.yml` |
| Swap on, `/swap.img`; inotify instances at Ubuntu's 128 | 1 GiB `/swap.img`, same fstab line; 128 | `playbooks/base.yml` |

crosby's experiment is the weakest row. The scan recorded what the experiment ended up with, not the command that built it. `playbooks/old.yml` uses `flannel-backend: none`, `disable-network-policy`, CIDRs 10.44/10.45 and kube-proxy left on; the 10.44 comes from its ufw rule, the rest is a guess.

## What isn't

| Difference | What it means for a drill |
|---|---|
| arm64 (Apple silicon), Heap is amd64 | k3s, Cilium and the busybox stand-ins are multi-arch. An app image that's amd64-only (JupyterHub's user image is a candidate) won't start here. |
| No GPUs, no `gpu` group | `default-runtime: nvidia`, the device plugin and the GPU labels from the new role go untested. The old stand-in carries the old role's labels only. |
| `system-reserved` 512Mi and eviction at 100Mi, against Heap's 6-10Gi and 1Gi | The reservations can't be sized here. Everything else the role renders is unchanged. |
| 4 GiB per VM, 2 vCPUs | Memory pressure arrives sooner than on Heap; it isn't a test of Heap's headroom. |
| Lima's DHCP address stays on eth0 as a secondary | Lima's ssh needs it. Routes, k3s and Cilium use the fixed primary. |
| IPv6 on a ULA /64, `fdf2:4f9f:1e83:90::/64` (`LAB_IPV6_PREFIX`), with Heap's interface IDs | Heap's addresses are global, and glibc ranks global IPv6 above IPv4 but ULA below it (RFC 6724's default table). A name with both families connects over IPv6 on Heap and over IPv4 here. The lab's `/etc/hosts` has IPv4 only anyway, so the /data mounts go over IPv4 where Heap's go over tcp6. The new StorageClass names broome's IPv4 address, so the new cluster matches. |
| No IPv6 router | No RA, no IPv6 default route, no IPv6 internet. Node to node and pod to pod work; IPv6 to anything outside the /64 doesn't. Heap's eth0 presumably has an IPv6 default route (no scan has recorded one); if so, the lab's lacking one is a difference in what Cilium's device autodetection (D-17) sees, and nobody has checked whether it changes what Cilium picks. |
| `heap-lab-ndp` sends IPv6 multicast out of eth0 as broadcast | user-v2's switch drops multicast, so without it neighbour discovery and DAD never get an answer. With it, every node receives every other node's neighbour solicitations and MLD reports, and each kernel still filters on the multicast address. It's a `netdev` table in nftables, beside ufw's and Cilium's iptables rules; `nft list table netdev heap_lab_ndp` shows it. |
| A 20 GiB virtual disk under /data, not a failing 10 TB one | No pending sectors. The fstab line has no `nofail`, as on Heap, so a missing disk would stop the boot. |
| No mercer | A second old agent and a second bind mount, both covered by greene and crosby. vllm's pin to mercer has nowhere to go. |
| Left out: users, svc-accts, sshd, ansible-pull, network, nix, popular_software, motd, gpu, nomad, mercer's and crosby's `/home` exports | None of it sits under k3s. `playbooks/base.yml` says why for each role. |
| unattended-upgrades off | So a snapshot stays the same snapshot. OS upgrades get drilled deliberately. |
| No public IPs or upstream filter | Ingress is tested from inside the lab, as the runbook does from broome. |
| `unreachable` routes for 10.44.0.0/16 and 10.45.0.0/16 on every VM | The lab's own instrument, standing in for Heap's upstream router dropping pod-range packets that leave a node before Cilium routes them. Without it Lima's NAT stalls every VM's TCP egress (Known issues). |
| `/opt/cni/bin` holds only the inert calico stand-ins | Heap's broome and greene also have `bandwidth`, `flannel`, `host-local`, `loopback`, `portmap` and `tuning` there from 2025. Not copied: a fake `loopback` would break what a real one makes work. |
| Argo CD syncs the lab's copy of heap-k8s, served from broome | `heap-k8s/` is a subset of recursecenter/heap-k8s at `HEAP_K8S_MIRRORED`: bootstrap, projects, `apps/_template`, and argocd, sealed-secrets, cert-manager, csi-driver-nfs and rbac under `platform/`. monitoring, nvidia-device-plugin and kuberay-operator are left out. Heap's values are placeholders, and four marked deltas make it go green: waves on the AppProjects and the Ingress health check (heap-k8s findings 1 and 2), the port-forward as Argo CD's `url`, and a self-signed `letsencrypt-prod`. `heap-k8s/README.md` has the list; `task argo-drift` shows the diff against upstream. `task argo` publishes it from broome on 8418, the lab's own git server, and stops if a Heap address is left in anything Argo CD applies. `task argo SOURCE=upstream` syncs all of upstream instead, with only its values swapped. `task up STAGE=new` still installs csi-driver-nfs with Helm from `scripts/addons.sh`; Argo CD adopts the release. |
| No sealed secrets, no Cloudflare token | The lab's `heap-k8s/` has no monitoring and a self-signed issuer, so nothing waits on a secret. With `SOURCE=upstream`, Grafana waits for `grafana-admin` and the ClusterIssuer is Degraded, as on a fresh Heap until someone seals them (heap-k8s finding 5). |
| Logins go through the real batchmate.id, with your own clients | There's nothing to stand in for: the API servers and Argo CD trust `https://batchmate.id` exactly as Heap will, so a login needs the internet and Chandler's gateway up. `task oidc` patches Argo CD's settings onto the live cluster and keeps its client secret in a Secret it creates from `.env`; heap-k8s carries the same settings and still has to seal that secret. Admins come from `LAB_OIDC_ADMINS`, the lab's own instrument; on Heap they belong in heap-k8s. |

## What has been run (2026-11-17)

Against cluster-config `k3s-ha-cilium` at `db38bb4`, uncommitted. Lima 2.2.1, ansible-core 2.21.5, an M1 Max with 32 GiB.

- `task up` (old) builds in about 3 minutes from cached images. Every stand-in comes up; `heap-check.sh baseline` reports 12 entries, 73 archive entries and exactly one NFS mount under kubelet, `ray-pv` on broome, which is what it reports on Heap.
- The whole migration, one card at a time: greene (old-agent path), crosby (standalone path), then broome (old-server path, with the old workloads and `ray-pv`'s loopback mount still in place, so Phase 7's gate was skipped on purpose). Each teardown copied its local-path volumes to `/data/k8s-migration/<node>/` and passed `heap-check clean`, and `/data`'s checksum never moved. All three nodes joined v1.36.6+k3s1 with Cilium 1.20.4 and passed `heap-check joined`, apart from the two crosby failures under Findings.
- csi-driver-nfs 4.13.6 and `heap-nfs`: a PVC provisioned `/data/k8s/lab-canary/heartbeat` on broome, and the canary answered through Cilium's ingress on all three nodes.
- `task watch` through `systemctl restart k3s` on crosby: crosby's API was out for 7 s (5 s with no answer, then 2 s answering 503); greene's API and the canary on every node never dropped.
- Snapshot and restore: after deleting a namespace, adding a file on greene and changing a file in `/data`, restoring `old-fresh` took 2m05s and brought back all three. `task data-check` caught the `/data` change before the restore.

- Logins through batchmate.id, against cluster-config `k3s-ha-cilium` at `2c6fe8f` plus the k3s role's OIDC change, uncommitted. `task k3s -l` on greene, then crosby, restarted each API server with `authentication-config`; v1 of `AuthenticationConfiguration` was accepted. `task whoami` came back `batchmate:sub_fbb0…` after a browser login. RBAC as that user: refused everything with no bindings; with `view` bound in `monitoring`, pods there yes, `kube-system`, Secrets and delete no; with cluster-admin, `can-i '*' '*'` yes. Argo CD's "Log in via Recurse" failed with `invalid_request` until `enablePKCEAuthentication` (finding 3 below), then worked. As `role:recurser` you can get and sync but not delete; `LAB_OIDC_ADMINS` makes you admin in both, and an empty list takes it away again. Snapshot `new-oidc`.

- The lab's `heap-k8s/` (2026-11-18), mirroring recursecenter/heap-k8s at `74d7823`, published over the IanEff copy on snapshot `pre-lab-k8s`. heap-k8s's own `scripts/validate.sh` passed on the rendered tree. root went Synced and Healthy for the first time: monitoring, kuberay-operator and nvidia-device-plugin were pruned (Prometheus's and Grafana's volumes went to `/data/k8s/archived-monitoring`), `rbac` arrived at wave 0, and `letsencrypt-prod` went Ready. `platform/argocd` stays OutOfSync until its first manual sync (4.12): the diff is Argo CD's `tracking-id` annotation on every object bootstrap.sh's Helm install made, `oidc.config`'s comments, and `LAB_OIDC_ADMINS`'s line in `policy.csv`. 4.8 on upstream's StorageClass, which has no `nfsvers`: a PVC bound, mounted as NFS 4.2, wrote, and was archived when its namespace went.

- The RC id and the device flow (2026-11-20), against cluster-config `k3s-ha-cilium` at `fb4e0f7` plus the role change for `idp_issuer` and `idp_subject`, uncommitted. batchmate.id now advertises `device_authorization_endpoint`. kubelogin v1.36.4 with `--grant-type=device-code` and Heap's public `kubectl` client got an id token once the code was approved in a browser. kubelogin opens the link itself and prints nothing at the default log level. The token carried `idp_issuer: "https://www.recurse.com"` and `idp_subject: "7776"`, a string, and no `federated_claims`. `task k3s -l greene.heap-lab,crosby.heap-lab` changed only `authentication.yaml`; both API servers logged `reloaded authentication config`, with no restart. `whoami` came back `rc:7776` with groups `[batchmate:recursers heap:admins system:authenticated]`; `heap:admins` came from `admin_rc_ids` (nine unexpired that day). As that user with nothing bound to `rc:7776`: list pods everywhere and read `kube-system` logs yes, Secrets and delete no, cluster-admin no, because `LAB_OIDC_ADMINS` still named `sub_…`. With `7776` added, `can-i '*' '*'` yes. Then the lab's copy of heap-k8s took heap-k8s `64b3b5c`'s `scopes: "[groups, idp_subject]"` (only that change; `HEAP_K8S_MIRRORED` stays `74d7823`), `platform/argocd` was synced, and `LAB_OIDC_ADMINS` became `7776` alone. A device-flow id token from the lab's Argo CD client, as a bearer on Argo CD's API: userinfo `groups: ["7776"]`, and `can-i` yes for applications get, sync and delete and clusters create. Not run: the device flow from inside a VM with no browser.

- IPv6 on user-v2 (2026-11-20), on scratch instances built from `lima/node.yaml`, not on the heap-* VMs. Before `heap-lab-ndp`: ULA and link-local pings both failed. After it: pings both ways on the ULA addresses and on `fe80::`, a 1452-byte payload with DF set, HTTP over IPv6, all again after a restart; DAD flagged a duplicate address; the fixed IPv4 address stayed eth0's primary, the DHCP address didn't move, and `limactl shell` kept working. With ufw rules set by hand the way the firewall role sets them (deny in, allow the /24), TCP over IPv6 was refused until the /64 was allowed too, which is why `base.yml` passes `cluster_network_v6`. `limactl edit` on a stopped instance built from the previous template, swapping in the new `provision`, `probes` and `param.NodeIPv6`, brought IPv6 up at the next start with the same DHCP address. Not run: k3s or Cilium on IPv6.

- Dual-stack, the whole migration (2026-11-20), against cluster-config `k3s-ha-cilium` with the dual-stack role (P-16), uncommitted, ProtonVPN off. `task destroy`, then `task up` (old, 6m47s), then `task card` for greene, crosby and broome with no hand steps: crosby's card got past step c after its 3.3 reboot and its CNI checks passed, with findings 1 and 6 fixed in the branch. Every `heap-check joined` check passed on all three, including the IPv6 pod range, Cilium allocating IPv6 and IPv6 masquerade. Each node got a /24 and a /64 (`fdda:e07:a308:4400::/64` on greene); pods got both families; pod-to-pod pings across nodes worked on both; a `RequireDualStack` Service answered on its IPv6 ClusterIP. `task argo`: root and every platform app Synced and Healthy, `argocd` OutOfSync until 4.12 as before. The canary's heartbeat came back fresh with 200 through Cilium's ingress on all three nodes' IPv4 and IPv6 addresses; Envoy listens on `0.0.0.0:80` and `[::]:80`, but only once an Ingress exists. `task data-check` passed. `cilium connectivity test`: 86 of 90 passed. The three `pod-to-ingress-service` tests failed on both families, and `check-log-errors` failed on Envoy NACKs: the test's dedicated-mode Ingresses have no `ingress.cilium.io/host-listener-port`, so each tries to bind 80 beside the shared listener. The runbook's 3.7 and 7.2 will show the same on Heap. Two earlier attempts the same day stalled on the egress outage now fixed under Known issues. Not run: the snapshot of this state.

- Losing a server, and an etcd restore (2026-11-20), on the dual-stack cluster above. `task watch` running throughout. crosby stopped with `limactl stop` for 2m55s: greene's API down 168 s, the canary on greene and broome kept answering but its heartbeat went stale for 156 s (the writer was on crosby, and with no API nothing replaced it). greene stopped for 2m47s: crosby's API down about 165 s, and the canary down on broome and crosby too, about 100 s, then flapping for 1.5 minutes after greene came back, on both families. The restarted pods failed one NFS mount each, then came up. Restore: a ConfigMap made before `k3s etcd-snapshot save --name drill` on greene, swapped for another after it; both servers stopped; `--cluster-reset-restore-path` on greene, then greene started, crosby's `server/db` moved aside and crosby started. 33 s from stop to both servers Ready. The first ConfigMap was back and the second gone; both API servers report etcd ok; `heap-check joined` passed on greene and crosby; the canary answered on both families; Argo CD's apps went Unknown, root Degraded, and all came back Synced and Healthy within two minutes with nothing done.

- greene down again, instrumented (2026-11-21), from `task restore NAME=new-dualstack`. The canary sat as it did on 2026-11-20: `web` on broome and greene, `writer` on crosby. `task watch` ran beside a throwaway probe on broome and crosby that asked every node's ingress and each `web` pod by IP twice a second (curl capped at 2 s), and every 3 s read Envoy's admin socket and `cilium-dbg service list` off the host, so neither needed the API. `limactl stop heap-greene` took 31 s to shut down; greene was started again 100 s after it went off. The watch's "down 100 s, then flapping" turned out to be two failures overlapping:
  - **The heartbeat stopped for 104 s.** The writer's last stamp is the second greene powered off, and the next came 104 s later, while greene was still booting. broome's nfsd gives each client reading `heartbeat/heartbeat` a read delegation (`/proc/fs/nfsd/clients/*/states` lists one for .133 and one for .138). The writer's `mv` over that file has to recall greene's, a dead client never answers, and nfsd holds the rename until greene's lease lapses (`/proc/fs/nfsd/nfsv4leasetime` is 90). Every `web` pod served the stale stamp in the meantime.
  - **About half of the requests to ingress on broome and crosby failed for 148 s.** That ran from greene's power-off until the EndpointSlice carrying greene's restarted pod (new IP) reached them, curl timing out at 2 s or Envoy answering 503. crosby's API was down from greene's shutdown to +111 s, so nothing took greene's pod out of the Service. Cilium kept it `active` and handed it to Envoy as `HEALTHY`. Envoy's outlier detection found it five times and ejected it none (`ejections_detected_consecutive_local_origin_failure: 5`, `ejections_enforced_total: 0`, `ejections_overflow: 5`): ejecting one of two hosts breaks the ejection cap. The cluster has no health checks and no `connect_timeout` (Envoy's default 5 s: 20 `upstream_cx_connect_timeout`), and the route has no retry policy (`upstream_rq_retry: 0`). The ClusterIP failed the same way from broome's host, 5 of 12, with no Envoy in the path. Once the writer was back at +104 s, these failures were what the watch showed as flapping.
  - **Retest with delegations off.** On a fresh restore, broome got `sysctl fs.leases-enable=0` and an `nfs-server` restart (a lab experiment, restored away afterwards), and `/proc/fs/nfsd/clients/*/states` then listed no delegations. The same 120 s stop of greene left the heartbeat never more than 1 s old. The endpoint failures were unchanged: roughly half of the requests to ingress on broome and crosby failed until +160 s, crosby's API answering 503 until +140 s. greene's `limactl start` returned in 22 s this time; the first run's start hung with greene's sshd never up and was abandoned for a restore.
  Not run: an agent down with the API up, where the node controller should drop its pods' endpoints after its grace period; a shorter lease in place of delegations off.

- broome down on the new stage (2026-11-21), from `new-dualstack`, with the same probes on greene and crosby. The canary's only NFS volume is the one PVC; `web` sat on broome and greene, `writer` on crosby. Two runs:
  - **`limactl stop heap-broome` for 180 s.** It returned in 31 s. Both APIs answered throughout. From the moment broome began shutting down, greene's `web` pod stopped answering (each read blocked on the `hard` mount), and the writer stopped. Ingress on greene and crosby returned curl timeouts, then mostly Envoy 503s after about +30 s. broome's `limactl start` took 9 s; 10 s later greene's pod answered with a 227 s-old stamp, and the stamp was fresh 10 s after that. Every ingress answered from +200 s. greene's `web` and crosby's `writer` kept their restart counts; only broome's own pods restarted, and broome's `web` failed one mount (`driver name nfs.csi.k8s.io not found`) before it came up. Envoy's endpoint for broome's dead pod went too, because the API was up.
  - **`sudo systemctl reboot` on broome.** It was gone for about 280 s, of which boot was 7 s (`systemd-analyze`). The shutdown hung on broome's own `web` pod: its NFS mount is served by broome, `nfs-server` had already stopped, and httpd's reads sat in uninterruptible sleep. The journal has SIGKILL at 195 s, "Still around after SIGKILL. Ignoring." at 285 s, and `systemd-shutdown` timing out on sync at 315 s. `/data` (no `nofail` in fstab) mounted at boot with no journal recovery; `nfs-server` and `k3s-agent` came up; `task data-check` passed. The canary's readers on greene hung and recovered without restarts, as in the first run.
  Not run: a boot with `/data`'s disk missing, which is what `nofail` would change.

- The Cilium upgrade, and whether the servers fight (2026-11-21), from `new-dualstack`, 1.20.4 to 1.20.5 (released 2026-11-17), passed as `-e k3s_cilium_version=1.20.5` so the checkout stayed untouched; `task watch` throughout.
  - **`task k3s -- -l greene.heap-lab` upgraded the whole cluster.** It changed only greene's manifest (`changed=1`), but the HelmChart is one object, so it went to 1.20.5 and every node's agent rolled. The DaemonSet's `maxUnavailable: 2` restarted greene's and broome's agents together. Ingress gaps: crosby 6 s, greene 12 s, broome 43 s.
  - **Restarting k3s on crosby put it back.** crosby's manifest still said 1.20.4. Within 10 s of `systemctl restart k3s` the HelmChart was at 1.20.4 (generation 2 to 3), a new `helm-install-cilium` job ran, and every agent went back to v1.20.4. The restart itself took both APIs out for 6 to 7 s. The downgrade's ingress gaps were up to 9 s.
  - **The full run fixed it.** `task k3s -- -e k3s_cilium_version=1.20.5` changed only crosby's file (greene's already said 1.20.5 and wasn't re-applied), the chart went to 1.20.5 (generation 4) and the agents rolled again in about 20 s, with ingress gaps of 9 to 14 s and no API gap.

- An OS upgrade on crosby (2026-11-21), from `new-dualstack`: `apt-get update && apt-get -y full-upgrade` (51 upgraded, 6 new, kernel 6.8.0-147 to 6.8.0-151), then `sudo systemctl reboot` with `task watch` running. crosby came back on 6.8.0-151 with ufw active, k3s active, the node Ready, and Cilium, Envoy and csi-nfs Running; `heap-check joined crosby` passed all 15 checks. The containerd bind mount (fstab line 6 in the lab) was mounted at 1.9 s after boot and k3s started at 4.9 s. The k3s unit names only `network-online.target` in `After=`; the order comes from systemd's default dependencies, which put every service after `local-fs.target` and so after fstab's mounts. Both APIs were out for 107 s (D-2 again), crosby's ingress for 132 s, and the canary was stale elsewhere for 36 s while its writer, on crosby, came back.

- A merge that deletes `apps/` (2026-11-21), from `new-dualstack`, through `task argo`. `apps/hello` was `_template` plus a 16Mi `heap-nfs` PVC mounted at `/data`; both were test fixtures, removed afterwards with `git restore`.
  - **The app couldn't deploy at all as committed.** Argo CD refused every sync with "resource :Namespace is not permitted in project community" (heap-k8s finding 6). For the rest of the run the lab's copy of `projects/community.yaml` allowed `Namespace`, marked as test-only, and reverted after.
  - **The template's pod couldn't write its own volume.** It runs as uid 101 and the provisioner makes each volume's directory `root:root 0755` (heap-k8s finding 7). With `securityContext: {fsGroup: 101}` added to the pod, kubelet made the directory `0:101 drwxrwsr-x` (the driver's `fsGroupPolicy` is `File`) and the write worked.
  - **Deleting `apps/` pruned everything within 10 s of the publish.** The Application, Deployment, Service, PVC and PV all went. `onDelete: archive` kept the data: `/data/k8s/archived-app-hello/hello-data/marker` had the marker's bytes. The namespace stayed Active with only `kube-root-ca.crt` and the `default` ServiceAccount, and an empty `/data/k8s/app-hello` stayed on broome. No `preserveResourcesOnDeletion` is needed to keep data; `git revert` brings the app back to a fresh volume, and the old bytes have to be moved back from `archived-*` by hand.
  - **With the git server stopped for 4 minutes, nothing was deleted.** The ApplicationSet went `ErrorOccurred` ("unable to resolve git revision") and kept its Applications; `app-hello` went `Unknown/Healthy` with its PVC in place.

- Backing out of a card (2026-11-21). Built from `old-fresh` with one fixture: the home volume on greene chowned to `1000:100`, so ownership could be checked (snapshot `t-old-fixture`). The cards ran at `CARD_ARGS='-e k3s_version=v1.36.5+k3s1'` (a new `card.sh` passthrough) with `HEAP_K3S_VERSION` to match, so the upgrade drill would have something to upgrade; the checkout was untouched. greene's card took 96 s and passed all 20 checks (snapshot `t-greene`); crosby's took 79 s, its pre-reboot FAIL included (snapshot `t-crosby`).
  - **greene back to the old cluster (Phase 2's back-out).** `k3s-teardown.yml` refuses new-cluster nodes, so `k3s-uninstall.sh` ran by hand. It left `cilium_host`, `cilium_net`, 34 `CILIUM` iptables rules and `05-cilium.conflist`; a reboot cleared all but the conflist, which v1.31's own CNI directory doesn't read. The two volumes were copied back from `/data/k8s-migration/greene/` to their local-path directories over a read-only NFS mount of broome's `/data`, before the agent existed (`rsync -aHAX --numeric-ids`, then a dry run: 0 differences). Then the v1.31.6 agent was installed with `playbooks/old.yml`'s flags and `config.yaml`, the node token from broome passed as `K3S_TOKEN_FILE`. greene was Ready 13 s later; the postgres stand-in ran on greene with `base.bin`'s hash unchanged; both volumes matched the first checksum, `1000:100` included; old ingress on greene answered 200. About a minute's work plus the reboot. The token file was deleted afterwards, which a real back-out mustn't do: the agent reads it on every start.
  - **crosby out of the new cluster (Phase 3's back-out), three ways, each from `t-crosby`.**
    - *Uninstall first, as the runbook implies.* `k3s-uninstall.sh` on crosby took greene's API down at once (`000`, then `503` for good). greene's etcd sat in pre-vote at term 4 with one vote of two, and `kubectl delete node crosby` got `ServiceUnavailable`. Recovery: stop k3s on greene, `k3s server --cluster-reset`, start k3s. 15 s to an API, then the node delete went through, and `heap-check joined greene` passed 14 of 14.
    - *Delete the node first.* greene's API stayed at 200, and k3s logged "Removing etcd member from cluster due to node delete". crosby's k3s, still running, then found the tombstone, wiped its `server/db`, exited, was restarted by systemd, and rejoined as a new member (`crosby-be545782`). It was back in `get nodes` about 40 s after the delete.
    - *Stop the restart, then delete the node.* A drop-in on crosby with `[Service] Restart=no`, `daemon-reload`, then `kubectl delete node crosby`. k3s removed the member, crosby's k3s exited and stayed `failed`, and greene's API never left 200. `k3s-uninstall.sh` on crosby then removed it for good (two Cilium interfaces were left, for a reboot). greene passed 14 of 14 as a one-member cluster. This is the only order that kept the API.

- Phase 5's data, and the Phase 7 gate (2026-11-21), continuing from `t-crosby` with csi-driver-nfs and `heap-nfs` from `scripts/addons.sh`. Every file in the three stand-in volumes was checksummed with its numeric owner and mode at three points: on local-path in the old cluster, in `/data/k8s-migration/<node>/` after the teardown, and in a new `heap-nfs` PVC after runbook 5.e. The postgres stand-in's `last-write`, which it rewrites every 5 s, was left out.
  - **The bytes moved intact.** New PVCs in `app-concourse` and `app-jupyterhub` (kubectl, not Argo CD, because of heap-k8s finding 6). Steps 5.d and 5.e: the old hub scaled to zero, then `rsync -aHAX --numeric-ids` on broome from the migration copies (greene's two) and from local-path (the hub's), each followed by a dry run that listed nothing. All three volumes matched at all three points, the home's `1000:100` included; each PVC root took local-path's `0777`. A pod running as `1000:100` with every capability dropped read the notebook with its hash unchanged and wrote a new file as `1000:100`.
  - **The teardown didn't refuse broome with `ray-pv` mounted.** broome's card ran with the old cluster's `rc-ray-head` still mounting all of `/data` over NFS under `/var/lib/kubelet/pods`. "Stop k3s and unmount pod volumes" (`k3s-killall.sh`) unmounted it, "List what is still mounted under k3s's directories" then found nothing, and the uninstall went ahead. `/data` was unchanged (148 files, same checksum), the hub's copy in `/data/k8s-migration/broome/` matched, and broome joined at v1.36.5 with every check passing. The 11-17 run behaved the same. Finding 13.

- The k3s upgrade drill (2026-11-21). v1.36.6+k3s1 is the newest v1.36 release, so the drill went from v1.36.5 to v1.36.6. The cluster from the two runs above (cards at v1.36.5, broome joined last) got the canary and became snapshot `t-v1365`. `task k3s` with the checkout's v1.36.6 refused on the first host: "greene.heap-lab runs k3s version v1.36.5+k3s1 (3dd98cc5), the inventory pins v1.36.6+k3s1. Set k3s_allow_upgrade=true to upgrade." `task k3s -- -e k3s_allow_upgrade=true` with `task watch` running took 61 s: greene, then crosby, then broome, `changed=1` each (the installer). APIs: both out 2 to 4 s while greene restarted, and both out 8 s while crosby did (D-2). Ingress never dropped. The canary's pods kept their restart counts through their nodes' k3s restarts. `heap-check joined` passed on all three at v1.36.6 (14, 15 and 14 checks). Not run: a minor version, since none exists yet.

- A test for every refusal (2026-11-21): `scripts/refusals.sh [old|new|all]`, new, against cluster-config `k3s-ha-cilium` at `dfb6639`. Each case passes only if the play fails and its log has that refusal's own message. The script restores `old-fresh` or `new-dualstack` before each group and between cases that change a node, so it can be rerun whenever the branch changes. All eight refused:

  | Case | Setup | Refused with |
  |---|---|---|
  | confirm | teardown of greene with `teardown_confirm=crosby` | "Pass -e teardown_confirm=greene" |
  | old-k3s | `k3s.yml -l greene` on the old cluster | "has a k3s install this role didn't make" |
  | bare-pod | a pod with no controller on greene, then its teardown | kubectl drain's "declare no controller" |
  | mount | a read-only NFS mount of broome's `/data` at `/var/lib/kubelet/heap-lab-refusal`, then teardown | "Still mounted under k3s's directories" |
  | flannel | a clean teardown of greene, a dummy `flannel.1`, then `k3s.yml -l greene` | "flannel.1 or cni0 still exists" |
  | cilium | the same with a dummy `cilium_host` | "cilium_host still exists" |
  | new-node | teardown of greene on the new cluster | "runs a k3s installed by roles/k3s" |
  | version | `k3s.yml -e k3s_version=v1.36.5+k3s1` on the v1.36.6 cluster | "Set k3s_allow_upgrade=true" |

  The mount case refuses only because its mount sits outside `/var/lib/kubelet/pods`; a pod's own volume is unmounted by `k3s-killall.sh` first (finding 13). The bare-pod refusal is kubectl's, and comes before anything is copied or stopped. The first full run lost its last two cases to the boot hang under Known issues; `refusals.sh new` passed them on its own.

- heap-k8s's `platform/cilium` against the role's Cilium (2026-11-21), on a throwaway restore of `new-dualstack`, restored away afterwards, with `task watch` running. The Application is heap-k8s `5c4473d`'s `platform/cilium/application.yaml`: chart 1.20.4, release `cilium` in `kube-system`, manual sync. Its values went inline, because the lab can't read the repo over SSH, and with `k8sServiceHost` changed from Heap's crosby to the lab's (invariant 7). Nothing went into `heap-k8s/`. Before: HelmChart 1.20.4 (generation 1), helm release `cilium` v1, IPAM `kubernetes`, IPv6 on, ingress on the host network.
  - **Applying it changed nothing, and Argo CD saw the other owner.** Every Cilium object, about 40, showed `OutOfSync`.
  - **A manual sync rewrote Cilium in 5 s.** `cilium-config` went to cluster-pool IPAM with IPv6 off, and the agents rolled. The nodes kept their pod ranges (the operator adopted the existing ones), so pods kept working. The ingress became a `LoadBalancer` Service on the node IPs (`loadBalancerClass: io.cilium/node`, `nodeIPAM`) in place of the role's host-network listener, and nothing answered on any node's port 80 over IPv4. Argo CD called it Synced and Healthy.
  - **helm-controller didn't notice.** Over the next three minutes, and through a `systemctl restart k3s` on crosby, the HelmChart stayed at generation 1, no helm job ran, and the cluster kept Argo CD's values.
  - **The role's next Cilium change took it back, by reinstalling.** `task k3s -- -e k3s_cilium_version=1.20.5` changed both servers' manifests. helm-controller logged "Suspended Job kube-system/helm-install-cilium for delete", `cilium-config` didn't exist for about 20 s, and then the role's values were back (IPAM `kubernetes`, IPv6 on, ingress answering 200 everywhere). Argo CD went OutOfSync and, being manual, did nothing more.
  - The watch: ingress on each node's IPv4 address failed about 430 of 609 probes, from the sync to the role's run. So the two owners don't fight continuously. Whichever acted last wins until the other acts, and the role wins by uninstalling and reinstalling the CNI. Evidence for D-24.

Not run yet, roughly in the order they matter for Heap:

1. ~~Why ingress on the healthy nodes dropped while greene was down (finding 9).~~ Explained 2026-11-21, above.
2. ~~Backing out of a card.~~ Run 2026-11-21, above (finding 10).
3. The two clusters side by side between Phases 3 and 6. Needs a fourth VM for mercer: with greene gone, the lab's old cluster is broome alone, so flannel between two old nodes beside Cilium is untested.
4. ~~Phase 5 for real, and broome's card against the 7.g gate.~~ Run 2026-11-21, above (finding 13).
5. ~~A test for every refusal in the role and the teardown.~~ `scripts/refusals.sh`, run 2026-11-21, above; rerun whenever the branch changes.
6. ~~A merge that deletes `apps/`. The same with the git server stopped.~~ Run 2026-11-21, above (heap-k8s findings 6 and 7).
7. ~~broome down on the new stage, and broome rebooted with no `nofail` on `/data`.~~ Run 2026-11-21, above (finding 11).
8. ~~The k3s upgrade drill (2), with the role's refusal first.~~ Run 2026-11-21, above. A minor version once one exists.
9. ~~The Cilium upgrade drill (3), plus whether greene and crosby fight over the HelmChart.~~ Run 2026-11-21, above (finding 12).
10. ~~heap-k8s's `platform/cilium` against the role's Cilium.~~ Run 2026-11-21, above (D-24).
11. ~~The OS upgrade drill (5), including whether k3s starts before crosby's fstab bind mount.~~ Run 2026-11-21, above.
12. `task up STAGE=new` in one go (its pieces ran inside the migration).

## Findings for cluster-config

These came out of the runs above. The lab doesn't work around them; they're for the PR.

1. **heap-check.sh can't read crosby's `/etc/cni/net.d`.** Cilium created the directory as 0700 (no podman conflist made it first on crosby), and the check runs `ls` without sudo, so two `joined` checks fail on crosby with "Permission denied". The real crosby probably has the same mode. The checks pass when run with sudo by hand. Fixed on `k3s-ha-cilium` (uncommitted, 2026-11-20): the two checks run `sudo ls`.
2. **The node goes Ready before Cilium exists.** On greene, k3s v1.36 marked the node Ready about 6 s after starting, because containerd accepts podman's `87-podman-bridge.conflist` in `/etc/cni/net.d`. Pods scheduled in that window fail sandbox creation (no `bridge` plugin in `/opt/cni/bin`, here or on Heap) and wait for Cilium, so no pod landed on podman's network. Anything that waits for Ready, such as a check or the role, is waiting for the wrong thing.
3. **crosby's teardown leaves Cilium interfaces only some of the time.** On the first run `cilium_host`, `cilium_net`, the `CILIUM_` chains and the tc programs were all gone after `k3s-teardown.yml`, with no reboot. On the second (2026-11-17, 12:10) `cilium_host`, `cilium_net` and `cilium_vxlan` were still there, as the vault's 2026-11-16 note says. Plan on the 3.3 reboot.
4. **prometheus.prometheus 0.27.0**, pinned in `requirements.yml`, refuses to install on ansible-core above 2.18, and its `_common` role fails on 2.19+'s strict conditionals. Anyone running `configure.yml` from a current laptop hits this. The lab installs it anyway and relaxes conditionals for `base.yml` only.
5. **roles/nfs_server** formats the whole device and then partitions it, so it fails on a blank disk. Harmless on Heap, where sdb already has a partition.
6. **`heap-check clean` fails on crosby after the 3.3 reboot.** fstab line 14 bind-mounts `/home/k3s-containerd` back over `/var/lib/rancher/k3s/agent/containerd` at boot, so "nothing mounted under k3s's directories" lists it. The teardown allowlists that target and the runbook's crosby table expects the mount (P-9), so card step c can't pass on crosby as written. mercer has the same line. The lab's `card.sh` stops there; on 2026-11-17 crosby's card was finished by hand from step d. Fixed on `k3s-ha-cilium` (uncommitted, 2026-11-20): `clean` allows that one target on `HEAP_BIND_MOUNT_NODES`, as the teardown does.
7. **Nothing documents an etcd restore.** Neither the role's README nor the runbook says how to restore from the snapshots `etcd-snapshot-schedule-cron` takes. The lab's drill (below) followed the k3s docs and worked: `k3s etcd-snapshot save`, stop k3s on both servers, `k3s server --cluster-reset --cluster-reset-restore-path=<file>` on greene, start greene, move crosby's `server/db` aside, start crosby. It belongs in `roles/k3s/README.md` before Heap needs it.
8. **`cilium connectivity test` can't pass as the runbook expects (3.7, 7.2).** With the ingress controller on the host network, the test's three `pod-to-ingress-service` tests fail on IPv4 and IPv6 alike, and `check-log-errors` fails on the Envoy NACKs they cause: its dedicated-mode Ingresses carry no `ingress.cilium.io/host-listener-port`, so each tries to bind port 80 beside the shared listener. Either the checks say "passes except those four", or the runbook runs it with `--test '!pod-to-ingress-service,!check-log-errors'` and the ingress is checked by curl as in 4.9.
9. **A server's reboot takes the whole API down for as long as it lasts** (D-2's cost, measured). The drill below took each server down for about three minutes; the other server's API was down the whole time. Running pods kept serving unless their backend was on the stopped node. While greene was down, ingress on the healthy nodes dropped for about 100 s as well, and flapped for 1.5 minutes after it came back. Explained on 2026-11-21 (the run above); both causes apply to Heap:
   - *NFS delegations.* A writer on any node stalls for up to broome's NFSv4 lease (90 s in the lab) when it changes a file that a pod on the dead node had open for reading. That holds whichever node dies, agent or server, and any RWX volume shared across nodes is exposed. Heap's broome runs the same nfsd; its `nfsv4leasetime` hasn't been read. The levers are broome's (R-O2): a shorter lease, or delegations off. Neither has been tried in the lab.
   - *Dead endpoints stay.* When a server goes down, every Service with a pod on it loses one request in N (N backends) for the whole outage, because there's no API to update its endpoints. Envoy's outlier detection can't eject one of two backends, and the Ingress route has no retries. When the dead node is an agent, the API is up and the endpoints should go once the node controller marks it NotReady; that hasn't been run. Whether Cilium's Ingress can set Envoy retries or outlier detection hasn't been looked at.
10. **Nothing takes a node out of the new cluster.** `k3s-teardown.yml` refuses any node with `.managed-by-ansible` ("Refuse to tear down a node of the new cluster"), and no other playbook removes one. The runbook's back-out for Phase 3 is "`k3s-teardown.yml` on crosby again", which that guard stops, and Phase 2's back-out has the same hole. Removing one member of a two-member etcd is also the step most likely to lose the API. Drilled 2026-11-21 (above). Uninstalling a server first loses quorum, and only `--cluster-reset` on the other brings the API back. Deleting the node first removes its etcd member, but a still-running k3s then rejoins by itself within a minute. What worked: `Restart=no` in a drop-in on the leaving server, `kubectl delete node`, then `k3s-uninstall.sh` and a reboot. That's the procedure for a playbook, or for the teardown's new-cluster path. Taking an agent back to the old cluster worked by hand, and the playbook would need to keep the agent's token file.
13. **The teardown's mount check can't see pod volumes.** It runs after `k3s-killall.sh`, which unmounts everything under `/var/lib/kubelet/pods`, NFS included. So broome's teardown with `ray-pv` mounted went straight through (2026-11-21, above), and runbook step b's "If it stops at Still mounted" never happens for a pod's volume. The check still guards the uninstall's `rm -rf`, which matters if an unmount fails. But R-M4 and gate 7.g4 ("no `ray-pv`") are enforced only by whoever reads the gate. Rehearsal step 1.8 passed in its reduced form because a stray tmpfs isn't a pod volume. A check before killall that lists NFS mounts under `/var/lib/kubelet` and refuses, on the old-server path at least, would make the gate real.
11. **broome's reboot hangs for minutes on its own NFS volumes.** A pod on broome with a `heap-nfs` volume mounts it from broome itself. At shutdown systemd stops `nfs-server` before the pod's container scope, so any process in the middle of an NFS call can't be killed. In the lab a reboot took about 280 s instead of a few seconds: SIGKILL ignored for 90 s, then the final sync timing out (run of 2026-11-21 above). On Heap every broome reboot will do this once broome runs any pod with a volume, which runbook 7.3 sets out to arrange. The host team's reboots get slower, and the end of that shutdown is systemd giving up on a sync on the node that holds `/data`. `/data` came back clean in the lab. One possible fix is ordering broome's container shutdown (k3s's `k3s-killall.sh`, or a unit stopping before `nfs-server`) ahead of the NFS server; it hasn't been tried.
12. **The two servers fight over Cilium's version.** Each server's `manifests/cilium.yaml` is a whole copy of the one HelmChart, and k3s applies its own copy whenever it starts or the file changes. A `k3s.yml -l` that reaches one server upgrades the whole cluster at once; the other server's next k3s restart, a host-team reboot included, quietly puts the old version back and rolls every agent again (2026-11-21, above). On Heap a version change has to reach greene and crosby in the same run, and a partial run is a downgrade waiting for a reboot. A preflight that compares the other server's manifest, or a note in the role's README, would catch it. The same goes for any change to `k3s_cilium_values`.

## Findings for heap-k8s

From the first `task argo`, 2026-11-17, against `IanEff/heap-k8s` at 66b7a83. Both stop a fresh bootstrap on Heap too. The lab unblocked them by hand on the live cluster (snapshot `new-argo` has both); the repo is unchanged.

1. **The root app deadlocks on its first sync.** `platform/argocd` is wave -3 and uses project `platform`; `projects/*.yaml` have no wave, so they're wave 0. With the Application health check in `argocd-cm`, root waits for `argocd` to be healthy, and it can't be while its project doesn't exist ("Application referencing project platform which does not exist"). Fix: `argocd.argoproj.io/sync-wave: "-4"` on both AppProjects. The lab applied `projects/` with kubectl.
2. **Every Ingress stays Progressing.** Cilium's ingress on the host network never fills in `status.loadBalancer`, and Argo CD's built-in Ingress health check waits for it. `argocd-server`'s Ingress kept `platform/argocd` Progressing, which blocked root again at wave -3, and any community app with an Ingress would never go Healthy. Fix: a `resource.customizations.health.networking.k8s.io_Ingress` check in `platform/argocd/values.yaml` that returns Healthy. The lab patched that key into the live `argocd-cm`; `platform/argocd` is manual sync, so nothing reverts it.
3. **batchmate.id refuses any login without PKCE, confidential clients included.** Its `AuthorizationRequest` requires `code_challenge` with `S256`, so Argo CD's server-side login came back `invalid_request`. Argo CD 3.6 sends PKCE from the server only with `enablePKCEAuthentication: true` in `oidc.config`. Fixed in heap-k8s; Grafana (`use_pkce`), JupyterHub (`enable_pkce`) and Concourse's Dex will each need the same. kubelogin does it unasked.
4. **Argo CD logs every user's claims.** argocd-server logs the whole id token at info on each API call: email, name, pronouns, picture. On Heap that's the email of every Recurser who logs in, in the pod's logs. Decide whether that's fine or lower the log level.
5. **An unsealed secret stops every later wave.** Without `cloudflare-api-token-secret` the ClusterIssuer is Degraded ("failed to get secret"), so cert-manager is, and root never gets past wave -2. Without `grafana-admin`, monitoring does the same at wave -1. Either way `rbac` and `community-apps` (wave 0) are never applied, so kubectl logins see nothing and no community app syncs. Seen on the lab 2026-11-18. On Heap that makes 4.5's check ("root Synced, Healthy") wait for 4.7 and 4.11a, and both secrets have to be sealed before bootstrap or right after it. Moving `rbac` to an earlier wave would at least decouple logins.
6. **No app under `apps/` can deploy.** The ApplicationSet syncs with `CreateNamespace=true` and `managedNamespaceMetadata`, which makes the Namespace one of the app's resources, and `projects/community.yaml` has `clusterResourceWhitelist: []`. Every community app fails with "resource :Namespace is not permitted in project community" (2026-11-21, test 6). It's the same in Heap's repo at `ff8b62f`. Allowing `{group: "", kind: Namespace}` in the community project fixed it in the lab; whether that also lets an app create namespaces outside `app-*` hasn't been checked. Runbook 4.14 has never passed.
7. **`_template`'s pod can't write to a `heap-nfs` volume.** csi-driver-nfs makes each volume's directory `root:root 0755`, and the template's image runs as uid 101. Adding `securityContext: {fsGroup: 101}` to the pod spec fixed it in the lab (kubelet set the group and the setgid bit). Every non-root app with a volume needs the same, which matters for Phase 5's non-root check and for JupyterHub's user pods. The template should carry an `fsGroup`, or the StorageClass should set `mountPermissions`; only the first was tried.

## Findings for batchmate.id

From the same run; for Chandler, not for a PR.

1. ~~**No CORS on `/oauth/token`.**~~ Fixed upstream in `dffe196` (2026-11-19): CORS from any origin on every endpoint. Not retested in the lab.
2. **The RC id arrived as flat claims, not `federated_claims`** (`4f99af9`, 2026-11-17). `idp_issuer` and `idp_subject` come with the `profile` scope. The k3s role now reads them (2026-11-20 run above). Argo CD takes its subject only from `federated_claims.user_id`, so its subject stays `sub_…`; heap-k8s lists `idp_subject` in the rbac `scopes` so `g` lines can name RC ids instead.
3. **The identity-provider slug is `www.recurse.com`.** The gateway's upstream callback is `https://batchmate.id/oauth/broker/www.recurse.com/callback`.

## Known issues

- **A VM sometimes booted with no sshd, and `limactl start` waited its full 10 minutes: fixed 2026-11-21.** Seen three times that day. The cause was the lab's own `heap-lab-ndp.service`: with systemd's default dependencies it ran after `basic.target`, and its `Before=network-pre.target` closed a loop through networkd, `systemd-networkd-wait-online`, cloud-init and `sockets.target`. systemd breaks such a loop by deleting a job, and on the hung boots the job was `ssh.socket` (the journal of a hung boot on greene names the whole chain). The unit now has `DefaultDependencies=no`, as Debian's `nftables.service` does; the three instances got the new `provision` with `limactl edit --set`, and their next boots had no ordering cycles and IPv6 still worked. Every snapshot taken before the fix still has the old unit, so the first boot after restoring one can still hang until the provision step rewrites it. If it does, `limactl stop -f` the VM and start it again. Re-taking `old-fresh` and `new-dualstack` once would end it; that replaces the baselines, so it's Ian's call.

- **Fix for the egress outages below:** stop all three VMs so `limactl usernet` exits, then start them (`task snap` does both). On 2026-11-17 the outage ran past 25 minutes and took guest-to-Mac traffic down with it; a restart of usernet cleared it at once. Its outbound connections were leaving from ProtonVPN's tunnel address (10.2.0.2).

- **Egress through Lima's user-v2 NAT drops for minutes at a time.** Three windows on 2026-11-17, two of them starting right after a snapshot restarted the VMs; the longest ran about ten minutes. `get.k3s.io` and docker.io timed out from every node at once (18 of 20 tries failing), while the Mac reached both 60 of 60 times. A k3s.yml run inside the window fails at the installer download; rerun it. `up` and `snap` now wait until every node gets three answers in a row before handing back. The cause isn't known; the Mac had Tailscale and ProtonVPN up. A pull-through cache on the Mac (galley's) would take the image pulls off this path, and is the next thing to add.
- **pod CIDR traffic to the gateway: fixed 2026-11-20, and probably the egress outages' cause.** While a node has no Cilium (crosby between its join and its agent starting), its API server's calls to pod IPs on other nodes go to the default gateway, and Lima's NAT opens each one as a TCP connection from the Mac, where it hangs. On 2026-11-20 crosby had 125 SYNs pending to `10.44.0.78:10250` on greene, and every VM's TCP egress was dead while ICMP still worked. ProtonVPN was off for the second time. crosby couldn't pull Cilium, which would have added the route, so it never recovered. Not proven to be the 2026-11-17 windows, but those came right after restarts, when nodes are up before Cilium. Each VM now has `unreachable` routes for the new cluster's pod and service ranges (`LAB_UNREACHABLE_*` in `config/heap-lab.env`), so those packets fail at once, as they would at Heap's router. Cilium's per-node routes are more specific and win once it's up.

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

### 6. Phase 4 against the config repo

```bash
task restore NAME=new-oidc         # or any new-stage snapshot
task argo                          # 4.4, 4.5: publish heap-k8s/, bootstrap or refresh
task argo-status                   # root and every platform app Synced, Healthy
task argo-ui                       # 4.12: sync argocd by hand; then task oidc puts your admin line back
cp -R heap-k8s/apps/_template heap-k8s/apps/hello && task argo   # 4.14: app-hello appears
rm -rf heap-k8s/apps/hello && task argo                          # app-hello and its namespace go
task argo-drift                    # before trusting any of it: is heap-k8s/ still upstream?
```

`task argo` publishes the working tree, so an edit under `heap-k8s/` and a `task argo` is the lab's merge, and `git restore heap-k8s` (`git clean` for new files) with another `task argo` is the revert. 4.6 (the sealed-secrets key backup), 4.8 and the Phase 5 loop (5.a to 5.f, with the stand-ins under `manifests/old/` as the apps to move) run the same way. `task argo SOURCE=upstream` is the check that Heap's repo, as committed, would go green; until findings 1, 2 and 5 are fixed there, it won't.

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
| `task argo [SOURCE=lab\|upstream]` / `task argo-status` / `task argo-ui` | Phase 4: publish `heap-k8s/` (or all of `HEAP_K8S`) from broome, then bootstrap Argo CD or refresh it; list Applications; the UI on localhost:8080 |
| `task argo-drift` | `heap-k8s/` against `HEAP_K8S`: upstream commits since the mirror (fails if any), the diff, what's left out |
| `task oidc` / `task whoami` / `task whoami-device` | batchmate.id logins: check the API servers, write `.state/kube/login.yaml`, configure Argo CD, apply `LAB_OIDC_ADMINS`; `kubectl auth whoami` as yourself, with a browser or through the device flow |
| `task watch` | Disruption probe until Ctrl-C, then outages per target |
| `task canary [CLUSTER=new\|old\|delete-new\|delete-old]` | The probe's target app |
| `task data-check` / `task data-record` | `/data` unchanged since the baseline |
| `task ssh [NODE=]` / `task kubeconfig` / `task timeline` | Shell; re-fetch kubeconfigs and ssh config; seconds per build phase |

## How it works

**Testing a checkout.** `HEAP_REPO` in `config/heap-lab.env` names the cluster-config working tree. `scripts/play.sh` runs a playbook from it with the lab's `ansible.cfg` and inventory and its `roles/` on the path, and logs each run to `.state/runs/` with the branch and commit it ran. To rehearse a branch, check it out there, or point `HEAP_REPO` at a second worktree in `.env`.

**Inventory.** Hosts are `greene.heap-lab`, `crosby.heap-lab` and `broome.heap-lab`, so `inventory_hostname_short` is the Heap node name and k3s's node names match Heap's. The domain resolves only through `.state/ssh_config`, which `scripts/ssh_config.sh` writes from Lima's own per-instance ssh config. Ansible, `heap-check.sh` and the scripts all pass it with `-F`. The groups match cluster-config's `inventory/hosts`, plus `old_server`, `old_agents` and `experiment` for the old stage.

**Network.** Lima's `user-v2` network gives each VM one NIC on 192.168.104.0/24, with the VMs as L2 neighbours. The provision step in `lima/node.yaml` adds a fixed address that netplan brings up before DHCP, so it becomes eth0's primary, and points the default route at it. Changing the DHCP address instead hangs `limactl shell`: Lima's ssh is forwarded to that address. Tested 2026-11-17: the fixed address survives a restart, reaches the internet and the other VMs, and Lima's ssh keeps working.

The same netplan file puts each node's IPv6 address on eth0 (`LAB_IPV6_<NODE>`, a /64, no gateway). user-v2 is gvisor-tap-vsock's switch, whose `txPkt` floods broadcast, forwards unicast to MACs it has learned and drops everything else. IPv6 multicast goes in the last bucket, so out of the box the VMs had only `fe80::` addresses and couldn't ping each other on them. ARP is broadcast, which is why IPv4 never noticed. The provision step also installs `heap-lab-ndp.service`, which loads `/etc/heap-lab/ndp.nft`: an egress rule on eth0 that rewrites destination MACs `33:33:*` to `ff:ff:ff:ff:ff:ff`. After that neighbour discovery and DAD are real (a duplicate address comes up `dadfailed`), and nothing needs to know another node's MAC. Pinning neighbours statically was the first try and is a dead end: under vz, Lima gives the first user-v2 NIC `sha256(machine id + instance dir)` and ignores `macAddress`. The provision step runs on every boot and applies only what changed, so a `lima.yaml` edited with `limactl edit` takes effect at the next start.

**APIs.** Each VM forwards its 6443 to the Mac: greene 16443, crosby 16444, broome 16445. `scripts/kubeconfig.sh` fetches whichever admin kubeconfigs exist into `.state/kube/` and drops ones whose node no longer runs a server.

**Snapshots.** `limactl snapshot` is QEMU-only, and the lab runs on vz. `scripts/snap.sh` stops all three VMs (a clean shutdown, so etcd and sqlite are consistent), clones each VM's root `disk` (`diffdisk` on Lima before 2.2) and `vz-efi`, and broome's data disk with `cp -c` (APFS clonefile: instant, and blocks only take space once they diverge), and starts them again. Restore reverses it. `.state/`'s stage, kubeconfigs and /data baseline go with the snapshot.

**The watch.** `scripts/watch.sh` probes each API server's `/readyz` from the Mac through its forward (any HTTP answer counts as up) and, from a shell on broome, each Ingress host on every node's port 80 (`scripts/guest/probe.sh`), on its IPv6 address too (`<host>@<node>-v6`) for each node whose ingress answers there when the watch starts. The canary's writer stamps the time into an NFS volume every second, and its web pods serve the stamp, so one probe covers ingress, the pod network, Services and NFS: an answer more than 5 s old is reported as stale. Rows go to `.state/watch/<time>.csv`; Ctrl-C prints each target's outages as offsets from the start.

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
heap-k8s/                the lab's copy of the config repo, what task argo publishes (its README has the deltas)
scripts/                 up, down, destroy, snap, play, card, check, watch, data, ...
scripts/guest/probe.sh   the watch's broome side, fed over ssh
bin/                     new, old, crosby: kubectl per cluster
.state/                  ssh_config, kube/ (admin kubeconfigs, login.yaml, oidc-cache/), runs/, watch/, timeline.csv,
                         heap-k8s*/ (what argo.sh last published; argo-drift's upstream clone) (gitignored)
.snapshots/              whole-lab snapshots (gitignored; destroy removes them)
.cache/collections/      cluster-config's Ansible collections (gitignored; kept)
```

## Host changes

None outside the repo and Lima's own directories: the three instances and the `heap-broome-data` disk under `~/.lima`. `~/.ssh/config` and `~/.kube/config` aren't touched. It needs about 12 GiB of free memory for the default sizes; on a 32 GiB laptop that leaves room for everything else.
