# Tenants on a shared cluster

A **tenant** is an organisation whose workloads run as pods on your cluster, in namespaces of
its own, deployed through an Argo CD project of its own. They run on **tenant workers**: nodes
that the operating organisation (you, the ops org) creates in its own cloud project and runs.
The ops org is root on every tenant worker and holds every key: provisioning, SSH, the join
token, the registry credential and the Tailscale identity. **The tenant gets pods only**, never
a node shell.

The isolation primitives below still treat a tenant worker as untrusted. A container escape
there gives root on the node, and that is the threat they answer: a tenant pod that breaks out
must not reach anything of yours. Tenant workloads stay on tenant workers, and yours stay off
them.

## What a tenant can and can't do

| A tenant can | A tenant can't |
| --- | --- |
| Deploy to its own namespaces through its Argo CD project (its repos only) | Log in to any node: no SSH, no console, no kubeconfig with node rights, no access to the cloud project or the tailnet |
| Read its applications' status and logs (the AppProject's `read-only` role) | Create cluster-scoped objects, RBAC, ResourceQuotas, LimitRanges or NetworkPolicies |
| Reach its own Postgres poolers, cluster DNS and the egress listed in its `tenant.properties` | Reach platform services, other tenants' pods, private ranges or node addresses |
| Pull images with its own registry robot | Pull your private images |
| Run CI on its own runner pool, on its own nodes (`tenant-runners.sh`) | Schedule a pod anywhere but its own tenant workers, or tolerate another tenant's taint |
| Use what its quota allows (CPU, memory, pods, PVCs; no LoadBalancer or NodePort) | Run privileged pods outside the opt-in CI case below (Pod Security `restricted`) |

## If a tenant pod escapes to its node

Root on a k3s agent holds the following. Each row is closed by a primitive described below.

| On the node | What it allows | Closed by |
| --- | --- | --- |
| The join token (`/etc/systemd/system/k3s-agent.service.env`) | With the default (server) token: join a **server**, and with it the datastore and every Secret. With any token: register more nodes | `join-worker.sh --tenant` (a bootstrap token, dead after the join) + `infra-skills-node-registration` |
| The kubelet certificate (`system:node:<node>`) | Change its own Node object: labels, taints, status. Read the Secrets of pods bound to the node | NodeRestriction (built in) + `infra-skills-tenant-node-self` + `infra-skills-tenant-pod-placement` (no platform pod is ever bound there) |
| The shared agent certificate (`system:k3s-controller`) | `patch nodes/status` on **every** node (flannel writes its annotations with it); list pods, namespaces and NetworkPolicies cluster-wide | `infra-skills-node-shared-agent-identity` (writes); the reads remain, see below |
| `/etc/rancher/k3s/registries.yaml` | Pull with whatever robot it holds | `join-worker.sh --tenant` writes a tenant-only file |
| The host network | Reach every pod and node address the network allows | `network-policies.sh` (no trust in tenant node addresses), `tenant.sh` (tenant namespaces), `NETPOL_APP_NAMESPACES` (your app namespaces) |
| The node's tailnet identity | Reach what the tailnet policy lets its tag reach | The tailnet policy (INFRA-219): `tag:tenant-<tenant>` reaches only its cluster's 6443/tcp and 8472/udp |

## The primitives

- **The join token.** `join-worker.sh --tenant` joins with a k3s *bootstrap token*
  (`k3s token create --ttl`). The script makes it for this one join and deletes it when the
  run ends. A bootstrap token admits agents only: a server join with it is refused. Once
  deleted, the copy left on the tenant worker can register nothing more: on test it got 401
  where a fresh token got 200 (2026-11-21). The joined agent keeps working through restarts
  on its node password. The server needs no change and no restart. All of this was checked on
  k3s v1.36.4, 2026-11-20. A permanent `agent-token` is the other agent-only option, but only
  on a server installed with one: adding `agent-token` to a running server (config drop-in
  plus restart) makes every k3s start after the first fail with `cred/passwd newer than
  datastore`. That was reproduced on three fresh v1.36.4 servers; servers without it restarted
  cleanly.
- **`tools/k3s/tenant-admission.sh <env>`** installs four ValidatingAdmissionPolicies. They run
  inside the API server, with no webhook to keep alive:
  - `infra-skills-node-registration`: a new node registers only with the taint
    `infra-skills/quarantine=true:NoExecute`. A node named `<tenant>-*` also needs
    `infra-skills/tenant=<tenant>:NoExecute`.
  - `infra-skills-tenant-node-self`: a tenant worker's kubelet may not change its spec (taints)
    or any label other than those the kubelet maintains itself (hostname, os, arch, instance
    type, zone, region).
  - `infra-skills-node-shared-agent-identity`: `system:k3s-controller` may change only
    flannel's annotations. Flannel's `public-ip` must stay one of the node's own addresses.
  - `infra-skills-tenant-pod-placement`: pods in a namespace labelled
    `infra-skills/tenant=<tenant>` must select `node-restriction.kubernetes.io/tenant=<tenant>`
    and tolerate exactly their tenant's taint. Pods anywhere else may not tolerate a tenant
    taint or the quarantine taint, wildcard tolerations included.
    One exception: the node-exporter DaemonSet (`TENANT_NODE_DAEMONSETS`) may tolerate the
    tenant taint, so ops watches tenant workers too.

  `--warn` binds the policies with `[Warn, Audit]`, for a first look at a live cluster.
  `--plan` also lists the existing pods and nodes that the policies would refuse.
