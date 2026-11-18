#!/usr/bin/env bash
# Installs Argo CD on a fresh Heap cluster and applies the root app. Run it once,
# after `ansible-playbook k3s.yml` in cluster-config has brought up k3s and
# Cilium. Safe to re-run: it never upgrades Argo CD, because after the first run
# Argo CD's own Application (platform/argocd) owns it.
#
#   KUBECONFIG=~/.kube/heap.yaml bootstrap/bootstrap.sh
#
# Needs kubectl, helm and yq.
set -euo pipefail

: "${KUBECONFIG:?point KUBECONFIG at the new Heap cluster}"

EXPECTED_SERVER=${EXPECTED_SERVER:-https://k8s.cluster.recurse.com:6443}
cd "$(dirname "$0")/.."

# Refuse to install into whatever cluster the shell happens to point at.
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
if [ "$server" != "$EXPECTED_SERVER" ]; then
  echo "Refusing to run: KUBECONFIG points at $server, expected $EXPECTED_SERVER." >&2
  echo "Set EXPECTED_SERVER if the API really is somewhere else." >&2
  exit 1
fi

app=platform/argocd/application.yaml
if kubectl -n argocd get deployment argocd-server >/dev/null 2>&1; then
  echo "Argo CD is already installed; leaving it alone."
else
  helm upgrade --install \
    "$(yq '.spec.sources[0].helm.releaseName' "$app")" \
    "$(yq '.spec.sources[0].chart' "$app")" \
    --repo "$(yq '.spec.sources[0].repoURL' "$app")" \
    --version "$(yq '.spec.sources[0].targetRevision' "$app")" \
    --namespace argocd --create-namespace \
    --values platform/argocd/values.yaml \
    --wait --timeout 10m
fi

kubectl apply -f bootstrap/root.yaml

echo
echo "Done. Argo CD now syncs everything else from main."
echo "Initial admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
