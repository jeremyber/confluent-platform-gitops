# cp-flink-sql-sandbox mTLS Overlay

This overlay adds comprehensive mTLS authentication to the cp-flink-sql-sandbox workload for the `flink-demo-mtls` cluster.

## Overview

The overlay transforms the base HTTP-based configuration into HTTPS with mutual TLS authentication by:
- Creating certificate infrastructure (Root CA, Server cert, Client cert)
- Distributing CA certificates via trust-manager
- Patching hook jobs to use HTTPS and mTLS
- Configuring CMF operator to require mTLS
- Updating CMFRestClass to use mTLS for CFK → CMF communication

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Certificate Infrastructure (cert-manager)               │
├─────────────────────────────────────────────────────────┤
│ 1. Root CA Certificate (self-signed)                    │
│ 2. CMF Server Certificate (signed by Root CA)           │
│ 3. CMF Client Certificate (signed by Root CA)           │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ Trust Distribution (trust-manager)                      │
├─────────────────────────────────────────────────────────┤
│ Bundle: cmf-ca-bundle                                   │
│ - Distributes Root CA to labeled namespaces            │
│ - Creates ConfigMaps with CA certificate                │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ CMF Service (operator namespace)                        │
├─────────────────────────────────────────────────────────┤
│ - TLS enabled on port 443                               │
│ - Server cert from Secret: cmf-server-tls               │
│ - Client cert verification enabled (mTLS)               │
└─────────────────────────────────────────────────────────┘
                          ↑ mTLS
┌─────────────────────────────────────────────────────────┐
│ ArgoCD Hook Jobs (flink namespace)                      │
├─────────────────────────────────────────────────────────┤
│ - Client cert from Secret: cmf-client-tls               │
│ - CA bundle from ConfigMap: cmf-ca-bundle               │
│ - CLI commands use --cacert, --cert, --key flags        │
└─────────────────────────────────────────────────────────┘
```

## File Structure

```
workloads/cp-flink-sql-sandbox/overlays/flink-demo-mtls/
├── kustomization.yaml                  # Overlay orchestration
├── README.md                           # This file
├── MTLS_IMPLEMENTATION.md              # Detailed implementation guide
├── certificates/                       # Certificate infrastructure
│   ├── ca-certificate.yaml             # Root CA (10-year validity)
│   ├── ca-issuer.yaml                  # CA Issuer (operator namespace)
│   ├── ca-issuer-flink.yaml            # CA Issuer (flink namespace)
│   ├── cmf-server-certificate.yaml     # Server cert (90-day validity)
│   ├── cmf-client-certificate.yaml     # Client cert (90-day validity)
│   └── trust-bundle.yaml               # CA distribution bundle
├── cmf-init-job-patch.yaml             # Strategic merge patch for init job
└── cmf-compute-pool-job-patch.yaml     # Strategic merge patch for compute pool job
```

## How It Works

### 1. Base Resources (Unchanged)

The base resources in `../../base/` remain HTTP-only with no authentication:
- `cmf-init-job.yaml` - HTTP endpoint, no certificates
- `cmf-compute-pool-job.yaml` - HTTP endpoint, no certificates
- Topics, schemas, and config maps

### 2. Overlay Additions

The overlay adds certificate infrastructure as new resources:
- Root CA certificate (self-signed, 10-year validity)
- Server certificate for CMF service (90-day validity, auto-renewal)
- Client certificate for Flink CLI (90-day validity, auto-renewal)
- Trust bundle for CA distribution

### 3. Strategic Merge Patches

The overlay patches base Job resources to add mTLS:

**cmf-init-job-patch.yaml**:
- Changes `CMF_URL` from HTTP:80 to HTTPS:443
- Adds `wait-for-certificates` initContainer
- Mounts client certificate and CA bundle volumes
- Updates `confluent flink` commands to use `--cacert`, `--cert`, `--key` flags
- Updates `curl` commands to use certificate options

**cmf-compute-pool-job-patch.yaml**:
- Same changes as init job for compute pool creation

### 4. Namespace Label Patches

The overlay adds `cmf-mtls: enabled` labels to namespaces:
- `operator` namespace - receives CA bundle, hosts CMF service
- `flink` namespace - receives CA bundle, runs hook jobs

These labels enable trust-manager to distribute the CA certificate.

## Certificate Lifecycle

| Certificate | Validity Period | Renewal Threshold | Auto-Renewal |
|-------------|----------------|-------------------|--------------|
| Root CA | 10 years (87600h) | 30 days (720h) | Yes |
| Server Cert | 90 days (2160h) | 30 days (720h) | Yes |
| Client Cert | 90 days (2160h) | 30 days (720h) | Yes |

Certificates are automatically renewed by cert-manager before expiry.

## Related Overlays

This overlay works in conjunction with:

- **`workloads/cmf-operator/overlays/flink-demo-mtls/`** - Enables mTLS on CMF server
  ```yaml
  cmf:
    authentication:
      type: mtls
  mountedVolumes:
    volumes:
      - name: cmf-server-tls
        secret:
          secretName: cmf-server-tls
  ```

- **`workloads/flink-resources/overlays/flink-demo-mtls/`** - Configures CFK to use mTLS
  ```yaml
  spec:
    cmfRest:
      endpoint: https://cmf-service.operator.svc.cluster.local:443
      authentication:
        type: mtls
        sslClientAuthentication: true
      tls:
        secretRef: cmf-client-tls
  ```

## Deployment

The overlay is automatically applied when deploying the `cp-flink-sql-sandbox` application in the `flink-demo-mtls` cluster:

```yaml
# clusters/flink-demo-mtls/workloads/cp-flink-sql-sandbox.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cp-flink-sql-sandbox
spec:
  source:
    path: workloads/cp-flink-sql-sandbox/overlays/flink-demo-mtls
