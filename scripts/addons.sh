#!/usr/bin/env bash
# heap-lab: addons.sh
# The storage half of Phase 4, standing in until the config repo's
# platform/csi-driver-nfs exists: /data/k8s on broome (gate G-6, the host
# team's on Heap), csi-driver-nfs, and StorageClass heap-nfs (R-S2).
# Idempotent. Run against the new cluster.
set -euo pipefail
_TAG=addons
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export KUBECONFIG="${KUBE_DIR}/new.yaml"
[ -f "$KUBECONFIG" ] || error "No new cluster yet (.state/kube/new.yaml)."

step "/data/k8s on broome (G-6)"
on broome 'sudo install -d -m 0755 -o root -g root /data/k8s'

step "csi-driver-nfs ${CSI_NFS_VERSION}"
helm upgrade --install csi-driver-nfs csi-driver-nfs \
    --repo https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts \
    --version "${CSI_NFS_VERSION}" -n kube-system \
    --set controller.replicas=1 \
    --wait --timeout 10m >/dev/null

step "StorageClass heap-nfs"
sed -e "s/\${LAB_IP_BROOME}/${LAB_IP_BROOME}/" "${LAB_ROOT}/manifests/new/heap-nfs.yaml" | kubectl apply -f - >/dev/null
