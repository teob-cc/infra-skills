# Tenant worker on Hetzner Cloud

A **tenant worker** is a node that runs only one tenant's workloads on your cluster. The *tenant*
is another organisation; you, the *operating org*, run the cluster. This page covers the case where
the node is a Hetzner Cloud VM and the cluster is somewhere else (bare metal or cloud), reached
over Tailscale. The isolation model itself (join token, admission policies, network policies) is in
[TENANTS.md](TENANTS.md).

## Who owns what

The operating org owns the node. The tenant gets pods.

| | Operating org | Tenant |
| --- | --- | --- |
| Hetzner project, billing, console, rescue system, root password reset | yes: the VM is in your project | none |
| Root and SSH on the node | yes: user `admin`, your provisioning key only | no shell, no key on the node |
| Tailscale device, its tag, the tailnet policy | yes | none |
| k3s join, kubelet credentials, registries.yaml | yes, set by `join-worker.sh --tenant` | its pull robot's credentials sit in registries.yaml |
| Workloads | the platform's DaemonSets that tolerate the tenant taint | its pods, in its namespaces, through its Argo CD project |

The tenant has no console or rescue access **by construction**: the VM is not in its Hetzner project,
and no tenant key is ever placed on it. A tenant that wants infrastructure of its own gets its own
envs repo, age key and cluster instead.

The admission policies and network policies still treat the node as untrusted: a container escape
there gives root, and root on an agent holds the kubelet certificate and the node's network.

## Lifecycle

`tools/provision-hetzner-cloud.sh <env> --worker <tenant>-<n>` does the whole lifecycle:

1. **Create**, in your Hetzner project, with your ops token:
   - a firewall that drops all inbound traffic except `udp/41641` (Tailscale direct connections);
   - the server, with that firewall in place from the first boot;
   - cloud-init that creates `admin` with your provisioning key, installs Tailscale and joins the
     tailnet with a one-off auth key tagged `tag:tenant-<tenant>`.

   Every resource carries the labels `managed-by=infra-skills`, `tenant=<tenant>` and
   `node=<tenant>-<n>`. The script refuses to change a server or firewall of that name without all
   three (your project holds other things). The node has no public SSH and no ingress, and gets no
   DNS records.
2. **Provision** over Tailscale as `admin`. The postinstall runs in its `tenant-worker` role: minimal
   packages, ufw (deny inbound except Tailscale and the k3s overlay), swap off, SSH root login off.
   It then reboots the node.
3. **Join** the cluster through `tools/k3s/join-worker.sh <env> <tenant>-<n> --tenant <tenant>`:
   - a bootstrap token, deleted after the join;
   - a registries.yaml that holds only the tenant's credentials;
   - the quarantine and tenant taints, and the tenant label.
4. **Destroy** in reverse:
   - `join-worker.sh --remove` drains the node and deletes it from the cluster;
   - the server and its firewall are deleted, only when they carry all three labels;
   - the node's Tailscale device (hostname and tenant tag) is deleted;
   - EXTERNAL_IP and VLAN_IP are cleared in env.properties.

   Your provisioning SSH key stays registered in the project; other nodes use it too.

`--dry-run` prints every API call: method, URL and body, with user data replaced by its size.
GET calls run when a token is loaded, so the plan shows what already exists. POST, PUT and DELETE
calls are never sent. The SSH steps and the join-worker.sh call are printed and not run.

## Configuration

`envs/<env>/<tenant>-<n>/env.properties`, the same file `join-worker.sh` reads:

```properties
# Tenant worker of <tenant> on cluster <env> (Hetzner Cloud, the operating org's project).
TENANT=symbioen
# The cluster server: its Tailscale IP (k3s API and flannel over the tailnet) and hostname.
MASTER_VLAN_IP=100.x.y.z
MASTER_HOSTNAME=<server hostname>
# Hetzner Cloud: put the node where the cluster server is (fewer Tailscale hops).
HCLOUD_SERVER_TYPE=cx33
HCLOUD_LOCATION=hel1
HCLOUD_IMAGE=ubuntu-24.04
# No REGISTRY_HOSTS: the node pulls from Harbor over public 443, like any client. join-worker.sh
# would pin Harbor to MASTER_VLAN_IP, where the tenant tag is granted no 443; the script refuses it.
# Written by provision-hetzner-cloud.sh (SSH_VIA=tailscale: join-worker.sh skips the closed public :22):
EXTERNAL_IP=
VLAN_IP=
SSH_VIA=tailscale
```