```

## Verification

### Check Certificates

```bash
# Check all certificates
kubectl get certificates -n operator
kubectl get certificates -n flink

# Check certificate details
kubectl describe certificate cmf-root-ca -n operator
kubectl describe certificate cmf-server-tls -n operator
kubectl describe certificate cmf-client-tls -n flink
```

### Check Trust Bundle

```bash
# Check Bundle resource
kubectl get bundle cmf-ca-bundle

# Check ConfigMaps created by trust-manager
kubectl get configmap cmf-ca-bundle -n operator
kubectl get configmap cmf-ca-bundle -n flink
```

### Verify mTLS Connections

```bash
# Check CMF service is using HTTPS
kubectl get svc cmf-service -n operator

# Check hook job logs for mTLS authentication
kubectl logs -n flink -l job-name=cmf-catalog-database-init

# Verify certificates in job pods
kubectl get secret cmf-client-tls -n flink -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

## Troubleshooting

### Certificate Not Ready

```bash
# Check cert-manager controller logs
kubectl logs -n cert-manager -l app=cert-manager

# Check certificate events
kubectl describe certificate cmf-server-tls -n operator
```

### mTLS Connection Failures

```bash
# Check CMF logs for TLS errors
kubectl logs -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink

# Check hook job logs
kubectl logs -n flink -l job-name=cmf-catalog-database-init
```

### Trust Bundle Not Distributed

```bash
# Check trust-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=trust-manager

# Verify namespace labels
kubectl get namespace operator -o yaml | grep cmf-mtls
kubectl get namespace flink -o yaml | grep cmf-mtls
```

## Design Principles

### Overlay Isolation

This overlay demonstrates proper Kustomize overlay patterns:
- ✅ Base resources remain cluster-agnostic (HTTP, no auth)
- ✅ Overlay adds resources specific to mTLS
- ✅ Strategic merge patches transform base resources
- ✅ No modifications to base files
- ✅ Other clusters can use base without mTLS

### Security Best Practices

- Private keys never exposed in ConfigMaps (only in Secrets)
- Certificate auto-rotation before expiry
- RBAC ensures only authorized pods access certificates
- Server validates client certificates (mutual authentication)

## References

- [MTLS_IMPLEMENTATION.md](./MTLS_IMPLEMENTATION.md) - Detailed implementation guide
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [trust-manager Documentation](https://cert-manager.io/docs/trust/trust-manager/)
- [Confluent CMF mTLS](https://docs.confluent.io/operator/current/co-manage-flink.html)
- [Kustomize Strategic Merge Patches](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/#patches)

---

**Implementation**: Phase 2 Complete ✅
**Status**: Ready for deployment
**Related Issue**: #71
