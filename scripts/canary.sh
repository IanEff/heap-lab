#!/usr/bin/env bash
# heap-lab: canary.sh [new|old|delete-old|delete-new]
# Deploy the canary (manifests/canary.yaml) to one cluster.
#   new  heap-nfs volume, the default IngressClass (cilium)
#   old  a static NFS PV on broome:/data/lab-canary, IngressClass traefik.
#        Not part of the old stage by default: it adds NFS mounts under
#        kubelet that Heap doesn't have. Use it to watch a migration.
set -euo pipefail
_TAG=canary
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

render() {  # storage-line ingress-class-line
    sed -e "s|\${CANARY_STORAGE}|$1|" -e "s|\${CANARY_INGRESS_CLASS}|$2|" "${LAB_ROOT}/manifests/canary.yaml"
}

case "${1:-new}" in
    new)
        render 'storageClassName: heap-nfs' '' | new_kubectl apply -f - >/dev/null
        k() { new_kubectl "$@"; } ;;
    old)
        on broome 'sudo install -d -m 0777 /data/lab-canary'
        old_kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolume
metadata: {name: lab-canary}
spec:
  capacity: {storage: 64Mi}
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef: {namespace: lab-canary, name: heartbeat}
  nfs: {server: ${LAB_IP_BROOME}, path: /data/lab-canary}
EOF
        render 'storageClassName: ""' 'ingressClassName: traefik' | old_kubectl apply -f - >/dev/null
        k() { old_kubectl "$@"; } ;;
    delete-new) new_kubectl delete ns lab-canary --wait=false; exit 0 ;;
    delete-old) old_kubectl delete ns lab-canary --wait=false; old_kubectl delete pv lab-canary --wait=false; exit 0 ;;
    *) error "usage: canary.sh new|old|delete-new|delete-old" ;;
esac
k -n lab-canary rollout status deploy/writer --timeout=5m >/dev/null
k -n lab-canary rollout status deploy/web --timeout=5m >/dev/null
info "canary.recurse.cloud is up on the ${1:-new} cluster."
