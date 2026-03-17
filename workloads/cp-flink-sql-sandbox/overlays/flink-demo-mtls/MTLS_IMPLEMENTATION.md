# mTLS Implementation for Confluent Flink CLI

## Overview

This document describes the mTLS authentication implementation for the `cp-flink-sql-sandbox` workload, enabling secure communication between Confluent Flink CLI commands (in ArgoCD hooks) and the Confluent Manager for Apache Flink (CMF) service.

## Implementation Summary

### ✅ Completed Components

#### 1. Certificate Infrastructure
Created a complete PKI infrastructure using cert-manager:

- **Root CA Certificate** (`certificates/ca-certificate.yaml`)
  - Self-signed root CA with 10-year validity
  - Namespace: `operator`
  - Secret: `cmf-root-ca`

- **CA Issuers** (`certificates/ca-issuer.yaml`, `certificates/ca-issuer-flink.yaml`)
  - Separate issuers in `operator` and `flink` namespaces
  - Both reference the `cmf-root-ca` secret

- **Server Certificate** (`certificates/cmf-server-certificate.yaml`)
  - For CMF service TLS termination
  - 90-day validity with auto-renewal at 30 days
  - Includes all DNS SANs for the CMF service

- **Client Certificate** (`certificates/cmf-client-certificate.yaml`)
  - For Confluent Flink CLI authentication
  - 90-day validity with auto-renewal at 30 days
  - Namespace: `flink`

#### 2. Trust Distribution
- **Trust Bundle** (`certificates/trust-bundle.yaml`)
  - Uses trust-manager to distribute CA certificate
  - Creates `cmf-ca-bundle` ConfigMap in labeled namespaces
  - Namespace selector: `cmf-mtls: enabled`

- **Namespace Labels** (`namespace-labels.yaml`)
  - Labels `operator` and `flink` namespaces for bundle distribution

#### 3. CMF Service Configuration
Updated CMF operator Helm values (`workloads/cmf-operator/overlays/flink-demo/values.yaml`):

```yaml
cmf:
  authentication:
    type: mtls

mountedVolumes:
  volumes:
    - name: cmf-server-tls
      secret:
        secretName: cmf-server-tls
        defaultMode: 0440
  volumeMounts:
    - name: cmf-server-tls
      mountPath: /etc/cmf/tls
      readOnly: true
```

#### 4. CMFRestClass Configuration
Updated `workloads/flink-resources/base/cmfrestclass.yaml`:

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

#### 5. ArgoCD Hook Jobs
Updated both `cmf-init-job.yaml` and `cmf-compute-pool-job.yaml`:

**Changes:**
- Added `wait-for-certificates` initContainer to ensure certificates are ready
- Changed CMF_URL from HTTP (port 80) to HTTPS (port 443)
- Mounted client certificates and CA bundle
- Updated all `confluent flink` commands to use mTLS flags:
  ```bash
  --cacert /certs/ca/ca.crt \
  --cert /certs/client/tls.crt \
  --key /certs/client/tls.key
  ```
- Updated all `curl` commands to use mTLS options

#### 6. Documentation
- **certificates/README.md**: Comprehensive guide covering architecture, verification, troubleshooting
- **MTLS_IMPLEMENTATION.md** (this file): Implementation summary

## File Structure

```
workloads/cp-flink-sql-sandbox/base/
├── certificates/
│   ├── ca-certificate.yaml           # Root CA
│   ├── ca-issuer.yaml                # CA Issuer (operator namespace)
│   ├── ca-issuer-flink.yaml          # CA Issuer (flink namespace)
│   ├── cmf-server-certificate.yaml   # Server cert for CMF
│   ├── cmf-client-certificate.yaml   # Client cert for CLI
│   ├── trust-bundle.yaml             # trust-manager Bundle
│   ├── ca-secret-reflector.yaml      # Secret sync (if using Reflector)
│   └── README.md                     # Certificate infrastructure docs
├── cmf-compute-pool-job.yaml         # Updated with mTLS
├── cmf-config-configmap.yaml         # Unchanged
├── cmf-init-job.yaml                 # Updated with mTLS
├── kustomization.yaml                # Updated to include certificates
├── namespace-labels.yaml             # Namespace labels for trust bundle
├── schemas.yaml                      # Unchanged
└── topics.yaml                       # Unchanged
```

## Deployment Flow

The mTLS setup follows this deployment sequence:

1. **Namespace Labels Applied**
   - Labels added to `operator` and `flink` namespaces

2. **Root CA Created**
   - cert-manager creates self-signed CA certificate
   - Secret `cmf-root-ca` created in `operator` namespace

3. **CA Secret Synced** (requires external tooling)
   - Secret synced to `flink` namespace (via Reflector or manual copy)

4. **CA Issuers Ready**
   - Issuers in both namespaces reference the CA secret

5. **Server & Client Certificates Issued**
   - Server cert created in `operator` namespace
   - Client cert created in `flink` namespace

