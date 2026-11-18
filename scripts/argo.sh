#!/usr/bin/env bash
# heap-lab: argo.sh [lab|upstream]
# Phase 4 in the lab: Argo CD and everything it owns, from a config repo served
# by broome (scripts/guest/git-http.py, the lab's own instrument). Run against
# the new cluster. Safe to re-run: the first run installs Argo CD with the
# repo's own bootstrap/bootstrap.sh; later runs publish a new commit and ask
# Argo CD to refresh.
#
# Two sources (LAB_ARGO_SOURCE, or the first argument):
#   lab       heap-k8s/ in this repo, as it stands in the working tree: the
#             subset of HEAP_K8S the lab can bring to Healthy, with four
#             marked deltas (heap-k8s/README.md). The default.
#   upstream  all of HEAP_K8S at HEAP_K8S_REF, with only its Heap values
#             swapped. What Heap will get; on the lab it stops at the findings
#             the lab subset works around.
# Either way, nothing Argo CD applies may still name Heap.
set -euo pipefail
_TAG=argo
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export KUBECONFIG="${KUBE_DIR}/new.yaml"
[ -f "$KUBECONFIG" ] || error "No new cluster yet (.state/kube/new.yaml)."
command -v yq >/dev/null || error "yq not found (heap-k8s's bootstrap.sh needs it): brew install yq"

SOURCE="${1:-${LAB_ARGO_SOURCE}}"
TREE="${STATE_DIR}/heap-k8s-tree"   # what gets published, rendered
WORK="${STATE_DIR}/heap-k8s"        # a clone of what broome serves
BARE=/srv/heap-lab-git/heap-k8s.git
GUEST_USER=$(on broome 'id -un')
[ -n "${LAB_OIDC_ARGOCD_CLIENT_ID:-}" ] \
    || warn "LAB_OIDC_ARGOCD_CLIENT_ID isn't set in .env; Argo CD's Recurse login won't work (admin still does)."

# ── broome: /data/k8s (G-6, the host team's on Heap) and the git server ─────
step "/data/k8s on broome (G-6)"
on broome 'sudo install -d -m 0755 -o root -g root /data/k8s'

step "Lab git server on broome:${LAB_GIT_PORT}"
on broome "sudo install -d -o ${GUEST_USER} -g ${GUEST_USER} /srv/heap-lab-git && \
    { [ -d ${BARE} ] || git init -q --bare -b main ${BARE}; }"
on broome 'sudo tee /usr/local/sbin/heap-lab-git-http >/dev/null && sudo chmod 0755 /usr/local/sbin/heap-lab-git-http' \
    < "${LAB_ROOT}/scripts/guest/git-http.py"
on broome "sudo tee /etc/systemd/system/heap-lab-git.service >/dev/null" <<EOF
# heap-lab instrument, not Heap: serves the lab's copy of heap-k8s to Argo CD.
[Unit]
Description=heap-lab git server for Argo CD
After=network-online.target

[Service]
User=${GUEST_USER}
ExecStart=/usr/local/sbin/heap-lab-git-http ${LAB_GIT_PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
on broome 'sudo systemctl daemon-reload && sudo systemctl enable -q heap-lab-git && sudo systemctl restart heap-lab-git'

# ── The tree to publish ─────────────────────────────────────────────────────
rm -rf "$TREE"
case "$SOURCE" in
    lab)
        step "heap-k8s/ (mirrors ${HEAP_K8S_MIRRORED}; working tree, uncommitted changes included)"
        cp -R "${LAB_ROOT}/heap-k8s" "$TREE"
        MSG="heap-lab: heap-k8s/ at heap-lab $(git -C "$LAB_ROOT" describe --always --dirty), mirroring ${HEAP_K8S_MIRRORED}"
        ;;
    upstream)
        step "${HEAP_K8S} ${HEAP_K8S_REF}, all of it"
        git clone -q --depth 1 --branch "$HEAP_K8S_REF" --single-branch "$HEAP_K8S" "$TREE"
        MSG="heap-lab: ${HEAP_K8S}@$(git -C "$TREE" rev-parse --short HEAD) with lab values"
        rm -rf "${TREE}/.git"
        heap_k8s_placeholders "$TREE"
        ;;
    *) error "Source is lab or upstream, not '${SOURCE}'." ;;
esac
heap_k8s_render "$TREE"

# Invariant 7: nothing Argo CD applies may name Heap. Comments don't count.
LEFT=$(_heap_k8s_yaml "$TREE" | xargs grep -nE 'cluster\.recurse\.com|23\.136\.216\.|github\.com/recursecenter/heap-k8s' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
[ -z "$LEFT" ] || { echo "$LEFT" >&2; error "Heap addresses left after the lab's swaps. Add the new one to heap_k8s_placeholders (scripts/lib.sh)."; }

# ── Publish: one commit on top of what broome already serves ────────────────
# A fast-forward, so Argo CD sees a history and a git revert in heap-lab
# arrives as one more commit, the way a revert merges on Heap.
step "Publishing to ${LAB_GIT_URL}"
export GIT_SSH_COMMAND="ssh -F ${SSH_CONFIG}"
rm -rf "$WORK"
if on broome "git -C ${BARE} rev-parse -q --verify refs/heads/main" >/dev/null; then
    git clone -q "$(fqdn broome):${BARE}" "$WORK"
else
    git init -q -b main "$WORK"
fi
rsync -a --delete --exclude .git "${TREE}/" "${WORK}/"
git -C "$WORK" add -A
if git -C "$WORK" diff --cached --quiet; then
    info "No change since $(git -C "$WORK" rev-parse --short HEAD)."
else
    git -C "$WORK" -c user.name=heap-lab -c user.email=heap-lab@heap-lab.invalid commit -qm "$MSG"
    git -C "$WORK" push -q "$(fqdn broome):${BARE}" HEAD:refs/heads/main
    info "Serving $(git -C "$WORK" rev-parse --short HEAD): ${MSG}"
fi

# ── Argo CD ─────────────────────────────────────────────────────────────────
if new_kubectl -n argocd get application root >/dev/null 2>&1; then
    step "Asking Argo CD to refresh"
    new_kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null
else
    # The repo's own script, unchanged. Its guard wants the API's URL; the lab's
    # guard is that KUBECONFIG is .state/kube/new.yaml.
    step "bootstrap/bootstrap.sh"
    EXPECTED_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') \
        bash "${TREE}/bootstrap/bootstrap.sh"
fi

# platform/argocd syncs by hand (runbook 4.12), so it's left out of the wait.
step "Applications (Argo CD keeps going after this; task argo-status to look again)"
for i in $(seq 1 60); do
    rows=$(new_kubectl -n argocd get applications --no-headers 2>/dev/null | grep -v '^argocd ' || true)
    apps=$(printf '%s\n' "$rows" | grep -c . || true)
    pending=$(printf '%s\n' "$rows" | grep . | grep -cvE 'Synced +Healthy' || true)
    [ "$apps" -gt 1 ] && [ "$pending" -eq 0 ] && break
    sleep 10
done
new_kubectl -n argocd get applications
[ "$pending" -eq 0 ] || warn "${pending} Application(s) not Synced and Healthy after 10 minutes."
