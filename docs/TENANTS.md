# Tenants on a shared cluster

A **tenant** is an organisation that runs its own workloads on your cluster: on a node it owns
(a *tenant worker*), in namespaces of its own, deployed through an Argo CD project of its own.
The model assumes **shared root** on the tenant worker: the tenant is root there, and so are
you. The tenant must not reach anything of yours from that node. Its workloads must stay off
your nodes, and yours off its node.

This page explains what root on a k3s agent gives away, and which primitive closes each gap.
It also gives the order to set a tenant up in, and the gaps that remain.

## What root on an agent node holds

| On the node | What it allows | Closed by |
| --- | --- | --- |
| The join token (`/etc/systemd/system/k3s-agent.service.env`) | With the default (server) token: join a **server**, and with it the datastore and every Secret. With any token: register more nodes | `join-worker.sh --tenant` (a bootstrap token, dead after the join) + `infra-skills-node-registration` |
| The kubelet certificate (`system:node:<node>`) | Change its own Node object: labels, taints, status. Read the Secrets of pods bound to the node | NodeRestriction (built in) + `infra-skills-tenant-node-self` + `infra-skills-tenant-pod-placement` (no platform pod is ever bound there) |
| The shared agent certificate (`system:k3s-controller`) | `patch nodes/status` on **every** node (flannel writes its annotations with it); list pods, namespaces and NetworkPolicies cluster-wide | `infra-skills-node-shared-agent-identity` (writes); the reads remain, see below |
| `/etc/rancher/k3s/registries.yaml` | Pull with whatever robot it holds | `join-worker.sh --tenant` writes a tenant-only file |
| The host network | Reach every pod and node address the network allows | `network-policies.sh` (no trust in tenant node addresses), `tenant.sh` (tenant namespaces), `NETPOL_APP_NAMESPACES` (your app namespaces) |

## The primitives

- **The join token.** `join-worker.sh --tenant` joins with a k3s *bootstrap token*
  (`k3s token create --ttl`). The script makes it for this one join and deletes it when the
  run ends. A bootstrap token admits agents only: a server join with it is refused. Once
  deleted, the copy left on the tenant node can register nothing more, and the joined agent
  keeps working through restarts on its node password. The server needs no change and no
  restart. All of this was checked on k3s v1.36.4, 2026-11-20. A permanent `agent-token` is
  the other agent-only option, but only on a server installed with one: adding `agent-token`
  to a running server (config drop-in plus restart) makes every k3s start after the first
  fail with `cred/passwd newer than datastore`. That was reproduced on three fresh v1.36.4
  servers; servers without it restarted cleanly.
- **`tools/k3s/tenant-admission.sh <env>`** installs four ValidatingAdmissionPolicies. They run
  inside the API server, with no webhook to keep alive:
  - `infra-skills-node-registration`: a new node registers only with the taint
    `infra-skills/quarantine=true:NoExecute`. A node named `<tenant>-*` also needs
    `infra-skills/tenant=<tenant>:NoExecute`.
  - `infra-skills-tenant-node-self`: a tenant node's kubelet may not change its spec (taints)
    or any label other than those the kubelet maintains itself (hostname, os, arch, instance
    type, zone, region).
  - `infra-skills-node-shared-agent-identity`: `system:k3s-controller` may change only
    flannel's annotations. Flannel's `public-ip` must stay one of the node's own addresses.
  - `infra-skills-tenant-pod-placement`: pods in a namespace labelled
    `infra-skills/tenant=<tenant>` must select `node-restriction.kubernetes.io/tenant=<tenant>`
    and tolerate exactly their tenant's taint. Pods anywhere else may not tolerate a tenant
    taint or the quarantine taint, wildcard tolerations included.

  `--warn` binds the policies with `[Warn, Audit]`, for a first look at a live cluster.
  `--plan` also lists the existing pods and nodes that the policies would refuse.
- **`tools/k3s/join-worker.sh <env> <tenant>-<n> --tenant <tenant>`** joins the tenant worker:
  - it joins with a bootstrap token made for this join and deleted when the run ends
    (`--token agent` uses a separate agent token instead, on a server installed with one; the
    server token is refused for a tenant);
  - it writes a registries.yaml that holds only the tenant's pull robot
    (`secrets.plain/registry-tenant-<tenant>.yaml`, with `stringData.registry`, `.username`
    and `.password`);
  - it persists no labels;
  - the node registers with the quarantine taint and the tenant taint;
  - as cluster admin it sets the label `node-restriction.kubernetes.io/tenant=<tenant>`.
    NodeRestriction keeps the kubelet away from that label prefix;
  - it lifts the quarantine only after the node checks out: the expected InternalIP, the tenant
    taint and the tenant label.

  With the registration policy installed, a platform worker also joins quarantined, and the
  quarantine is lifted the same way.
