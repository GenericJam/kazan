#!/bin/bash

# Quick setup script for Kazan integration tests
# This script will:
# 1. Create a kind cluster if it doesn't exist
# 2. Apply RBAC configuration
# 3. Generate a kubeconfig file
# 4. Run the integration tests

set -e

CLUSTER_NAME="kazan-test"
KUBECONFIG_FILE="/tmp/kazan-test-kubeconfig"

echo "🚀 Setting up Kazan integration test environment..."

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "❌ kind is not installed. Please install it first:"
    echo "   # On macOS: brew install kind"
    echo "   # On Linux: see https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed. Please install it first."
    exit 1
fi

# Create kind cluster if it doesn't exist
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "📦 Creating kind cluster: ${CLUSTER_NAME}"
    kind create cluster --name ${CLUSTER_NAME}
else
    echo "✅ Kind cluster ${CLUSTER_NAME} already exists"
fi

# Set kubeconfig to use the kind cluster
echo "🔧 Setting kubeconfig context..."
kubectl config use-context kind-${CLUSTER_NAME}

# Apply RBAC configuration
echo "🔐 Applying RBAC configuration..."
kubectl apply -f "$(dirname "$0")/kazan-test-rbac.yaml"

# Wait for service account to be ready
echo "⏳ Checking service account..."
if kubectl get serviceaccount kazan-test-sa -n default >/dev/null 2>&1; then
    echo "✅ Service account is ready"
else
    echo "❌ Service account not found"
    exit 1
fi

# Generate kubeconfig for the service account
echo "📝 Generating kubeconfig..."

# Create a token for the service account (works with Kubernetes 1.24+)
TOKEN=$(kubectl create token kazan-test-sa -n default --duration=8760h)

# Get cluster information
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Create the kubeconfig
cat > ${KUBECONFIG_FILE} <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_SERVER}
  name: kind-${CLUSTER_NAME}
contexts:
- context:
    cluster: kind-${CLUSTER_NAME}
    user: kazan-test-sa
    namespace: default
  name: kazan-test-sa@kind-${CLUSTER_NAME}
current-context: kazan-test-sa@kind-${CLUSTER_NAME}
users:
- name: kazan-test-sa
  user:
    token: ${TOKEN}
EOF

echo "✅ Setup complete!"
echo ""
echo "📄 Kubeconfig created at: ${KUBECONFIG_FILE}"
echo "🧪 To run integration tests:"
echo "   export KUBECONFIG=${KUBECONFIG_FILE}"
echo "   cd kazan && mix test --include integration"
echo ""
echo "🔍 To test the connection:"
echo "   kubectl --kubeconfig=${KUBECONFIG_FILE} get namespaces"
echo ""
echo "🧹 To clean up when done:"
echo "   kind delete cluster --name ${CLUSTER_NAME}"

# Optionally run the tests if requested
if [ "$1" = "--run-tests" ]; then
    echo "🧪 Running integration tests..."
    export KUBECONFIG=${KUBECONFIG_FILE}
    cd kazan && mix test --include integration
fi
