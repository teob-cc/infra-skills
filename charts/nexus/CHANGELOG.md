# Changelog

All notable changes to the Nexus Helm chart will be documented in this file.

## [1.0.0] - 2025-11-01

### Added
- Initial Helm chart for Nexus Repository Manager
- StatefulSet deployment with persistent storage
- IP whitelisting via Traefik middleware
- Automatic TLS/HTTPS via cert-manager
- Configurable resource limits and JVM tuning
- Health probes (liveness and readiness)
- Support for custom IP whitelist
- Comprehensive documentation (README, MIGRATION, NOTES)

### Features
- **IP Whitelist**: Default ranges for Tailscale and cluster networks
- **Custom IPs**: Load additional IPs from `nexus-whitelist-ips.txt`
- **Ingress**: Traefik ingress with middleware support
- **Storage**: Configurable PVC size and storage class
- **Security**: IP-based access control for browser and API access

### Migration
- Replaced ~200 lines of inline YAML in `provision-delivery.sh`
- Moved all Kubernetes resources to Helm templates
- Simplified provisioning script to ~100 lines
- Added proper versioning and upgrade path

### Configuration
- `values.yaml`: Default configuration with sensible defaults
- Environment-specific overrides via Helm values
- Custom IP whitelist loaded from external file

### Documentation
- `README.md`: Comprehensive usage guide
- `MIGRATION.md`: Migration path from raw manifests
- `CHANGELOG.md`: Version history (this file)
- `NOTES.txt`: Post-install instructions

### Testing
- Helm lint validation
- Template rendering tests
- IP whitelist configuration tests

## Future Enhancements

Planned features for future releases:

- [ ] LDAP/SAML authentication support
- [ ] Default repository configuration via init container
- [ ] Backup/restore job templates
- [ ] Prometheus metrics exporter
- [ ] Custom init scripts via ConfigMap
- [ ] Multi-backend storage support