- **`tools/k3s/network-policies.sh <env>`** works as follows:
  - tenant nodes are left out of `platform-allow-from-nodes` and out of the addresses runners
    may reach;
  - the Postgres and MinIO client allows admit only namespaces that are not a tenant's;
  - a tenant reaches only its own poolers (`cnpg.io/podRole=pooler`,
    `infra-skills/tenant=<tenant>`), and MinIO only when listed in `NETPOL_TENANT_MINIO`;
  - `NETPOL_APP_NAMESPACES` gives your own application namespaces default-deny ingress.
    **Set it before the tenant joins.** An application namespace without a NetworkPolicy is
    open to the tenant's node.
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
  - in `<tenant>-ci`, only on the tenant's nodes;
  - with env only from the Secrets listed in `TENANT_RUNNER_SECRETS` in that namespace;
  - with no service account token;
  - with internet-only egress.

## Order

1. Add the tenant to `TENANTS` in env.properties. Run `tenant-admission.sh <env> --plan`, then
   apply it.
2. Set `NETPOL_APP_NAMESPACES` and run `network-policies.sh <env>`.
3. Run `tenant.sh <env> <tenant>`.
4. Run `postgres.sh <env> --provision-credentials <app> --tenant <tenant> --pooler`, and
   `--revoke-public-connect` if needed.
5. Join the node: `join-worker.sh <env> <tenant>-1 --tenant <tenant>`.
6. Set up CI: `tenant-runners.sh <env> <tenant>`.
7. Check:
   - from the tenant node, with its own credentials and `--dry-run=server`, try to remove its
     taint or add a label (kubelet: `/var/lib/rancher/k3s/agent/kubelet.kubeconfig`), and to
     patch another node's status (`client-k3s-controller.crt`). Each must be refused;
   - `tenant-admission.sh <env> --plan` reports nothing.

To roll back, run `tenant-admission.sh <env> --remove`, `network-policies.sh <env> --remove`
and `join-worker.sh <env> <node> --remove`. Removing a tenant's namespaces is deliberately
manual, because they hold its data.

## What remains

- **Reads.** `system:k3s-controller` lists pods, namespaces and NetworkPolicies cluster-wide.
  The tenant can therefore read every pod spec, including literal env values (never Secret
  values referenced by `secretKeyRef`). Keep credentials out of literal env.
- **Pod networking.** Flannel VXLAN does not authenticate sources. Root on the tenant node can
  send packets with a forged source pod IP. Replies go to the real owner, so TCP sessions
  cannot be set up this way, but one-way UDP can be forged. Rewriting another node's flannel
  `backend-data` can disrupt traffic to that node's pods (denial of service, not interception:
  `public-ip` is pinned).
- **The `postgres` database** stays open to every role. It holds no application data.
- **Logs and metrics.** Promtail and node-exporter do not run on a tenant node. Promtail would
  hand the tenant its Loki credentials. The tenant sees its own logs and metrics through a
  tenant console that queries server-side.
- **The tailnet.** Tag the tenant node `tag:tenant-<tenant>` (its Tailscale auth key carries
  the tag). In your Tailscale ACL, allow the tag to reach only the server's k3s API (6443/tcp)
  and flannel (8472/udp). The server may reach the tag on 8472/udp and 10250/tcp (kubelet: logs
  and exec), and the operator on 22/tcp. The ACL lives outside infra-skills;
  `provision-hetzner-cloud.sh` documents the snippet. A tailnet still on the default policy
  (grant `*` → `*:*`, no `tagOwners`) confines nothing. A tag can be minted only once
  `tagOwners` names it. Confine the tag before the tenant gets root. A node whose public :22 is
  closed sets `SSH_VIA=tailscale` in its env.properties.
- **Host firewall.** Where ufw is installed, `join-worker.sh` persists its NAT rules with a
  oneshot unit (`infra-skills-worker-nat.service`) instead of installing iptables-persistent.
  On Ubuntu 24.04 ufw declares `Breaks` on iptables-persistent and netfilter-persistent, so
  installing either would remove ufw.
- **The server token on platform workers.** Without `--token bootstrap`, a platform worker
  still joins with the server token, as before. Root on any such worker can join a server.
  Move platform workers with `join-worker.sh <env> <worker> --token bootstrap`, which takes
  them off the server token.
