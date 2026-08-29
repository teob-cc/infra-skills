# Nexus Quick Start Guide

## Clean Installation (5 minutes)

### Prerequisites

- Kubernetes cluster with Traefik ingress
- cert-manager installed
- `kubectl` and `helm` CLI tools
- DNS configured (or wildcard DNS)

### Step 1: Configure Custom IPs (Optional)

Add your public IP to the whitelist:

```bash
echo "203.0.113.10" >> envs/shared/nexus-whitelist-ips.txt  # replace with your office IP
```

Or connect via Tailscale VPN (100.64.0.0/10 is whitelisted by default).

### Step 2: Set Environment Variables

**Option A: Public Access (No IP Whitelist)**

```bash
# Required
export NEXUS_HOST="nexus.example.com"
export EXTERNAL_IP="203.0.113.10"  # Your public IP

# Optional (defaults shown)
export NAMESPACE_NEXUS="nexus"
export NEXUS_STORAGE_CLASS="local-path"
export NEXUS_STORAGE_SIZE="50Gi"
export CLUSTER_ISSUER="letsencrypt-prod"
```

**Option B: Tailscale DNS (Recommended - Secure)**

In `envs/<env>/env.properties`:

```properties
# Just set HOSTNAME - everything else is auto-generated!
HOSTNAME=dev.example.com

# This automatically creates:
# - NEXUS_HOST=nexus.dev.example.com
# - Auto-detects Tailscale IP
# - Creates DNS record
# - Deploys without IP whitelist

# Optional overrides
NEXUS_ENABLE_IP_WHITELIST=false
NEXUS_STORAGE_CLASS=local-path
NEXUS_STORAGE_SIZE=50Gi
```

**What happens automatically:**
1. ✅ `NEXUS_HOST` generated from `HOSTNAME`
2. ✅ Tailscale IP auto-detected (tries `tailscale ip -4`, then checks K8s nodes)
3. ✅ DNS record created: `nexus.dev.example.com` → `100.x.x.x`
4. ✅ Nexus accessible only via Tailscale

**Manual override** (if auto-detection fails):
```properties
NEXUS_HOST=nexus.custom.com  # Override hostname
NEXUS_IP=100.64.123.45       # Override Tailscale IP
```

**Option C: IP Whitelist**

```properties
NEXUS_HOST=nexus.dev.example.com
EXTERNAL_IP=203.0.113.10
NEXUS_ENABLE_IP_WHITELIST=true
# Add IPs to: envs/shared/nexus-whitelist-ips.txt
```

### Step 3: Deploy

```bash
tools/provision-delivery.sh <env-name>
```

Or manually:

```bash
helm install nexus envs/shared/apps/nexus \
  --namespace nexus \
  --create-namespace \
  --set ingress.host=nexus.example.com
```

### Step 4: Access Nexus

**Via Tailscale (recommended):**
```bash
tailscale up
open https://nexus.example.com
```

**Via port-forward (bypasses IP whitelist):**
```bash
kubectl -n nexus port-forward svc/nexus 8081:8081
open http://localhost:8081
```

### Step 5: Get Admin Password

```bash
kubectl -n nexus exec nexus-0 -- cat /nexus-data/admin.password
```

Login with:
- Username: `admin`
- Password: (from above command)

## What Gets Deployed

- **StatefulSet**: Nexus 3.70.1 with 2Gi-4Gi memory
- **PVC**: 50Gi persistent storage for artifacts
- **Service**: ClusterIP on port 8081
- **Ingress**: HTTPS with Let's Encrypt TLS
- **Middleware**: IP whitelist (Tailscale + cluster networks + custom IPs)

## Post-Installation

The provisioning script automatically:
1. ✅ Changes admin password
2. ✅ Creates deployment user (username: `deployment`)
3. ✅ Configures GitHub environment secrets

Credentials are stored in:
- `nexus/nexus-admin-credentials` - Admin password
- `nexus/nexus-deployment-credentials` - Deployment user password

## Accessing Nexus

### Browser Access (UI)

**Requirements**: Must be on Tailscale VPN or whitelisted IP

```bash
# Connect to Tailscale
tailscale up

# Open browser
open https://nexus.example.com
```

### API Access (Maven/Gradle)

**From GitHub Actions runners** (inside cluster):
```xml
<server>
  <id>nexus</id>
  <username>deployment</username>
  <password>${env.NEXUS_PASSWORD}</password>
</server>
```

**From local machine** (via Tailscale or whitelisted IP):
```bash
# Get deployment password
kubectl -n nexus get secret nexus-deployment-credentials \
  -o jsonpath='{.data.password}' | base64 -d

# Configure Maven settings.xml
```

## Troubleshooting

### Can't access Nexus (HTTP 403)

**Cause**: IP whitelist blocking your request

**Solutions**:
1. Connect via Tailscale VPN
2. Add your IP to `envs/shared/nexus-whitelist-ips.txt` and redeploy
3. Use port-forward: `kubectl -n nexus port-forward svc/nexus 8081:8081`

### Pod not starting

```bash
# Check pod status
kubectl -n nexus get pods

# Check logs
kubectl -n nexus logs nexus-0

# Check PVC
kubectl -n nexus get pvc
```

### Certificate issues

```bash
# Check certificate status
tools/debug/check-certificates.sh

# Check cert-manager logs
kubectl -n cert-manager logs -l app=cert-manager
```

## Cleanup

```bash
# Delete everything (including data)
helm uninstall nexus -n nexus
kubectl delete namespace nexus

# Or keep data (delete only Helm release)
helm uninstall nexus -n nexus
# PVC will be retained due to persistentVolumeReclaimPolicy
```

## Next Steps

1. **Configure repositories** - Maven Central proxy, hosted releases/snapshots
2. **Set up blob stores** - Separate storage for different artifact types
3. **Configure cleanup policies** - Automatic deletion of old snapshots
4. **Enable anonymous access** - For public repositories (optional)
5. **Set up LDAP/SAML** - Enterprise authentication (optional)

## References

- [Nexus Documentation](https://help.sonatype.com/repomanager3)
- [Maven Repository Configuration](https://help.sonatype.com/repomanager3/nexus-repository-administration/formats/maven-repositories)
- [Helm Chart README](README.md)
- [Migration Guide](MIGRATION.md)
