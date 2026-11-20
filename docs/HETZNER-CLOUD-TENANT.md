# Tenant worker on Hetzner Cloud

A **tenant worker** is a node that another organisation (the *tenant*) owns and pays for, and
that runs only that tenant's workloads on your cluster. This page covers the case where the node
is a Hetzner Cloud VM in the **tenant's own Hetzner project**, and the cluster is somewhere else:
bare metal or cloud, reached over Tailscale. The isolation model itself (shared root, join token,
admission policies, network policies) is in [TENANTS.md](TENANTS.md).

`tools/provision-hetzner-cloud.sh <env> --worker <tenant>-<n>` does the whole lifecycle:

1. **Create**, in the tenant's project, with the tenant's API token:
   - a firewall that drops all inbound traffic except `udp/41641` (Tailscale direct connections);
   - the server, with that firewall in place from the first boot;
   - cloud-init that installs Tailscale and joins the tailnet with a one-off tagged auth key.

   The node has no public SSH and no ingress, and gets no DNS records.
2. **Provision** over Tailscale as `admin`. The postinstall runs in its `tenant-worker` role: minimal
   packages, ufw (deny inbound except Tailscale and the k3s overlay), swap off, SSH root login off.
   It then reboots the node.
3. **Join** the cluster through `tools/k3s/join-worker.sh <env> <tenant>-<n> --tenant <tenant>`:
   - a bootstrap token, deleted after the join;
   - a registries.yaml that holds only the tenant's credentials;
   - the quarantine and tenant taints, and the tenant label.
4. **Destroy** in reverse:
   - `join-worker.sh --remove` drains the node and deletes it from the cluster;
   - the server and its firewall are deleted;
   - the node's Tailscale device is deleted;
   - EXTERNAL_IP and VLAN_IP are cleared in env.properties.

   Only resources labelled `managed-by=infra-skills` and `tenant=<tenant>` are deleted.

`--dry-run` prints every API call: method, URL and body, with user data replaced by its size.
GET calls run when a token is loaded, so the plan shows what already exists. POST, PUT and DELETE
calls are never sent. The SSH steps and the join-worker.sh call are printed and not run.

## Configuration

`envs/<env>/<tenant>-<n>/env.properties`, the same file `join-worker.sh` reads:

```properties
# Tenant worker of <tenant> on cluster <env> (Hetzner Cloud, the tenant's own project).
TENANT=symbioen
# The cluster server: its Tailscale IP (k3s API and flannel over the tailnet) and hostname.
MASTER_VLAN_IP=100.x.y.z
MASTER_HOSTNAME=<server hostname>
# Hetzner Cloud: put the node where the cluster server is (fewer Tailscale hops).
HCLOUD_SERVER_TYPE=cx33
HCLOUD_LOCATION=hel1
HCLOUD_IMAGE=ubuntu-24.04
# Ingress hosts (Harbor) pinned to MASTER_VLAN_IP in /etc/hosts, for image pulls (join-worker.sh).
REGISTRY_HOSTS=harbor.<cluster hostname>
# Written by provision-hetzner-cloud.sh (SSH_VIA=tailscale: join-worker.sh skips the closed public :22):
EXTERNAL_IP=
VLAN_IP=
SSH_VIA=tailscale
```

Optional keys:

| Key | Default | Meaning |
| --- | --- | --- |
| `HCLOUD_TOKEN_FILE` | `<env>/secrets.plain/hetzner-cloud-token-<tenant>.txt` | The tenant project's token file, relative to `envs/`. The sops copy under `secrets.sops/` is used when the plain file is missing |
| `TAILSCALE_TAG` | `tag:tenant-<tenant>` | The node's tailnet identity |
| `HCLOUD_FIREWALL_NAME` | `<tenant>-<n>` | The node's Hetzner firewall |
| `HCLOUD_FIREWALL_SSH_CIDRS` | empty | Sources allowed to SSH to the public IP: a break-glass for when Tailscale on the node is down. The Hetzner console is the other way in |
| `TAILSCALE_POLICY_CHECK` | refuse | `warn`: create the node even though the tailnet policy check fails (only for a throwaway test tailnet) |

**The tenant's token.** The tenant creates a *Read & Write* API token in its own project
(Hetzner console, then Security, then API Tokens). It gives you that token, and you store it as
`envs/<env>/secrets.plain/hetzner-cloud-token-<tenant>.txt`, encrypted with
`tools/sops/encrypt.sh <env> hetzner-cloud-token-<tenant>.txt`. The script never uses the shared
token (`envs/shared/secrets.plain/hetzner-cloud-token.txt`) or an `HCLOUD_TOKEN` from the
environment for a tenant worker. It refuses a tenant token file that holds the shared token.

## Tailnet policy

The node is isolated on the tailnet only if the tailnet policy confines its tag. With the default
policy (`grants: [{src: ["*"], dst: ["*"], ip: ["*"]}]`, or the older `acls` allow-all), the
tenant's node reaches every device on your tailnet, on every port. Before creating a node, the
script reads the policy and refuses when either of these holds:

- the tag is missing from `tagOwners`;
- a rule lets `*` or the tag reach `*`.

The node needs:

- **tenant node to cluster server**: `tcp:6443` (k3s supervisor and API) and `udp:8472` (flannel VXLAN);
- **cluster server to tenant node**: `udp:8472`. kubelet `tcp:10250` goes through the agent's own tunnel to 6443;
  grant it anyway if you reach kubelets directly;
