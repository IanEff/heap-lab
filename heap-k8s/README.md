# heap-k8s, lab copy

The part of [recursecenter/heap-k8s](https://github.com/recursecenter/heap-k8s) the lab can bring to Synced and Healthy, copied from the commit in `HEAP_K8S_MIRRORED` (`config/heap-lab.env`), with Heap's values written as placeholders and four deltas marked `heap-lab:`. `task argo` fills in the placeholders, publishes the tree from broome and lets Argo CD sync it. Everything else here is upstream's bytes.

It's a mirror, and mirrors drift. `task argo-drift` diffs this directory against upstream and fails when upstream has commits in a mirrored directory that this copy doesn't. Re-mirror then: copy the change in, keep the deltas, move `HEAP_K8S_MIRRORED`.

Read **The deltas** before trusting a green sync here. Each one is a place where Heap's repo, as committed, would not go green.

## What's mirrored

| Path | From upstream | Runbook |
|---|---|---|
| `bootstrap/` | All three files and the README; `bootstrap.sh` byte for byte | 4.4, 4.5 |
| `projects/` | Both AppProjects, plus delta 1 | 4.5 |
| `platform/argocd` | Chart, values, OIDC login; plus deltas 2 and 3 | 4.12, 4.13 |
| `platform/sealed-secrets` | Unchanged | 4.6 |
| `platform/cert-manager` | Chart and values unchanged; the ClusterIssuer is delta 4 | 4.7 |
| `platform/csi-driver-nfs` | Unchanged; `heap-nfs` points at the lab's broome | 4.8 |
| `platform/rbac` | Unchanged | kubectl logins |
| `apps/` | `_template` and the README; no apps | 4.14, Phase 5 |
| `scripts/` | `render.sh` and `validate.sh`, unchanged | 4.3 |

Left out, and why:

| Upstream | Why not here |
|---|---|
| `platform/monitoring` | Grafana waits for the sealed `grafana-admin` Secret, so the Application stays Degraded and root never reaches wave 0. kube-prometheus-stack also wants more memory than 4 GiB VMs have spare (greene sat at 80% with it on 2026-11-18). |
| `platform/nvidia-device-plugin` | No GPUs in the lab. |
| `platform/kuberay-operator` | Nothing in the lab runs Ray on the new cluster yet. Copy it in for a Phase 5 Ray drill; it syncs as is. |
| `docs/`, `.github/`, the top-level README | Not anything Argo CD applies. |

`root.yaml` includes `platform/*/application.yaml`, so deleting a directory here is all it takes to leave a component out, and copying one back from upstream is all it takes to add it.

## Placeholders

| Placeholder | Heap's value | Lab's value, from |
|---|---|---|
| `${LAB_GIT_URL}` | `https://github.com/recursecenter/heap-k8s.git` | broome's git server, `LAB_IP_BROOME` and `LAB_GIT_PORT` |
| `${LAB_IP_BROOME}` | `23.136.216.133`, `heap-nfs`'s server | `LAB_IP_BROOME` |
| `${LAB_OIDC_ARGOCD_CLIENT_ID}` | Heap's `svc_` client | `.env` |

`heap_k8s_placeholders` and `heap_k8s_render` in `scripts/lib.sh` do the two directions. Only YAML is rewritten, so `bootstrap.sh` keeps Heap's `EXPECTED_SERVER` default and `task argo` passes the lab's API instead.

## The deltas

1. **Both AppProjects carry `sync-wave: "-4"`.** heap-k8s finding 1 in the lab's README: with no wave they're wave 0, and root deadlocks waiting for `platform/argocd` (wave -3), whose project doesn't exist yet.
2. **An Ingress health check in `platform/argocd/values.yaml` that always says Healthy.** Finding 2: Cilium's host-network ingress never fills `status.loadBalancer`, so every Ingress stays Progressing, `argocd-server`'s included, and root stops at wave -3.
3. **`url: http://localhost:8080`** in the same file. That's `task argo-ui`'s port-forward, and the lab's batchmate.id client redirects there. Heap's is `https://argocd.recurse.cloud`.
4. **The ClusterIssuer `letsencrypt-prod` is self-signed.** Heap's needs the sealed Cloudflare token. Without it the issuer is Degraded, cert-manager with it, and root stops at wave -2 (seen on the lab 2026-11-18). The lab has no token and shouldn't register an ACME account per rebuild. Every Ingress that asks for `letsencrypt-prod` gets a self-signed certificate.

Deltas 1 and 2 are fixes heap-k8s still needs. Drop them from here once upstream has them, and `task argo-drift` will show the diff shrink. Deltas 3 and 4 are the lab's for good.

## Running it

```bash
task argo                  # publish heap-k8s/, bootstrap Argo CD or refresh it
task argo-status
task argo-ui               # http://localhost:8080
task argo-drift            # this directory against upstream
task argo SOURCE=upstream  # all of upstream instead; stops at the deltas above
```

`task argo` publishes the working tree, uncommitted edits included, as one commit on top of what broome already serves. Publishing is the lab's merge: edit here, `task argo`, watch Argo CD pick it up. `git restore heap-k8s` (`git clean` for new files) and another `task argo` is the revert.
