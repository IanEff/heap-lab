#!/usr/bin/env bash
# heap-lab: argo.sh
# Phase 4 in the lab: Argo CD and everything it owns, from the config repo
# (HEAP_K8S at HEAP_K8S_REF). Run against the new cluster. Safe to re-run: the
# first run installs Argo CD with heap-k8s's own bootstrap/bootstrap.sh; later
# runs push the repo's latest commit and ask Argo CD to refresh.
#
# heap-k8s is written for Heap, so the lab can't sync it as it stands. The lab
# clones it, swaps in lab values, commits that on top, and serves the result
# from broome (scripts/guest/git-http.py, the lab's own instrument). The swaps
# are values only, the same kind the inventory makes for cluster-config:
#   1. https://github.com/recursecenter/heap-k8s.git -> broome's git server
#   2. heap-nfs's NFS server, Heap's broome -> the lab's broome
#   3. Prometheus's node targets, <node>.cluster.recurse.com -> lab addresses
#      (mercer's dropped: the lab has no mercer)
# If a Heap address is still in anything Argo CD applies afterwards, it stops.
set -euo pipefail
_TAG=argo
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export KUBECONFIG="${KUBE_DIR}/new.yaml"
[ -f "$KUBECONFIG" ] || error "No new cluster yet (.state/kube/new.yaml)."
command -v yq >/dev/null || error "yq not found (heap-k8s's bootstrap.sh needs it): brew install yq"

UPSTREAM_URL="https://github.com/recursecenter/heap-k8s.git"
LAB_URL="http://${LAB_IP_BROOME}:${LAB_GIT_PORT}/heap-k8s.git"
SRC="${STATE_DIR}/heap-k8s"
GUEST_USER=$(on broome 'id -un')

# ── broome: /data/k8s (G-6, the host team's on Heap) and the git server ─────
step "/data/k8s on broome (G-6)"
on broome 'sudo install -d -m 0755 -o root -g root /data/k8s'

step "Lab git server on broome:${LAB_GIT_PORT}"
on broome "sudo install -d -o ${GUEST_USER} -g ${GUEST_USER} /srv/heap-lab-git && \
    { [ -d /srv/heap-lab-git/heap-k8s.git ] || git init -q --bare -b main /srv/heap-lab-git/heap-k8s.git; }"
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

# ── The lab's copy of heap-k8s ──────────────────────────────────────────────
step "heap-k8s ${HEAP_K8S_REF} from ${HEAP_K8S}"
rm -rf "$SRC"
git clone -q --branch "$HEAP_K8S_REF" --single-branch "$HEAP_K8S" "$SRC"
SRC_SHA=$(git -C "$SRC" rev-parse --short HEAD)

yaml_files() { find "$SRC" -path "$SRC/.git" -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print; }
while IFS= read -r f; do
    sed -i '' \
        -e "s#${UPSTREAM_URL}#${LAB_URL}#g" \
        -e "s#server: 23\.136\.216\.133#server: ${LAB_IP_BROOME}#" \
        -e "s#broome\.cluster\.recurse\.com:9100#${LAB_IP_BROOME}:9100#" \
        -e "s#crosby\.cluster\.recurse\.com:9100#${LAB_IP_CROSBY}:9100#" \
        -e "s#greene\.cluster\.recurse\.com:9100#${LAB_IP_GREENE}:9100#" \
        -e "/mercer\.cluster\.recurse\.com:9100/d" \
        "$f"
done < <(yaml_files)

# Invariant 6: nothing Argo CD applies may name Heap. Comments don't count.
LEFT=$(yaml_files | xargs grep -nE 'cluster\.recurse\.com|23\.136\.216\.|github\.com/recursecenter/heap-k8s' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
[ -z "$LEFT" ] || { echo "$LEFT" >&2; error "Heap addresses left after the lab's swaps; heap-k8s has a new one. Add it above."; }

git -C "$SRC" -c user.name=heap-lab -c user.email=heap-lab@heap-lab.invalid \
    commit -qam "heap-lab: lab values on top of ${SRC_SHA}"
GIT_SSH_COMMAND="ssh -F ${SSH_CONFIG}" git -C "$SRC" push -qf \
    "$(fqdn broome):/srv/heap-lab-git/heap-k8s.git" "HEAD:refs/heads/main"
info "Serving heap-k8s ${SRC_SHA} (+ lab values) at ${LAB_URL}"

# ── Argo CD ─────────────────────────────────────────────────────────────────
if new_kubectl -n argocd get application root >/dev/null 2>&1; then
    step "Asking Argo CD to refresh"
    new_kubectl -n argocd annotate applications --all argocd.argoproj.io/refresh=hard --overwrite >/dev/null
else
    # heap-k8s's own script, unchanged. Its guard wants the API's URL; the lab's
    # guard is that KUBECONFIG is .state/kube/new.yaml.
    step "bootstrap/bootstrap.sh"
    EXPECTED_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}') \
        bash "${SRC}/bootstrap/bootstrap.sh"
fi

step "Applications (Argo CD keeps going after this; task argo-status to look again)"
for i in $(seq 1 60); do
    apps=$(new_kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pending=$(new_kubectl -n argocd get applications --no-headers 2>/dev/null | grep -cvE 'Synced +Healthy' || true)
    [ "$apps" -gt 1 ] && [ "$pending" -eq 0 ] && break
    sleep 10
done
new_kubectl -n argocd get applications