6. **Trust Bundle Distributed**
   - trust-manager creates `cmf-ca-bundle` ConfigMap in both namespaces

7. **CMF Operator Deployed**
   - Helm chart applies with mTLS configuration
   - Server certificate mounted to CMF pod

8. **CMFRestClass Applied**
   - CFK configured to use mTLS for CMF communication

9. **ArgoCD Hooks Execute**
   - Jobs wait for certificates to be ready
   - Execute Confluent Flink CLI commands with mTLS

## Prerequisites

### Required Components
- ✅ cert-manager (already deployed, sync-wave 20)
- ✅ trust-manager (already deployed, sync-wave 30)
- ✅ selfsigned-cluster-issuer (already exists)
- ⚠️  Secret sync solution (choose one):
  - **Option A**: [Reflector](https://github.com/emberstack/kubernetes-reflector)
  - **Option B**: Manual secret copy

### Namespace Requirements
- `operator` namespace must exist (already exists)
- `flink` namespace must exist (already exists)
- Both namespaces labeled with `cmf-mtls: enabled`

## Installation Steps

### 1. Deploy Secret Sync Solution (if using Reflector)

```bash
# Install Reflector via Helm
helm repo add emberstack https://emberstack.github.io/helm-charts
helm repo update
helm install reflector emberstack/reflector \
  --namespace kube-system \
  --create-namespace
```

### 2. Apply the Workload via ArgoCD

The workload is applied through the existing ArgoCD application:
- Location: `clusters/flink-demo/workloads/`
- Application name: `cp-flink-sql-sandbox`
- Sync wave: (TBD - after CMF operator)

ArgoCD will automatically:
1. Create namespace labels
2. Generate certificates via cert-manager
3. Distribute CA bundle via trust-manager
4. Update CMF operator with mTLS config
5. Update CMFRestClass
6. Execute hook jobs with mTLS

### 3. Verify Deployment

See `certificates/README.md` for comprehensive verification steps.

Quick verification:
```bash
# Check certificates
kubectl get certificates -n operator
kubectl get certificates -n flink

# Check trust bundle
kubectl get configmap cmf-ca-bundle -n flink

# Check hook job logs
kubectl logs -n flink -l job-name=cmf-catalog-database-init
```

## Configuration Details

### Certificate Lifetimes
| Certificate | Validity Period | Renewal Threshold |
|-------------|----------------|-------------------|
| Root CA | 10 years (87600h) | 30 days (720h) |
| Server Cert | 90 days (2160h) | 30 days (720h) |
| Client Cert | 90 days (2160h) | 30 days (720h) |

### Service Endpoints
| Service | Protocol | Port | Endpoint |
|---------|----------|------|----------|
| CMF Service | HTTPS | 443 | `cmf-service.operator.svc.cluster.local:443` |
| Schema Registry | HTTP | 8081 | `schemaregistry.kafka.svc.cluster.local:8081` |

### Secret Locations
| Secret | Namespace | Purpose | Contents |
|--------|-----------|---------|----------|
| `cmf-root-ca` | `operator` | Root CA | `ca.crt`, `tls.crt`, `tls.key` |
| `cmf-root-ca` | `flink` | Root CA (synced) | `ca.crt`, `tls.crt`, `tls.key` |
| `cmf-server-tls` | `operator` | Server cert | `ca.crt`, `tls.crt`, `tls.key` |
| `cmf-client-tls` | `flink` | Client cert | `ca.crt`, `tls.crt`, `tls.key` |

### ConfigMap Locations
| ConfigMap | Namespace | Purpose | Contents |
|-----------|-----------|---------|----------|
| `cmf-ca-bundle` | `operator` | CA bundle | `ca.crt` |
| `cmf-ca-bundle` | `flink` | CA bundle | `ca.crt` |

## Security Considerations

### ✅ Implemented Security Features
1. **Mutual TLS**: Both server and client authenticate each other
2. **Certificate Rotation**: Automatic renewal via cert-manager
3. **Secret Isolation**: Secrets scoped to specific namespaces
4. **Read-Only Mounts**: Certificate mounts are read-only
5. **Restricted Permissions**: Secret mode set to 0440

### 🔒 Security Best Practices
1. **Backup Root CA**: Securely backup the `cmf-root-ca` secret
2. **Monitor Expiry**: Set up alerts for certificate expiration
3. **RBAC**: Ensure only authorized ServiceAccounts access certificate secrets
4. **Audit Logs**: Enable audit logging for certificate operations
5. **Network Policies**: Consider adding NetworkPolicies to restrict traffic

## Troubleshooting

### Common Issues

#### 1. Certificate Not Ready
**Symptoms**: Hook jobs fail with "Certificates not ready yet"

**Solutions**:
```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check certificate status
kubectl describe certificate cmf-server-tls -n operator
kubectl describe certificate cmf-client-tls -n flink
```

#### 2. Secret Not Synced
**Symptoms**: Client certificate creation fails

**Solutions**:
```bash
# Verify Reflector is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=reflector

# Check Reflector logs
kubectl logs -n kube-system -l app.kubernetes.io/name=reflector

# Manual sync (alternative)
kubectl get secret cmf-root-ca -n operator -o yaml | \
  sed 's/namespace: operator/namespace: flink/' | \
  kubectl apply -f -
```

#### 3. mTLS Connection Failures
**Symptoms**: Hook jobs fail with SSL/TLS errors

**Solutions**:
```bash
# Verify CMF service is using HTTPS
kubectl get svc -n operator cmf-service

# Check CMF logs for TLS errors
kubectl logs -n operator -l app.kubernetes.io/name=confluent-manager-for-apache-flink

# Test certificate chain
kubectl get secret cmf-client-tls -n flink -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout
```

#### 4. Trust Bundle Not Created
**Symptoms**: ConfigMap `cmf-ca-bundle` not found

**Solutions**:
```bash
# Check trust-manager logs
kubectl logs -n cert-manager -l app.kubernetes.io/name=trust-manager

# Verify namespace labels
kubectl get namespace operator --show-labels
kubectl get namespace flink --show-labels

# Check Bundle resource
kubectl describe bundle cmf-ca-bundle
```

## Testing

### Manual Testing

#### Test Certificate Creation
```bash
# Wait for certificates to be ready
kubectl wait --for=condition=Ready certificate/cmf-server-tls -n operator --timeout=300s
kubectl wait --for=condition=Ready certificate/cmf-client-tls -n flink --timeout=300s
```

#### Test mTLS Connection
```bash
# Create a test pod with certificates mounted
kubectl run -n flink test-mtls \
  --image=confluentinc/confluent-cli:4.53.0 \
  --rm -it \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "test-mtls",
      "image": "confluentinc/confluent-cli:4.53.0",
      "command": ["sh"],
      "volumeMounts": [
        {"name": "client-certs", "mountPath": "/certs/client", "readOnly": true},
        {"name": "ca-bundle", "mountPath": "/certs/ca", "readOnly": true}
      ]
    }],
    "volumes": [
      {"name": "client-certs", "secret": {"secretName": "cmf-client-tls"}},
      {"name": "ca-bundle", "configMap": {"name": "cmf-ca-bundle"}}
    ]
  }
}'

# Inside the pod, test connection:
curl -v \
  --cacert /certs/ca/ca.crt \
  --cert /certs/client/tls.crt \
  --key /certs/client/tls.key \
  https://cmf-service.operator.svc.cluster.local:443/health
```

## Validation Checklist

Before considering the implementation complete, verify:

- [ ] cert-manager is running
- [ ] trust-manager is running
- [ ] Secret sync solution is in place (Reflector or manual)
- [ ] Namespace labels applied (`cmf-mtls: enabled`)
- [ ] Root CA certificate created
- [ ] Server certificate created in `operator` namespace
- [ ] Client certificate created in `flink` namespace
- [ ] Trust bundle ConfigMaps exist in both namespaces
- [ ] CMF operator Helm values updated
- [ ] CMF pods restarted with new configuration
- [ ] CMFRestClass updated
- [ ] Hook jobs execute successfully
- [ ] Certificates auto-renew before expiry

## Rollback Plan

If issues occur, rollback by:

1. **Revert CMF Operator Helm Values**
   ```bash
   # Edit values to remove mTLS config
   # Redeploy CMF operator
   ```

2. **Revert CMFRestClass**
   ```bash
   kubectl patch cmfrestclass cmf-rest-class -n flink --type merge -p '
   {
     "spec": {
       "cmfRest": {
         "endpoint": "http://cmf-service.operator.svc.cluster.local:80",
         "authentication": null,
         "tls": null
       }
     }
   }'
   ```

3. **Revert Hook Jobs**
   - Update jobs to use HTTP endpoint
   - Remove certificate mounts and mTLS flags

4. **Clean Up Certificate Resources**
   ```bash
   kubectl delete -k workloads/cp-flink-sql-sandbox/base/certificates/
   ```

## Future Enhancements

Potential improvements:
1. **External CA Integration**: Use production CA instead of self-signed
2. **Certificate Monitoring**: Add Prometheus metrics for certificate expiry
3. **Automated Testing**: CI/CD tests for mTLS connectivity
4. **Policy Enforcement**: Use OPA/Gatekeeper to enforce mTLS
5. **Mutual TLS for Kafka**: Extend mTLS to Kafka client connections

## References

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [trust-manager Documentation](https://cert-manager.io/docs/trust/trust-manager/)
- [Confluent CMF Documentation](https://docs.confluent.io/operator/current/co-manage-flink.html)
- [Confluent CLI Documentation](https://docs.confluent.io/confluent-cli/current/overview.html)
- [Kubernetes TLS Best Practices](https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets)

---

**Implementation Date**: 2026-03-16
**Status**: ✅ Complete (pending deployment)
**Validation**: ⏳ Pending deployment to cluster