Optional keys:

| Key | Default | Meaning |
| --- | --- | --- |
| `HCLOUD_TOKEN_FILE` | `shared/secrets.plain/hetzner-cloud-token.txt` | Your ops project's token file, relative to `envs/`, when this env's cloud nodes live in another of your projects. The sops copy under `secrets.sops/` is used when the plain file is missing. `HCLOUD_TOKEN` from the environment is never used |
| `TAILSCALE_TAG` | `tag:tenant-<tenant>` | The node's tailnet identity, and the only value allowed: any other tag stops the script before an API call. The auth key is minted with it and the first-boot `tailscale up` passes `--advertise-tags` with it. The same key names a server's or worker's tag elsewhere (provision skill, "Tailnet tag"); `tools/doctor.sh` warns when the device does not carry it |
| `HCLOUD_FIREWALL_NAME` | `<tenant>-<n>` | The node's Hetzner firewall |
| `HCLOUD_FIREWALL_SSH_CIDRS` | empty | Your sources allowed to SSH to the public IP: a break-glass for when Tailscale on the node is down. The Hetzner console of your project is the other way in |
| `TAILSCALE_DENY_TESTS` | empty | Extra `host:port` destinations the tag must not reach, tested with Tailscale's evaluator (below): subnet routes such as a home LAN, which the device list does not show |
| `TAILSCALE_POLICY_CHECK` | refuse | `warn`: create the node even though the tailnet policy check fails (only for a throwaway test tailnet) |

## Tailnet policy

One tailnet can carry several envs and tenants if the policy segments it by tags:

- **operators** (user-owned devices, `autogroup:member`) reach everything;
- **each env's servers** carry an env tag (`tag:env-prod`, `tag:env-test`, ...) and reach only the
  flows they need;
- **a tenant tag** (`tag:tenant-<tenant>`) reaches only its cluster server, on `tcp:6443` (k3s
  supervisor and API) and `udp:8472` (flannel VXLAN). A tenant's nodes may also reach each other on
  `udp:8472`.

With the default policy (`grants: [{src: ["*"], dst: ["*"], ip: ["*"]}]`, or the older `acls`
allow-all) and no `tagOwners`, a tenant node reaches every device on the tailnet on every port, and
its tagged auth key cannot even be minted. Before creating a node, the script reads the policy and
the device list (read-only) and **refuses** when:

- the tag is missing from `tagOwners`;
- a rule whose source can be the node (`*`, the tag, `autogroup:tagged`, `0.0.0.0/0`, a `100.x`
  range wider than /32) reaches anything other than the cluster server on `tcp:6443` or `udp:8472`.
  The cluster server is `MASTER_VLAN_IP`, a `hosts` alias of it, or a tag that **only** the device
  with that address carries. An env tag that workers carry too does not count; use a `hosts` alias;
