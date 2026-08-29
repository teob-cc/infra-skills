# Nexus Repository Manager Helm Chart

This is a local Helm chart for deploying Nexus Repository Manager (OSS) to Kubernetes.

## Features

- **StatefulSet deployment** with persistent storage
- **Optional IP whitelisting** via Traefik middleware (disabled by default)
- **Tailscale DNS support** for secure access without IP management
- **TLS/HTTPS** via cert-manager and Let's Encrypt
- **Resource limits** and JVM tuning for production use
- **Health probes** for liveness and readiness

## Configuration

### Access Control Options

**Option 1: No IP Whitelist (Default)**

By default, IP whitelisting is **disabled**. Nexus is protected by authentication only.

**Option 2: Tailscale DNS (Recommended)**

Use Tailscale MagicDNS to expose Nexus only to your tailnet:

```properties
# In envs/dev/env.properties
HOSTNAME=dev.example.com
NEXUS_ENABLE_IP_WHITELIST=false
```

The provisioning script automatically:
- Generates `NEXUS_HOST=nexus.dev.example.com`
- Detects Tailscale IP (100.x.x.x)
- Creates DNS record pointing to Tailscale IP
- Deploys without IP whitelist

See [Tailscale DNS Setup Guide](../../../docs/TAILSCALE_DNS_SETUP.md) for details.

**Option 3: IP Whitelist**

Enable IP whitelisting for additional security:

```bash
# Enable IP whitelisting
export NEXUS_ENABLE_IP_WHITELIST=true

# Add custom IPs to whitelist file (use your own office/home IP)
echo "203.0.113.10" >> envs/shared/nexus-whitelist-ips.txt

# Deploy
tools/provision-delivery.sh dev
```

Default whitelisted ranges (when enabled):
- `10.0.0.0/8` - Kubernetes pod/service networks
- `172.16.0.0/12` - Kubernetes internal networks
- `192.168.0.0/16` - Private networks
- `100.64.0.0/10` - Tailscale CGNAT range

## Installation

### Clean Install (Recommended)

For a fresh Nexus installation:

```bash
tools/provision-delivery.sh <env-name>
```

The provisioning script will:
1. Load custom IPs from `envs/shared/nexus-whitelist-ips.txt`
2. Generate deployment user credentials
3. Install the Helm chart with environment-specific values
4. Configure Nexus via API (change admin password, create deployment user)
5. Configure GitHub environment secrets

### Manual Installation

```bash
# Install with default values
helm install nexus envs/shared/apps/nexus \
  --namespace nexus \
  --create-namespace \
  --set ingress.host=nexus.example.com

# Install with custom values
helm install nexus envs/shared/apps/nexus \
  --namespace nexus \
  --create-namespace \
  --values my-values.yaml
```

### Migration from kubectl-managed Resources

If you have existing Nexus resources created via kubectl (not Helm), you need to either:

**Option 1: Clean reinstall (data loss)**
```bash
# Delete old resources
kubectl -n nexus delete statefulset nexus
kubectl -n nexus delete service nexus
kubectl -n nexus delete ingress nexus
kubectl -n nexus delete middleware nexus-ip-whitelist
kubectl -n nexus delete pvc nexus-data  # WARNING: Deletes all data

# Install via Helm
tools/provision-delivery.sh <env-name>
```

**Option 2: Migrate existing resources (preserves data)**
```bash
# Use migration script to add Helm labels
tools/migrate-nexus-to-helm.sh nexus

# Then install via Helm
tools/provision-delivery.sh <env-name>
```

## Post-Installation Configuration

The Helm chart only deploys the infrastructure. To configure Nexus:

1. **Get initial admin password:**
   ```bash
   kubectl -n nexus exec nexus-0 -- cat /nexus-data/admin.password
   ```

2. **Access Nexus UI:**
   - Via Tailscale: `https://nexus.<hostname>`
   - Via port-forward: `kubectl -n nexus port-forward svc/nexus 8081:8081`

3. **Change admin password** and create deployment user via UI or API

The `provision-delivery.sh` script automates steps 1-3.

## Values Reference

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Nexus image repository | `sonatype/nexus3` |
| `image.tag` | Nexus image tag | `3.70.1` |
| `resources.requests.cpu` | CPU request | `1` |
| `resources.requests.memory` | Memory request | `2Gi` |
| `resources.limits.cpu` | CPU limit | `2` |
| `resources.limits.memory` | Memory limit | `4Gi` |
| `persistence.enabled` | Enable persistent storage | `true` |
| `persistence.size` | PVC size | `50Gi` |
| `persistence.storageClass` | Storage class | `local-path` |
| `ingress.enabled` | Enable ingress | `true` |
| `ingress.host` | Ingress hostname | `""` |
| `ipWhitelist.enabled` | Enable IP whitelisting | `true` |
| `ipWhitelist.customIPs` | Custom IP addresses/ranges | `[]` |

## Security

### Access Control

**Default Configuration (No IP Whitelist):**
- Nexus is accessible from anywhere
- Protected by username/password authentication
- Suitable for development environments

**Recommended Configuration (Tailscale DNS):**
- Point DNS to Tailscale IP (e.g., 100.64.123.45)
- Only accessible to devices on your tailnet
- No IP whitelist management needed
- See [Tailscale DNS Setup Guide](../../../docs/TAILSCALE_DNS_SETUP.md)

**Optional Configuration (IP Whitelist):**
- Enable via `NEXUS_ENABLE_IP_WHITELIST=true`
- Restricts access to specific IP ranges
- Useful for production with known runner IPs

### Authentication

- **Admin account:** Default username is `admin`, password is auto-generated
- **Deployment account:** Created by provisioning script with `nx-admin` role
- **GitHub Actions:** Use `NEXUS_USERNAME` and `NEXUS_PASSWORD` environment secrets

### Best Practices

1. **Use Tailscale DNS** for admin/developer access
2. **Disable IP whitelist** during initial setup to avoid provisioning issues
3. **Enable IP whitelist** in production if you have static runner IPs
4. **Rotate passwords** regularly via Nexus UI or API
5. **Use LDAP/SAML** for enterprise authentication (optional)

## Troubleshooting

### HTTP 403 Forbidden (Only if IP whitelist is enabled)

If you get HTTP 403 when accessing Nexus with IP whitelisting enabled:
1. Check if IP whitelist is enabled: `kubectl -n nexus get middleware nexus-ip-whitelist`
2. Disable IP whitelist: `NEXUS_ENABLE_IP_WHITELIST=false tools/provision-delivery.sh dev`
3. Or add your IP to `envs/shared/nexus-whitelist-ips.txt` and redeploy
4. Or connect via Tailscale VPN
5. Or use `kubectl port-forward svc/nexus 8081:8081`

### Provisioning hangs at "Waiting for Nexus API"

**Cause**: IP whitelist is blocking the provisioning script

**Solution**: Disable IP whitelist during provisioning
```bash
export NEXUS_ENABLE_IP_WHITELIST=false
tools/provision-delivery.sh dev
```

Then enable it after initial setup if needed.

### Pod not starting

Check pod logs:
```bash
kubectl -n nexus logs nexus-0
```

Check PVC status:
```bash
kubectl -n nexus get pvc
```

### API configuration fails

The provisioning script uses port-forward to bypass IP whitelist during setup.
If it fails, you can manually configure via UI or run:

```bash
kubectl -n nexus port-forward svc/nexus 8081:8081
# Then access http://localhost:8081
```
