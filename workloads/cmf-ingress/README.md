# CMF Ingress Application

## ⚠️ Deprecation Notice

This Application is **deprecated** and will be removed in a future update.

**New clusters should use the consolidated `ingresses` Application pattern** introduced in the `flink-demo-rbac` cluster, which groups all IngressRoutes (Control Center, CMF, MDS) into a single unified Application.

### Migration Path

The `flink-demo-rbac` cluster demonstrates the new pattern:
- **Old:** Separate Applications for `controlcenter-ingress`, `cmf-ingress`, `mds-ingress`
- **New:** Single `ingresses` Application managing all cluster IngressRoutes

**See:** `workloads/ingresses/` for the consolidated pattern

### Current Usage

This Application is currently used by:
- `flink-demo` cluster

### Migration Issue

Track the backport of the new pattern: #107

## Benefits of Consolidated Pattern

1. **Reduced ArgoCD clutter** - 3 Applications → 1
2. **Easier management** - All IngressRoutes sync together
3. **Better organization** - Single view of all cluster ingress rules
4. **Consistent pattern** - Aligns with new cluster creation standards

## Structure

```
workloads/cmf-ingress/
├── README.md              # This file
├── base/
│   ├── kustomization.yaml
│   └── ingressroute.yaml  # Base CMF IngressRoute template
└── overlays/
    └── flink-demo/        # Cluster-specific hostname
        ├── kustomization.yaml
        └── ingressroute-patch.yaml
```

## What This Application Does

Deploys a Traefik IngressRoute for Confluent Manager for Apache Flink (CMF) API access:

- **Service:** `cmf-service` in `operator` namespace
- **Port:** 80 (HTTP)
- **Hostname:** Cluster-specific (e.g., `cmf.flink-demo.confluentdemo.local`)

## Migration Instructions

To migrate a cluster to the new pattern:

1. Create `workloads/ingresses/overlays/<cluster-name>/` directory
2. Add IngressRoutes for Control Center, CMF, and MDS
3. Create `clusters/<cluster-name>/workloads/ingresses.yaml` Application
4. Remove individual ingress Applications from cluster kustomization
5. Delete cluster-specific overlays from old ingress applications

See PR #104 for complete migration example.
