#!/usr/bin/env bash
# Renders the repo and checks every object against the Kubernetes 1.36 schemas,
# and CRD schemas from the datree catalog. Runs in CI; locally:
#
#   scripts/validate.sh
#
# Needs helm, kustomize, yq and kubeconform.
set -euo pipefail

KUBE_VERSION=${KUBE_VERSION:-1.36.0}
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
cd "$(dirname "$0")/.."

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
KUBE_VERSION=$KUBE_VERSION scripts/render.sh "$out"

status=0
for f in "$out"/argocd/*.yaml "$out"/apps/*.yaml; do
  echo "== ${f#"$out"/}"
  kubeconform -strict -summary -kubernetes-version "${KUBE_VERSION}" \
    -schema-location default -schema-location "$CRD_SCHEMAS" "$f" || status=1
done
# Charts install CRDs that the catalog may not know yet, so platform renders
# skip objects with no schema instead of failing on them.
for f in "$out"/platform/*.yaml; do
  echo "== ${f#"$out"/}"
  kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version "${KUBE_VERSION}" \
    -schema-location default -schema-location "$CRD_SCHEMAS" "$f" || status=1
done
exit $status
