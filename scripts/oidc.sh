#!/usr/bin/env bash
# heap-lab: oidc.sh
# Logins through batchmate.id on the new cluster. The API server's half comes
# from cluster-config's k3s role (`task k3s`, with LAB_OIDC_KUBECTL_CLIENT_ID in
# .env); this script does the rest:
#   1. checks both servers carry the role's authentication config;
#   2. writes .state/kube/login.yaml, a kubeconfig whose user is kubelogin, with
#      its token cache under .state/ (nothing in ~/.kube);
#   3. gives Argo CD batchmate.id as its OIDC provider.
# Step 3 patches the running Argo CD rather than heap-k8s: on Heap the same
# settings belong in heap-k8s's platform/argocd/values.yaml. Argo CD's own
# Application syncs by hand, so nothing reverts the patch until someone syncs it.
# Grants nothing: a login proves who someone is; RBAC is separate.
set -euo pipefail
_TAG=oidc
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export KUBECONFIG="${KUBE_DIR}/new.yaml"
[ -f "$KUBECONFIG" ] || error "No new cluster yet (.state/kube/new.yaml)."
: "${LAB_OIDC_ISSUER:?set in config/heap-lab.env}"
: "${LAB_OIDC_KUBECTL_CLIENT_ID:?set in .env (see .env.example)}"
: "${LAB_OIDC_ARGOCD_CLIENT_ID:?set in .env (see .env.example)}"
: "${LAB_OIDC_ARGOCD_CLIENT_SECRET:?set in .env (see .env.example)}"
# kubelogin, by absolute path: krew's bin dir is often missing from the PATH of
# non-interactive shells, and the kubeconfig runs it from whatever shell kubectl
# was started in.
KUBELOGIN=$(command -v kubectl-oidc_login || command -v kubelogin \
    || { [ -x "${KREW_ROOT:-$HOME/.krew}/bin/kubectl-oidc_login" ] && echo "${KREW_ROOT:-$HOME/.krew}/bin/kubectl-oidc_login"; } \
    || true)
[ -n "$KUBELOGIN" ] || error "kubelogin not found: kubectl krew install oidc-login (or brew install kubelogin)"
command -v jq >/dev/null || error "jq not found: brew install jq"

# ── 1. The API servers ──────────────────────────────────────────────────────
step "API servers: the role's authentication config"
for n in greene crosby; do
    on "$n" 'sudo grep -q "authentication-config=" /etc/rancher/k3s/config.yaml && sudo test -f /etc/rancher/k3s/authentication.yaml' \
        || error "$n has no OIDC config. Run: task k3s  (with LAB_OIDC_KUBECTL_CLIENT_ID in .env)"
done
info "greene and crosby accept ${LAB_OIDC_ISSUER} tokens for ${LAB_OIDC_KUBECTL_CLIENT_ID}"

# ── 2. A kubeconfig that logs in ────────────────────────────────────────────
LOGIN_KUBECONFIG="${KUBE_DIR}/login.yaml"
step "Writing ${LOGIN_KUBECONFIG#"${LAB_ROOT}/"}"
SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
mkdir -p "${KUBE_DIR}/oidc-cache"
cat > "$LOGIN_KUBECONFIG" <<EOF
# heap-lab: kubectl as a person, logged in through ${LAB_OIDC_ISSUER}.
# Written by scripts/oidc.sh. No secret in here; kubelogin caches the tokens in
# .state/kube/oidc-cache.
apiVersion: v1
kind: Config
clusters:
  - name: heap-lab
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: batchmate
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: ${KUBELOGIN}
        args:
          - get-token
          - --oidc-issuer-url=${LAB_OIDC_ISSUER}
          - --oidc-client-id=${LAB_OIDC_KUBECTL_CLIENT_ID}
          - --oidc-extra-scope=profile
          - --oidc-extra-scope=email
          - --token-cache-dir=${KUBE_DIR}/oidc-cache
        interactiveMode: IfAvailable
contexts:
  - name: heap-lab-login
    context:
      cluster: heap-lab
      user: batchmate
current-context: heap-lab-login
EOF
chmod 0600 "$LOGIN_KUBECONFIG"

# ── 3. Argo CD ──────────────────────────────────────────────────────────────
step "Argo CD: client secret in Secret argocd-oidc"
# From a file descriptor, so the secret is never in argv or the output.
new_kubectl -n argocd create secret generic argocd-oidc \
    --from-file=clientSecret=<(printf '%s' "$LAB_OIDC_ARGOCD_CLIENT_SECRET") \
    --dry-run=client -o json \
  | jq '.metadata.labels["app.kubernetes.io/part-of"] = "argocd"' \
  | new_kubectl apply -f - >/dev/null

step "Argo CD: url and oidc.config in argocd-cm"
# url is the lab's port-forward (task argo-ui), standing in for
# https://argocd.recurse.cloud; the client's redirect URI has to match it.
OIDC_CONFIG=$(cat <<EOF
name: Recurse
issuer: ${LAB_OIDC_ISSUER}
clientID: ${LAB_OIDC_ARGOCD_CLIENT_ID}
clientSecret: \$argocd-oidc:clientSecret
requestedScopes: ["openid", "profile", "email"]
# batchmate.id requires PKCE (S256) on every authorize request, confidential
# clients included; without it the login comes back invalid_request. Argo CD
# 3.6's server-side login sends PKCE when this is on.
enablePKCEAuthentication: true
EOF
)
new_kubectl -n argocd patch configmap argocd-cm --type merge -p "$(
    jq -n --arg cfg "$OIDC_CONFIG" '{data: {url: "http://localhost:8080", "oidc.config": $cfg}}'
)" >/dev/null
new_kubectl -n argocd rollout restart deployment argocd-server >/dev/null
new_kubectl -n argocd rollout status deployment argocd-server --timeout=180s

info "Done. kubectl as yourself:  KUBECONFIG=${LOGIN_KUBECONFIG#"${LAB_ROOT}/"} kubectl auth whoami"
info "Argo CD:                    task argo-ui, then 'Log in via Recurse'"
