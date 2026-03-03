#!/usr/bin/env bash
#
# new-cluster.sh - Scaffold new cluster directory structure
#
# Usage: ./scripts/new-cluster.sh <cluster-name> <domain>
#   or: ./scripts/new-cluster.sh (interactive mode)
#
# Example: ./scripts/new-cluster.sh prod-us-east kafka.example.com
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

success() {
    echo -e "${GREEN}✓ $1${NC}"
}

info() {
    echo -e "${YELLOW}→ $1${NC}"
}

usage() {
    cat <<EOF
Usage: $0 <cluster-name> <domain>
   or: $0 (interactive mode)

Scaffold a new cluster directory structure for GitOps deployment.

Arguments:
  cluster-name  Name of the cluster (e.g., prod-us-east, staging, dev)
  domain        Base domain for the cluster (e.g., kafka.example.com)

Example:
  $0 prod-us-east kafka.example.com

EOF
}

# Validate cluster name
validate_cluster_name() {
    local name="$1"

    # Check format (alphanumeric, hyphens only)
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
        error "Cluster name must contain only lowercase letters, numbers, and hyphens"
        error "Must start and end with alphanumeric character"
        return 1
    fi

    # Check length
    if [ ${#name} -lt 3 ]; then
        error "Cluster name must be at least 3 characters"
        return 1
    fi

    if [ ${#name} -gt 63 ]; then
        error "Cluster name must be less than 63 characters"
        return 1
    fi

    return 0
}

# Validate domain
validate_domain() {
    local domain="$1"

    # Basic domain format check
    if ! [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
        error "Domain must contain only lowercase letters, numbers, hyphens, and dots"
        return 1
    fi

    return 0
}

# Check if cluster already exists
check_cluster_exists() {
    local cluster_name="$1"
    local cluster_dir="clusters/$cluster_name"

    if [ -d "$cluster_dir" ]; then
        error "Cluster directory already exists: $cluster_dir"
        return 1
    fi

    return 0
}

# Get repository URL from git config
get_repo_url() {
    local url
    url=$(git config --get remote.origin.url 2>/dev/null || echo "")

    if [ -z "$url" ]; then
        # Default to upstream if no origin
        echo "https://github.com/osowski/confluent-platform-gitops.git"
    else
        # Convert SSH URL to HTTPS if needed
        if [[ "$url" =~ ^git@github.com:(.+)\.git$ ]]; then
            echo "https://github.com/${BASH_REMATCH[1]}.git"
        else
            echo "$url"
        fi
    fi
}

# Create bootstrap.yaml
create_bootstrap() {
    local cluster_name="$1"
    local domain="$2"
    local repo_url="$3"
    local file="clusters/$cluster_name/bootstrap.yaml"

    cat > "$file" <<EOF
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: $repo_url
    targetRevision: HEAD
    path: bootstrap
    helm:
      valuesObject:
        cluster:
          name: $cluster_name
          domain: $domain
        git:
          targetRevision: "HEAD"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

    success "Created $file"
}

# Create infrastructure kustomization.yaml
create_infrastructure_kustomization() {
    local cluster_name="$1"
    local file="clusters/$cluster_name/infrastructure/kustomization.yaml"

    cat > "$file" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
# Add infrastructure applications here as they are created
# Examples:
# - traefik.yaml
# - kube-prometheus-stack.yaml
# - cert-manager.yaml
# - vault.yaml
EOF

    success "Created $file"
}

# Create workloads kustomization.yaml
create_workloads_kustomization() {
    local cluster_name="$1"
    local file="clusters/$cluster_name/workloads/kustomization.yaml"

    cat > "$file" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources: []
# Add workload applications here as they are created
# Examples:
# - namespaces.yaml
# - cfk-operator.yaml
# - confluent-resources.yaml
# - flink-kubernetes-operator.yaml
EOF

    success "Created $file"
}

# Create cluster README.md
create_readme() {
    local cluster_name="$1"
    local domain="${2:-}"
    local file="clusters/$cluster_name/README.md"

    cat > "$file" <<EOF
# $cluster_name Cluster

## Overview

- **Cluster Name:** $cluster_name
- **Domain:** $domain
- **Bootstrap:** \`bootstrap.yaml\`

## Quick Start

### Prerequisites

- Kubernetes cluster with ArgoCD installed
- \`kubectl\` configured with cluster access

### Deploy Bootstrap

\`\`\`bash
kubectl apply -f clusters/$cluster_name/bootstrap.yaml
\`\`\`

### Verify Deployment

\`\`\`bash
# Check bootstrap application
kubectl get application bootstrap -n argocd

# Check parent applications
kubectl get applications -n argocd

# Watch sync progress
kubectl get applications -n argocd -w
\`\`\`

## Applications

### Infrastructure

Infrastructure applications are defined in \`infrastructure/kustomization.yaml\`.

TODO: Add infrastructure applications

### Workloads

Workload applications are defined in \`workloads/kustomization.yaml\`.

TODO: Add workload applications

## Access

### ArgoCD UI

\`\`\`bash
# Get cluster-specific hostname (after argocd-ingress is deployed)
kubectl get ingressroute -n argocd argocd-server -o yaml | yq '.spec.routes[0].match'

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
\`\`\`

Navigate to \`https://argocd.$cluster_name.$domain\` and login with username \`admin\`.

## Customization

This cluster was created using \`scripts/new-cluster.sh\`. Customize by:

1. Adding applications to \`infrastructure/kustomization.yaml\`
2. Adding applications to \`workloads/kustomization.yaml\`
3. Creating cluster-specific overlays in \`infrastructure/\` and \`workloads/\`

See [Cluster Onboarding](../../docs/cluster-onboarding.md) for detailed guidance.
EOF

    success "Created $file"
}

# Interactive mode
interactive_mode() {
    echo "=== New Cluster Setup (Interactive Mode) ==="
    echo ""

    # Get cluster name
    while true; do
        read -rp "Enter cluster name (e.g., prod-us-east): " cluster_name
        if [ -z "$cluster_name" ]; then
            error "Cluster name cannot be empty"
            continue
        fi
        if validate_cluster_name "$cluster_name"; then
            if check_cluster_exists "$cluster_name"; then
                break
            fi
        fi
    done

    # Get domain
    while true; do
        read -rp "Enter domain (e.g., kafka.example.com): " domain
        if [ -z "$domain" ]; then
            error "Domain cannot be empty"
            continue
        fi
        if validate_domain "$domain"; then
            break
        fi
    done

    echo ""
    echo "Summary:"
    echo "  Cluster Name: $cluster_name"
    echo "  Domain:       $domain"
    echo ""
    read -rp "Create cluster? [y/N] " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled"
        exit 0
    fi

    CLUSTER_NAME="$cluster_name"
    DOMAIN="$domain"
}

# Main function
main() {
    # Check if running from repository root (handles both normal repos and worktrees)
    if [ ! -e ".git" ] || [ ! -f "bootstrap/Chart.yaml" ]; then
        error "Must run from repository root"
        exit 1
    fi

    # Parse arguments or run interactive mode
    if [ $# -eq 0 ]; then
        interactive_mode
    elif [ $# -eq 2 ]; then
        CLUSTER_NAME="$1"
        DOMAIN="$2"

        # Validate inputs
        if ! validate_cluster_name "$CLUSTER_NAME"; then
            exit 1
        fi

        if ! validate_domain "$DOMAIN"; then
            exit 1
        fi

        if ! check_cluster_exists "$CLUSTER_NAME"; then
            exit 1
        fi
    elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
        exit 0
    else
        error "Invalid arguments"
        echo ""
        usage
        exit 1
    fi

    # Get repository URL
    REPO_URL=$(get_repo_url)

    info "Creating cluster directory structure for: $CLUSTER_NAME"
    info "Domain: $DOMAIN"
    info "Repository: $REPO_URL"
    echo ""

    # Create directories
    mkdir -p "clusters/$CLUSTER_NAME/infrastructure"
    mkdir -p "clusters/$CLUSTER_NAME/workloads"
    success "Created directories"

    # Create files
    create_bootstrap "$CLUSTER_NAME" "$DOMAIN" "$REPO_URL"
    create_infrastructure_kustomization "$CLUSTER_NAME"
    create_workloads_kustomization "$CLUSTER_NAME"
    create_readme "$CLUSTER_NAME" "$DOMAIN"

    echo ""
    success "Cluster $CLUSTER_NAME created successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Review generated files in clusters/$CLUSTER_NAME/"
    echo "  2. Add infrastructure applications to clusters/$CLUSTER_NAME/infrastructure/kustomization.yaml"
    echo "  3. Add workload applications to clusters/$CLUSTER_NAME/workloads/kustomization.yaml"
    echo "  4. Commit changes: git add clusters/$CLUSTER_NAME/ && git commit -m 'Add $CLUSTER_NAME cluster'"
    echo "  5. Deploy bootstrap: kubectl apply -f clusters/$CLUSTER_NAME/bootstrap.yaml"
    echo ""
    echo "For detailed guidance, see:"
    echo "  - docs/cluster-onboarding.md"
    echo "  - docs/adoption-guide.md"
}

main "$@"
