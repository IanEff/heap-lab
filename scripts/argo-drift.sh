#!/usr/bin/env bash
# heap-lab: argo-drift.sh
# How far heap-k8s/ has drifted from HEAP_K8S. Needs no VMs.
#   1. Upstream commits since HEAP_K8S_MIRRORED that touch a mirrored
#      directory. Any at all and it exits 1: copy them into heap-k8s/ and move
#      HEAP_K8S_MIRRORED in config/heap-lab.env.
#   2. The diff between upstream's mirrored directories, with Heap's values
#      turned into the lab's placeholders, and heap-k8s/. Every hunk should be
#      one of the deltas marked "heap-lab:".
#   3. What upstream has that the lab leaves out.
set -euo pipefail
_TAG=argo-drift
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB="${LAB_ROOT}/heap-k8s"
UP="${STATE_DIR}/heap-k8s-upstream"
rm -rf "$UP"
git clone -q --branch "$HEAP_K8S_REF" --single-branch "$HEAP_K8S" "$UP"
HEAD_SHA=$(git -C "$UP" rev-parse --short HEAD)

# Mirrored: every top-level directory of heap-k8s/, and platform/ one level down.
MIRRORED=()
for d in "$LAB"/*/; do
    d=$(basename "$d")
    if [ "$d" = platform ]; then
        for p in "$LAB"/platform/*/; do MIRRORED+=("platform/$(basename "$p")"); done
    else
        MIRRORED+=("$d")
    fi
done

step "Upstream commits since ${HEAP_K8S_MIRRORED} in mirrored directories (${HEAP_K8S} ${HEAP_K8S_REF} is at ${HEAD_SHA})"
NEW=$(git -C "$UP" log --oneline "${HEAP_K8S_MIRRORED}..HEAD" -- "${MIRRORED[@]}")
if [ -n "$NEW" ]; then echo "$NEW"; else info "None."; fi

step "upstream (placeholders) -> heap-k8s/"
rm -rf "${UP}/.git"
heap_k8s_placeholders "$UP"
for d in "${MIRRORED[@]}"; do
    diff -ru "${UP}/${d}" "${LAB}/${d}" | sed -e "s#${UP}/#upstream/#" -e "s#${LAB}/#heap-k8s/#" || true
done

step "In upstream, not in the lab"
for d in "$UP"/*/ "$UP"/platform/*/; do
    rel=${d#"$UP"/}; rel=${rel%/}
    [ "$rel" = platform ] && continue
    [ -e "${LAB}/${rel}" ] || echo "  ${rel}"
done

[ -z "$NEW" ] || error "heap-k8s/ is behind ${HEAP_K8S}: re-mirror the commits above."
