# apps

The playground. Each directory here becomes one Argo CD Application, `app-<dir>`, deployed into namespace `app-<dir>` by the ApplicationSet in `bootstrap/community-apps.yaml`. `_template` is skipped.

Argo CD builds each directory with Kustomize, so it needs a `kustomization.yaml` listing your files. Plain manifests and Helm charts through Kustomize's `helmCharts` both work.

## What your namespace starts with

`_template` ships four defaults. Change them in your PR if your app needs something else.

| File | Default |
|---|---|
| `owners.yaml` | Nobody. Add yourself, by the username `kubectl auth whoami` prints, to get kubectl `edit` in your namespace: exec, port-forward, deleting pods, reading Secrets. Everyone can already look at everything but Secrets ([../docs/kubectl.md](../docs/kubectl.md)). |
| `resourcequota.yaml` | 4 CPU and 16Gi of memory requested, 1 GPU, 5 volumes, 50Gi of storage |
| `limitrange.yaml` | Containers without requests get 100m CPU and 128Mi; without limits, 1 CPU and 1Gi |
| `networkpolicy.yaml` | Pods accept traffic from their own namespace, from Cilium's ingress and from Prometheus. Outbound is open. |

Namespaces carry `pod-security.kubernetes.io/warn: restricted`. Nothing gets refused; `kubectl apply` and Argo CD print a warning for pods that `restricted` would reject.

## Volumes

Ask for a PersistentVolumeClaim and you get a directory on broome's `/data/k8s/<namespace>/<pvc>`, through the default StorageClass `heap-nfs`. Deleting the claim archives the directory instead of deleting it.

Use a PVC. Mounting `nfs:` or `hostPath:` volumes directly reaches parts of broome's disk that hold other people's data.

SQLite over NFS has locking problems. If your app keeps a database, run Postgres.

## GPUs

crosby, greene and mercer have NVIDIA GPUs and carry the label `gpu=true`. Request one with `resources.limits."nvidia.com/gpu": 1`. Your quota allows one; ask in the #heap community cluster stream on Zulip for more.

## Publishing over HTTPS

Uncomment `ingress.yaml` in your `kustomization.yaml` and set the host. cert-manager gets the certificate.

Until the migration finishes, `*.recurse.cloud` still points at the old cluster, so ask in the #heap community cluster stream for an A record for your hostname first. NodePort and LoadBalancer Services aren't for community apps yet.

## Secrets

Never commit a plain Secret. Seal it:

```sh
kubectl -n app-<name> create secret generic <secret> --from-literal=key=value \
  --dry-run=client -o yaml | kubeseal -o yaml > apps/<name>/<secret>.sealed.yaml
```

Only the cluster can decrypt the result, so it's safe to commit.

## Removing an app

Delete the directory. Argo CD deletes the Application and everything in it; volumes are archived on broome. `git revert` brings it back.

## When a sync fails with "not permitted in project"

Your app tried to create something cluster-scoped: a CRD, a ClusterRole, a webhook. Those belong in `platform/`.
