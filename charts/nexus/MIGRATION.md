# Nexus Provisioning Migration

## Overview

Nexus provisioning has been refactored from inline kubectl manifests to a proper Helm chart.

## What Changed

### Before (Raw Manifests)
- ~200 lines of inline YAML in `provision-delivery.sh`
- Hard to maintain and version
- No templating or reusability
- Difficult to customize per environment

### After (Helm Chart)
- Dedicated Helm chart in `envs/shared/apps/nexus/`
- Proper templating with `values.yaml`
- Reusable across environments
- Easy to customize and upgrade

## File Structure

```
envs/shared/apps/nexus/
├── Chart.yaml              # Chart metadata
├── values.yaml             # Default configuration
├── README.md               # Chart documentation
├── MIGRATION.md            # This file
├── .helmignore             # Files to exclude from chart
└── templates/
    ├── _helpers.tpl        # Template helpers
    ├── NOTES.txt           # Post-install notes
    ├── service.yaml        # Service resource
    ├── statefulset.yaml    # StatefulSet resource
    ├── pvc.yaml            # PersistentVolumeClaim
    ├── middleware.yaml     # Traefik IP whitelist middleware
    └── ingress.yaml        # Ingress resource
```

## Key Features

### 1. IP Whitelist Configuration
- Default ranges (Tailscale, cluster networks) built into chart
- Custom IPs loaded from `envs/shared/nexus-whitelist-ips.txt`
- Automatically applied via Traefik middleware

### 2. Resource Management
- Configurable CPU/memory limits
- JVM tuning parameters
- Persistent storage configuration

### 3. Ingress & TLS
- Automatic cert-manager integration
- Traefik ingress with middleware support
- Configurable hostname per environment

### 4. Health Probes
- Liveness and readiness probes
- Configurable delays and thresholds

## Provisioning Script Changes

### Old Code (Lines 1346-1556)
```bash
# 200+ lines of inline kubectl apply with heredocs
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
# ... many more lines
EOF
```

### New Code (Lines 1346-1449)
```bash
# Load custom IPs from file
custom_ips=()
while IFS= read -r line; do
  custom_ips+=("$ip")
done < "$whitelist_file"

# Generate Helm values
cat > values.yaml <<YAML
ingress:
  host: ${NEXUS_HOST}
ipWhitelist:
  customIPs:
    - "${custom_ips[@]}"
YAML

# Deploy via Helm
helm upgrade --install nexus envs/shared/apps/nexus \
  --namespace nexus \
  --values values.yaml
```

## Benefits

### 1. Maintainability
- ✅ Separation of concerns (chart vs provisioning logic)
- ✅ Easier to review and update
- ✅ Standard Helm chart structure

### 2. Reusability
- ✅ Can be deployed to multiple environments
- ✅ Can be versioned independently
- ✅ Can be tested in isolation

### 3. Flexibility
- ✅ Easy to override values per environment
- ✅ Can use Helm's templating features
- ✅ Can add new resources without touching provisioning script

### 4. Documentation
- ✅ Chart README with usage examples
- ✅ NOTES.txt displayed after installation
- ✅ Values documented in values.yaml

## Migration Path

### For New Deployments (Recommended)

For clean installations, simply run:
```bash
tools/provision-delivery.sh <env-name>
```

The script will automatically:
1. Create namespace
2. Load custom IPs from `nexus-whitelist-ips.txt`
3. Generate deployment credentials
4. Deploy the Helm chart
5. Configure Nexus via API (admin password, deployment user)
6. Configure GitHub environment secrets

### For Existing kubectl-managed Deployments

If you have Nexus already deployed via kubectl (raw manifests):

#### Option 1: Clean Reinstall (No Data Preservation)

**Best for**: Development/testing environments, or when you don't need to preserve existing artifacts.

```bash
# Delete all old resources (including data)
kubectl -n nexus delete statefulset nexus
kubectl -n nexus delete service nexus
kubectl -n nexus delete ingress nexus
kubectl -n nexus delete middleware nexus-ip-whitelist
kubectl -n nexus delete pvc nexus-data  # ⚠️ DELETES ALL DATA

# Install via Helm
tools/provision-delivery.sh <env-name>
```

#### Option 2: Migrate to Helm (Preserves Data)

**Best for**: Production environments where you need to preserve existing Maven artifacts.

```bash
# Step 1: Use migration script to add Helm ownership labels
tools/migrate-nexus-to-helm.sh nexus

# Step 2: Deploy via Helm (will adopt existing resources)
tools/provision-delivery.sh <env-name>
```

The migration script adds required Helm labels and annotations to existing resources:
- `app.kubernetes.io/managed-by: Helm`
- `meta.helm.sh/release-name: nexus`
- `meta.helm.sh/release-namespace: nexus`

This allows Helm to adopt the resources without recreating them.

#### Option 3: Manual Migration with Data Backup

**Best for**: Maximum safety, allows rollback if needed.

```bash
# Step 1: Backup PVC data
kubectl -n nexus get pvc nexus-data -o yaml > nexus-pvc-backup.yaml

# Step 2: Export Nexus data (optional, for extra safety)
kubectl -n nexus exec nexus-0 -- tar czf /tmp/nexus-backup.tar.gz /nexus-data
kubectl -n nexus cp nexus-0:/tmp/nexus-backup.tar.gz ./nexus-backup.tar.gz

# Step 3: Delete old resources (keep PVC)
kubectl -n nexus delete statefulset nexus
kubectl -n nexus delete service nexus
kubectl -n nexus delete ingress nexus
kubectl -n nexus delete middleware nexus-ip-whitelist
# DO NOT delete PVC

# Step 4: Deploy via Helm with existing PVC
helm install nexus envs/shared/apps/nexus \
  --namespace nexus \
  --set ingress.host=nexus.example.com \
  --set persistence.existingClaim=nexus-data

# Or use provisioning script (auto-detects existing PVC)
tools/provision-delivery.sh <env-name>
```

## Testing

### Validate Chart Syntax
```bash
helm lint envs/shared/apps/nexus
```

### Dry Run
```bash
helm install nexus envs/shared/apps/nexus \
  --namespace nexus \
  --dry-run \
  --debug \
  --set ingress.host=nexus.example.com
```

### Template Output
```bash
helm template nexus envs/shared/apps/nexus \
  --namespace nexus \
  --set ingress.host=nexus.example.com
```

## Rollback

If you need to rollback to a previous Helm release:

```bash
# List releases
helm list -n nexus

# Rollback to previous version
helm rollback nexus -n nexus

# Rollback to specific revision
helm rollback nexus 1 -n nexus
```

## Future Enhancements

Potential improvements for the chart:

- [ ] Add support for LDAP/SAML authentication
- [ ] Configure default repositories via init container
- [ ] Add backup/restore job templates
- [ ] Support for horizontal scaling (if Nexus Pro)
- [ ] Prometheus metrics exporter sidecar
- [ ] Custom init scripts via ConfigMap
- [ ] Support for multiple storage backends

## Related Files

- `tools/provision-delivery.sh` - Main provisioning script
- `envs/shared/nexus-whitelist-ips.txt` - Custom IP whitelist
- `docs/NEXUS_SECURITY.md` - Security documentation
- `docs/NEXUS_PROVISIONING.md` - Provisioning guide (if exists)