- nothing grants the tag the server's `tcp:6443` and `udp:8472`: the node could not join;
- an `ssh` rule's source can be the node (Tailscale SSH from the tenant node to anything);
- Tailscale's own evaluator disagrees. The script puts the same questions as tests to
  `POST /api/v2/tailnet/-/acl/validate`, which runs them against the live policy and changes
  nothing: the tag is accepted on the server's tcp:6443 and udp:8472; denied on its 22, 443,
  10250 and 5432; denied on every other tailnet device (the tenant's own nodes aside) on 22, 443,
  6443 and udp:8472; denied on each `TAILSCALE_DENY_TESTS` destination. The evaluator also covers
  what the static reading cannot, such as groups and IP sets.

It **warns** when the evaluator says the server (its first tag, else its address) does not reach
the tag on `udp:8472`, `tcp:10250` and `tcp:9100`: VXLAN, kubelet metrics and node-exporter
scrapes from the server to the node would be dropped. It also warns when the policy has no
`tests` entry for the tag. Destroy and `--provision-only` do not run the check.

The tenant part of a segmented policy, with the prod server tagged `tag:env-prod`:

```jsonc
{
  "tagOwners": {
    "tag:env-prod":         ["autogroup:admin"],
    "tag:tenant-symbioen":  ["autogroup:admin"]
  },
  "grants": [
    // Operators reach everything (tagged devices are not members).
    {"src": ["autogroup:member"], "dst": ["*"], "ip": ["*"]},
    // The tenant node reaches its cluster server's k3s API and flannel, nothing else.
    {"src": ["tag:tenant-symbioen"], "dst": ["tag:env-prod"], "ip": ["tcp:6443", "udp:8472"]},
    // The server reaches the node's flannel, its kubelet (metrics-server, Prometheus) and node-exporter.
    {"src": ["tag:env-prod"], "dst": ["tag:tenant-symbioen"], "ip": ["udp:8472", "tcp:10250", "tcp:9100"]}
  ],
  "tests": [
    {"src": "tag:tenant-symbioen", "accept": ["tag:env-prod:6443"], "deny": ["tag:env-prod:22", "tag:env-prod:5432"]}
  ]
}
```

The rest of the policy (what each env tag reaches) belongs to your tailnet as a whole. Tagging a
device re-authenticates it and makes the tag, not a user, its identity, so roll the env tags out one device at a
time. Run `--dry-run` before every create: it prints the problems it finds.

## What lands on the node

All of it is the operating org's; the tenant receives none of it.

| On the node | What | Lifetime |
| --- | --- | --- |
| Your provisioning SSH **public** key, for user `admin` (and root's, which cloud-init disables) | the only key on the node | until destroy |
| A Tailscale auth key, in user data and in `/run/infra-skills/ts-authkey` | single use, preauthorized, one hour, `tag:tenant-<tenant>` only | spent at first boot; the file and cloud-init's copy are deleted. The provisioner then revokes it by id (`DELETE /api/v2/tailnet/-/keys/<id>`), whether the node enrolled or not, and on any earlier exit. The metadata service (169.254.169.254) keeps serving the key to anything on the node for the server's life, but revoked |
| The node's own Tailscale node key, tagged `tag:tenant-<tenant>` | the node's tailnet identity | until the device is deleted |
| A k3s bootstrap token, in `/etc/systemd/system/k3s-agent.service.env` | agent-only | deleted on the server when join-worker.sh ends |
| `/etc/rancher/k3s/registries.yaml` | the tenant's pull robot | until destroy |
| kubelet client certificate (`system:node:<tenant>-<n>`) | the node's | confined by NodeRestriction and the admission policies (TENANTS.md) |

No platform credential beyond these is placed on the node: no server token, no platform registry
robot, no Hetzner token, no Tailscale API key. They stay on the provisioning machine.

**Residual risk of the auth key in user data.** The key travels in the server's cloud-init user
data, so it sits at rest in the Hetzner project and on the metadata service. A one-off key is
spent once the node joins with it (Tailscale revokes it on use), so the risk is a key nobody
consumed. Until it is revoked or expires, anyone who can read the user data could join one device
as `tag:tenant-<tenant>`, which the policy confines to the cluster server's tcp:6443 and udp:8472.
The provisioner revokes the key by id once the node has enrolled or failed to. It tries three
times, and the EXIT trap tries again on any exit. Revoking does not remove the device that joined.
If the revoke still fails:
- The node enrolled: the key is spent; a warning names its id.
- The node did not enrol: the run exits non-zero and prints the key id and the manual revoke
  (admin console, Settings, Keys).
A dead machine mid-run cannot revoke at all; the one-hour expiry is the backstop. A node that did
not enrol keeps a dead key: `--destroy` it and create it again. Delivering the key after boot over
SSH, instead of in user data, is a separate change.

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
- **Monitoring of the node.** node-exporter runs on tenant nodes (hostNetwork); Prometheus on the
  cluster server scrapes it over the tailnet on `tcp:9100`, and NodeExporterDown covers the node.
  Promtail does not run there: it would need Loki credentials on the node (TENANTS.md). Hetzner's
  CPU, disk and network graphs are in your project's console.
- **Automatic restock.** When `HCLOUD_SERVER_TYPE` is unavailable, the script stops and lists what
  is available instead of choosing a type for you.
- **Billing the tenant.** The node is on your Hetzner invoice; charge it on as you agree with the
  tenant (the `tenant` label lets you find its resources).