- **`tools/k3s/join-worker.sh <env> <tenant>-<n> --tenant <tenant> --ssh-user admin`** joins
  the tenant worker, logging in with the ops org's provisioning key:
  - it joins with a bootstrap token made for this join and deleted when the run ends
    (`--token agent` uses a separate agent token instead, on a server installed with one; the
    server token is refused for a tenant worker);
  - it writes a registries.yaml that holds only the tenant's pull robot
    (`secrets.plain/registry-tenant-<tenant>.yaml`, with `stringData.registry`, `.username`
    and `.password`);
  - it refuses `REGISTRY_HOSTS`: a tenant worker pulls Harbor over the public address, not
    over the tailnet, where its tag gets no 443 on the server;
  - it persists no labels;
  - the node registers with the quarantine taint and the tenant taint;
  - as cluster admin it sets the label `node-restriction.kubernetes.io/tenant=<tenant>`.
    NodeRestriction keeps the kubelet away from that label prefix;
  - it lifts the quarantine only after the node checks out: the expected InternalIP, the tenant
    taint and the tenant label.

  With the registration policy installed, a platform worker also joins quarantined, and the
  quarantine is lifted the same way. `provision-hetzner-cloud.sh` creates the tenant worker
  in the ops org's project and calls this script (docs/HETZNER-CLOUD-TENANT.md).
- **`tools/k3s/network-policies.sh <env>`** works as follows:
  - tenant workers are left out of `platform-allow-from-nodes` and out of the addresses runners
    may reach;
  - the Postgres and MinIO client allows admit only namespaces that are not a tenant's;
  - a tenant reaches only its own poolers (`cnpg.io/podRole=pooler`,
    `infra-skills/tenant=<tenant>`), and MinIO only when listed in `NETPOL_TENANT_MINIO`;
  - `NETPOL_APP_NAMESPACES` gives your own application namespaces default-deny ingress.
    **Set it before the tenant worker joins.** An application namespace without a
    NetworkPolicy is open to a pod that escapes to the tenant worker;
  - it names every other policy in its namespaces that admits ingress from anywhere: such a
    policy overrides the default deny for its pods.
- **`tools/k3s/tenant.sh <env> <tenant>`** builds the namespace scaffold:
  - Pod Security `restricted`;
  - a ResourceQuota (no LoadBalancer or NodePort) and a LimitRange;
  - default-deny ingress and egress, plus egress to DNS, the tenant's poolers and the
    configured feeds (`TENANT_EGRESS`);
  - an Argo CD AppProject with no cluster-scoped resources, no quota, LimitRange,
    NetworkPolicy or RBAC objects, and a `read-only` role for the tenant's groups.

  The settings live in `envs/<env>/tenants/<tenant>/tenant.properties`.
- **`tools/k3s/postgres.sh <env> --provision-credentials <app> --tenant <tenant> --pooler`**
  provisions a tenant's database:
  - one role and one database, with CONNECT and TEMPORARY revoked from PUBLIC;
  - a connection limit (default 20), `statement_timeout` 60s and
    `idle_in_transaction_session_timeout` 5min;
  - a CNPG Pooler labelled for the tenant, which the Secret points at.

  `--revoke-public-connect [--apply]` closes the other databases. Every role may connect to a
  database until PUBLIC's CONNECT is revoked there.
- **`tools/k3s/tenant-runners.sh <env> <tenant>`** runs CI runners for the tenant's GitHub
  organization:
  - in `<tenant>-ci`, only on the tenant's workers;
  - with env only from the Secrets listed in `TENANT_RUNNER_SECRETS` in that namespace;
  - with no service account token;
  - with internet-only egress;
  - without Docker by default: the runner pod is not privileged (Pod Security `baseline`).
    `TENANT_RUNNER_DOCKER=true` adds Docker-in-Docker, which runs **privileged**. Anyone who
    can push a workflow in the tenant's organization then gets root on the tenant worker
    through it. Enable it only when the tenant needs `docker build`, and know that the
    node-level primitives above are then all that stands between that root and your cluster.

## Order

1. Add the tenant to `TENANTS` in env.properties. Run `tenant-admission.sh <env> --plan`, then
   apply it.
