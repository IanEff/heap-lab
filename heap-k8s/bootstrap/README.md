# bootstrap

For building the cluster from nothing. In normal use nobody touches this directory.

| File | What it is |
|---|---|
| `bootstrap.sh` | Installs Argo CD with Helm, then applies `root.yaml`. Run once per cluster. |
| `root.yaml` | The app-of-apps. It deploys `projects/*.yaml`, every `platform/*/application.yaml` and `community-apps.yaml`. |
| `community-apps.yaml` | The ApplicationSet that turns each `apps/<dir>` into an Application. |

## From an empty cluster

k3s and Cilium come first, from `ansible-playbook k3s.yml` in cluster-config. Then:

```sh
KUBECONFIG=~/.kube/heap.yaml bootstrap/bootstrap.sh
```

The script refuses to run unless the kubeconfig points at `https://k8s.cluster.recurse.com:6443`; set `EXPECTED_SERVER` if the API is somewhere else. It installs the same chart and values that `platform/argocd` pins, so Argo CD adopts its own release on the first sync.

After that, restore the sealed-secrets controller key from its backup before sealed-secrets first syncs. Without it, every SealedSecret in the repo is unreadable and has to be sealed again.

## Why the root app has no finalizer

With `resources-finalizer.argocd.argoproj.io`, deleting `root` would delete every platform component and every community app. Without it, deleting `root` deletes nothing.
