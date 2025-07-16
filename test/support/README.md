# Kazan Integration Test Setup

This directory contains files to help you set up and run Kazan integration tests against a real Kubernetes cluster.

## Quick Start (Recommended)

The easiest way to get started is using the automated setup script:

```bash
cd kazan/test/support
./setup-integration-tests.sh
```

This will:
1. Create a kind (Kubernetes in Docker) cluster named "kazan-test"
2. Apply the necessary RBAC permissions
3. Generate a kubeconfig file for testing
4. Provide instructions for running the tests

## Manual Setup

If you prefer manual setup or want to use an existing cluster:

### 1. Apply RBAC Configuration

```bash
kubectl apply -f kazan/test/support/kazan-test-rbac.yaml
```

### 2. Generate Kubeconfig

For Kubernetes 1.24+:
```bash
TOKEN=$(kubectl create token kazan-test-sa -n default --duration=8760h)
# Then create kubeconfig file manually or use existing cluster config
```

### 3. Run Tests

```bash
export KUBECONFIG=/path/to/your/kubeconfig
cd kazan && mix test --include integration
```

## What the Tests Need

The integration tests require:
- ✅ Pod operations (create, read, patch, delete, list, watch, logs)
- ✅ Namespace listing
- ✅ Deployment listing
- ✅ RBAC cluster role listing
- ✅ Custom Resource Definition management
- ✅ Custom resource operations (for test CRDs)

## Cleanup

To clean up after testing:

```bash
# If using the setup script (kind cluster)
kind delete cluster --name kazan-test

# If using manual setup
kubectl delete -f kazan/test/support/kazan-test-rbac.yaml
```

## Alternative Cluster Options

- **kind**: `kind create cluster --name kazan-test`
- **minikube**: `minikube start`
- **k3s**: `curl -sfL https://get.k3s.io | sh -`
- **Docker Desktop**: Enable Kubernetes in settings

## Troubleshooting

1. **Permission denied errors**: Make sure the RBAC configuration is applied
2. **Connection refused**: Check that your cluster is running and accessible
3. **Tests timing out**: Some tests create pods and wait for them to start; ensure your cluster can pull images

For more detailed setup instructions, see the artifacts in this chat.