- **operators to tenant node**: `tcp:22`, for the provisioning SSH.

A policy that keeps every existing device's reach, assuming all of them are user-owned today, and
confines the tenant:

```jsonc
{
  "tagOwners": {
    "tag:tenant-symbioen": ["autogroup:admin"]
  },
  "hosts": {
    "k3s-prod": "100.x.y.z"
  },
  "grants": [
    // What "*" -> "*" gave before, now from user-owned devices only (tagged devices are not members).
    {"src": ["autogroup:member"], "dst": ["*"], "ip": ["*"]},
    // The tenant node reaches the cluster server's k3s API and flannel, nothing else.
    {"src": ["tag:tenant-symbioen"], "dst": ["k3s-prod"], "ip": ["tcp:6443", "udp:8472"]}
  ],
  "tests": [
    {"src": "tag:tenant-symbioen", "accept": ["k3s-prod:6443"], "deny": ["k3s-prod:22", "k3s-prod:5432"]}
  ]
}
```

Check what the `tests` block covers, and run `--dry-run` before every create: it prints the policy
problems it finds. If the cluster server is itself a tagged device, put its tag in the second
grant's `dst`, and grant that tag the reach `*` had.

## What lands on the node

| On the node | Whose | Lifetime |
| --- | --- | --- |
| The operator's SSH **public** key, for user `admin` | yours, public | until destroy |
| A Tailscale auth key, in user data and in `/run/infra-skills/ts-authkey` | yours | single use, one hour. Spent at first boot; the file and cloud-init's copy are deleted. The metadata service (169.254.169.254) keeps serving the spent key to anything on the node |
| The node's own Tailscale node key, tagged `tag:tenant-<tenant>` | the node's | until the device is deleted |
| A k3s bootstrap token, in `/etc/systemd/system/k3s-agent.service.env` | yours | deleted on the server when join-worker.sh ends; agent-only even before that |
| `/etc/rancher/k3s/registries.yaml` | the tenant's pull robot | until destroy |
| kubelet client certificate (`system:node:<tenant>-<n>`) | the node's | confined by NodeRestriction and the admission policies (TENANTS.md) |

No platform credential is placed on the node: no server token, no platform registry robot, no
Hetzner token, no Tailscale API key. The provisioning machine uses the tenant's Hetzner token and
your Tailscale API key, and they stay there.

## Size for evse-ts (2026-11-20)

The node runs evse-ts after its P4 cutover. Postgres is on Databricks Lakebase (EVSE-63), and
the comparator and the ingestion diff are gone. Figures from prod on 2026-11-20:

| Container | Request | Limit | Live |
| --- | --- | --- | --- |
| evse-ts app | 3 GiB, 1 CPU | 4 GiB | 1.37 GiB, 0.02 CPU |
| evse-ts ingest | 256 MiB, 0.05 CPU | 512 MiB | 0.16 GiB |
| **Sum** | **3.25 GiB, 1.05 CPU** | **4.5 GiB** | **1.5 GiB** |

On top of that, the k3s agent, containerd, Tailscale and the OS take about 0.8 GiB. A replay
(EVSE-39) runs heavier than live operation, up to the 4 GiB limit.

**Recommendation: CX33 in hel1.** It has 4 shared vCPU (x86), 8 GB RAM and 80 GB NVMe, at
EUR 8.49/month net plus EUR 0.50 for the IPv4 address, EUR 8.99 in all (traffic: 20 TB
included). The limits sum to 4.5 GiB plus about 0.8 GiB of system, about 70% of 7.6 GiB, which
leaves room for a replay. CX23 (4 GB) cannot hold the 3 GiB request plus the system. hel1 is
where the cluster server is.

- **CX33 is out of stock.** On 2026-11-20 the API reports CX33, CX43 and CX53 as `available: false`
  in fsn1, nbg1 and hel1, and hetzner.com shows "currently unavailable". The script checks
  availability before it creates anything and lists what is available. While CX33 is out,
  **CPX32 in hel1** has the same 4 vCPU and 8 GB (AMD, 160 GB) at EUR 29.99 + 0.50/month.
  Switch back once CX33 is in stock.
- **If Postgres moves onto the node** (the Lakebase spike fails), size up to CX43 (8 vCPU, 16 GB,
  160 GB, EUR 15.99 net) and add a Hetzner volume for the data.
- **CI** stays on GitHub-hosted runners: a runner with its Docker daemon wants about 4 GiB and
  does not fit next to evse-ts on 8 GB.

Sources:

- the Hetzner Cloud API, `GET /v1/server_types` and `GET /v1/pricing`, read 2026-11-20. Prices are
  net, EUR, per location; per-location availability is under `server_types[].locations[].available`;
- hetzner.com/cloud/cost-optimized and /cloud/regular-performance: "€ 8.99 per month, excl. VAT"
  for CX33 and "€ 30.49" for CPX32 in HEL1, both "incl. IPv4";
- docs.hetzner.cloud/changelog: 2026-04-01 (per-location `available` and `recommended`) and
  2026-10-01 (`/datacenters` returns 410).

## Not covered

- **The tailnet policy** is yours to change, in the Tailscale admin console (above). infra-skills
  only checks it.
- **Monitoring of the node.** Promtail and node-exporter do not run on tenant nodes (TENANTS.md).
  Hetzner's own CPU, disk and network graphs are in the tenant's console.
- **Automatic restock.** When `HCLOUD_SERVER_TYPE` is unavailable, the script stops and lists what
  is available instead of choosing a type for you.