2. Set `NETPOL_APP_NAMESPACES` and run `network-policies.sh <env>`.
3. Run `tenant.sh <env> <tenant>`.
4. Run `postgres.sh <env> --provision-credentials <app> --tenant <tenant> --pooler`, and
   `--revoke-public-connect` if needed.
5. Confine `tag:tenant-<tenant>` in the tailnet policy, then create and join the tenant worker:
   `provision-hetzner-cloud.sh` (or `join-worker.sh <env> <tenant>-1 --tenant <tenant>` for a
   machine you made yourself).
6. Set up CI: `tenant-runners.sh <env> <tenant>`.
7. Check, as ops on the tenant worker:
   - with the node's own credentials and `--dry-run=server`, try to remove its taint or add a
     label (kubelet: `/var/lib/rancher/k3s/agent/kubelet.kubeconfig`), and to patch another
     node's status (`client-k3s-controller.crt`). Each must be refused;
   - `tenant-admission.sh <env> --plan` reports nothing.

To roll back, run `tenant-admission.sh <env> --remove`, `network-policies.sh <env> --remove`
and `join-worker.sh <env> <node> --remove`. Removing a tenant's namespaces is deliberately
manual, because they hold its data.

## What remains

- **Reads after an escape.** `system:k3s-controller` lists pods, namespaces and
  NetworkPolicies cluster-wide. A pod that escapes to a tenant worker can therefore read every
  pod spec, including literal env values (never Secret values referenced by `secretKeyRef`).
  Keep credentials out of literal env.
- **Pod networking after an escape.** Flannel VXLAN does not authenticate sources. Root on a
  tenant worker can send packets with a forged source pod IP. Replies go to the real owner, so
  TCP sessions cannot be set up this way, but one-way UDP can be forged. Rewriting another
  node's flannel `backend-data` can disrupt traffic to that node's pods (denial of service,
  not interception: `public-ip` is pinned).
- **Charts' own allow-all policies.** NetworkPolicies add up: a policy that admits ingress
  from anywhere overrides the default deny for its pods. The Argo CD chart's `argocd-server`
  policy is `ingress: [{}]`, so a tenant worker reached argocd-server directly, past Pomerium
  (found on test, 2026-11-21, INFRA-225); Argo CD's own login still applied. `argocd.sh` no
  longer creates that policy (teob-cc/infra-skills#36): re-run it on clusters with chart 10.x.
  `network-policies.sh` names every such policy in its namespaces.
- **The `postgres` database** stays open to every role. It holds no application data.
- **Logs and metrics.** node-exporter runs on tenant workers (INFRA-227): the ops org owns
  the node and watches its disk and memory like any other. Its DaemonSet tolerates the tenant
  taint, and `tenant-admission.sh` lets exactly that DaemonSet do so (`TENANT_NODE_DAEMONSETS`,
  default `observability/prometheus-prometheus-node-exporter`: namespace, service account and
  a DaemonSet owner must all match). It holds no credential and mounts no service account
  token. Prometheus on the cluster server scrapes it over the tailnet on tcp:9100, which the
  tailnet policy must grant from the server's tag to `tag:tenant-<tenant>`. NodeExporterDown
  covers tenant workers like any node. A pod that escapes to root on the node controls what
  that node's node-exporter reports, its textfile metrics included: trust a tenant worker's
  own metrics no more than the node itself. Promtail does not run there: its Loki
  credentials would be on the node, where an escaped pod could take them. The tenant sees its
  own logs and metrics through a tenant console that queries server-side.
- **The tailnet.** The tenant worker carries `tag:tenant-<tenant>` (its Tailscale auth key
  carries the tag). The tailnet policy, segmented by tags (INFRA-219), lets the tag reach only
  its cluster's server on 6443/tcp and 8472/udp. The server may reach the tag on 8472/udp and
  10250/tcp (kubelet: logs and exec), and operators reach it as `autogroup:member`. The policy
  lives outside infra-skills; `provision-hetzner-cloud.sh` checks it before it creates a
  tenant worker. A tailnet still on the default policy (grant `*` → `*:*`, no `tagOwners`)
  confines nothing, and a tag can be minted only once `tagOwners` names it. Confine the tag
  before the node joins. A node whose public :22 is closed sets `SSH_VIA=tailscale` in its
  env.properties.
- **Host firewall.** Where ufw is installed, `join-worker.sh` persists its NAT rules with a
  oneshot unit (`infra-skills-worker-nat.service`) instead of installing iptables-persistent.
  On Ubuntu 24.04 ufw declares `Breaks` on iptables-persistent and netfilter-persistent, so
  installing either would remove ufw.
- **The server token on platform workers.** Without `--token bootstrap`, a platform worker
  still joins with the server token, as before. Root on any such worker can join a server.
  Move platform workers with `join-worker.sh <env> <worker> --token bootstrap`, which takes
  them off the server token.
