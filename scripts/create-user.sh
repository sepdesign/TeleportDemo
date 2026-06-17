#!/bin/bash
# Create a non admin user through the Kubernetes CertificateSigningRequest flow.
# Run from your laptop with the admin kubeconfig active (KUBECONFIG set to it).
# Output goes to user-dev/ which git ignores.
set -euo pipefail

USER_NAME="dev"
GROUP="web-team"
NS="web"
CSR_NAME="${USER_NAME}-csr"
OUTDIR="user-${USER_NAME}"
mkdir -p "$OUTDIR"

# 1. Private key and CSR. The CN becomes the username. The O becomes the group.
openssl genrsa -out "$OUTDIR/${USER_NAME}.key" 2048
openssl req -new -key "$OUTDIR/${USER_NAME}.key" -out "$OUTDIR/${USER_NAME}.csr" \
  -subj "/CN=${USER_NAME}/O=${GROUP}"

# 2. Submit the CSR to the cluster. Remove any earlier one so re-runs work.
kubectl delete csr "${CSR_NAME}" --ignore-not-found
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: $(base64 -w0 "$OUTDIR/${USER_NAME}.csr")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 2592000
  usages:
  - client auth
EOF

# 3. Approve it. This is the admin decision.
kubectl certificate approve "${CSR_NAME}"

# 4. Read back the signed certificate.
kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}' | base64 -d > "$OUTDIR/${USER_NAME}.crt"

# 5. Build the user kubeconfig. Reuse the cluster CA and server from the admin kubeconfig.
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUTDIR/ca.crt"

KCFG="$OUTDIR/${USER_NAME}.kubeconfig"
rm -f "$KCFG"
kubectl config --kubeconfig="$KCFG" set-cluster "$CLUSTER_NAME" \
  --server="$SERVER" --certificate-authority="$OUTDIR/ca.crt" --embed-certs=true
kubectl config --kubeconfig="$KCFG" set-credentials "$USER_NAME" \
  --client-certificate="$OUTDIR/${USER_NAME}.crt" --client-key="$OUTDIR/${USER_NAME}.key" --embed-certs=true
kubectl config --kubeconfig="$KCFG" set-context "$USER_NAME" \
  --cluster="$CLUSTER_NAME" --user="$USER_NAME" --namespace="$NS"
kubectl config --kubeconfig="$KCFG" use-context "$USER_NAME"

echo "Done. User kubeconfig: $KCFG"
