#!/usr/bin/env bash
# Renders everything Argo CD would apply into one YAML file per Application, so
# CI can validate it and diff it against main. Usage:
#
#   scripts/render.sh <out-dir>
#
# Needs helm, kustomize and yq.
set -euo pipefail

out=${1:?usage: scripts/render.sh <out-dir>}
KUBE_VERSION=${KUBE_VERSION:-1.36.0}
cd "$(dirname "$0")/.."
mkdir -p "$out/platform" "$out/apps" "$out/argocd"

# The Argo CD objects themselves.
for f in bootstrap/root.yaml bootstrap/community-apps.yaml projects/*.yaml platform/*/application.yaml; do
  printf -- '---\n'
  cat "$f"
done > "$out/argocd/argocd.yaml"

for app in platform/*/application.yaml; do
  dir=$(dirname "$app")
  name=$(basename "$dir")
  dest="$out/platform/$name.yaml"
  : > "$dest"

  # A chart, when there is one, is sources[0]; sources with a path are plain
  # manifests from this repo. platform/rbac has no chart at all.
  values=$(yq '.spec.sources[0].helm.valueFiles[0] // ""' "$app" | sed 's|^\$values/||')
  [ "$(yq '.spec.sources[0].chart // ""' "$app")" = "" ] || helm template \
    "$(yq '.spec.sources[0].helm.releaseName' "$app")" \
    "$(yq '.spec.sources[0].chart' "$app")" \
    --repo "$(yq '.spec.sources[0].repoURL' "$app")" \
    --version "$(yq '.spec.sources[0].targetRevision' "$app")" \
    --namespace "$(yq '.spec.destination.namespace' "$app")" \
    --kube-version "$KUBE_VERSION" \
    --include-crds \
    ${values:+--values "$values"} \
    >> "$dest"

  for path in $(yq '.spec.sources[] | select(.path != null) | .path' "$app"); do
    for f in "$path"/*.yaml; do
      [ -e "$f" ] || continue
      printf -- '---\n' >> "$dest"
      cat "$f" >> "$dest"
    done
  done
done

for dir in apps/*/; do
  name=$(basename "$dir")
  kustomize build "$dir" > "$out/apps/$name.yaml"
done
