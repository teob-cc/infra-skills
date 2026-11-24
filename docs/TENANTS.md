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
  database until PUBLIC's CONNECT is revoked there. For an app whose data already exists, or
  that runs its migrations under a role of their own, see "A tenant's databases" below.
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

## A tenant's databases

Without more flags, `postgres.sh --provision-credentials <app> --tenant <tenant>` creates an
empty database named `<app>`, owned by a new role `<app>`, and writes `POSTGRES_*` keys into the
Secret `<app>-db`. An app that brings its own data, reads several databases, or keeps its
migrations off the runtime role needs the flags below. For example, an event-sourced app with a
journal database and a read-model database, a manifest database that does not exist yet, and
migrations that must not hit the 60 s timeout:

```bash
tools/k3s/postgres.sh <env> --provision-credentials evse-ts --tenant symbioen --pooler \
  --database evse:JOURNAL_DB --database evse_ts:STATE_DB \
  --database evse_archive:MANIFEST_DB --create-missing \
  --migration-role --connection-limit 32
```

This gives the role `evse-ts` rights on the three databases and writes, into the Secret
`evse-ts-db` in namespace `symbioen`, `JOURNAL_DB_HOST/PORT/DATABASE/USERNAME/PASSWORD`, the same
five keys under `STATE_DB_` and under `MANIFEST_DB_`. The host is the Pooler. The role
`evse-ts_migrate` gets the Secret `evse-ts-db-migrate` with the same keys, for a migrate Job.

| Flag | What it does |
| --- | --- |
| `--database <name>[:<PREFIX>]` | Repeatable. Use these databases instead of creating `<app>`. With a prefix, the Secret gets `<PREFIX>_HOST`, `_PORT`, `_DATABASE`, `_USERNAME` and `_PASSWORD` for that database; without one, `POSTGRES_*` (at most one database can go without). A database that does not exist is an error. |
| `--create-missing` | Create a named database that does not exist yet, owned by the migration role if there is one, else by the app role. PUBLIC's CONNECT is revoked on it, as on the default path. The intent is recorded in `infra_skills.create_intent` first: if the run stops after creating the database, the next run with `--create-missing` finishes it (PUBLIC's CONNECT revoked, grants) instead of taking it for an existing one. |
| `--revoke-public` | Revoke PUBLIC's CONNECT and TEMPORARY on the named databases. Needs `--keep-connect`. Off by default. |
| `--keep-connect <role>[,<role>]` | With `--revoke-public`: the roles, besides the owner, that keep CONNECT (`none` for no other role). |
| `--take-ownership` | Move each named database to the migration role (or the app role): the old owner's objects in it, then the database, in one transaction, then a check. Never its other databases or tablespaces. Off by default. |
| `--migration-role [name]` | A second login role, `<app>_migrate` unless named, with its own Secret `<app>-db-migrate`. |
| `--migration-schema <db>.<schema>` | Repeatable. A schema the migration role owns (created if missing, its owner changed if not). The role gets CREATE on that database. |
| `--migration-connection-limit N` | That role's connection limit (default 2, or `PG_MIGRATION_CONNECTION_LIMIT`). |
| `--connection-limit N` | The app role's connection limit (tenant default 20); -1 to 2147483647. |
| `--keep-password` | Keep the passwords in `secrets.plain/<app>-db.secret.yaml` and `<app>-db-migrate.secret.yaml`. A role that exists keeps its password untouched, and the stored password must match the role's verifier in the cluster, checked at the start and again right before the Secret is written and applied; otherwise the run stops and leaves the Secret as it is. A missing role is created with the password from the file. |

**Which roles the script uses.** It reuses an existing role only when it made that role for
this app: `COMMENT ON ROLE` holds the marker `infra-skills:app:<app>` or
`infra-skills:migrate:<app>`. An unmarked app role (made by the default path before the marker)
is adopted and marked only when all of this holds: it has LOGIN, it owns the database `<app>`, it
has no elevated attribute, and it has no role membership at all, in either direction (it belongs
to no role and no role belongs to it). Otherwise the run stops; there is no flag to force it, so
an existing app's re-runs keep working unchanged. These checks run on every path, the plain
default one (no new flags) included. The script refuses:

- reserved names: `postgres`, `app` (CNPG's owner), `streaming_replica`,
  `cnpg_pooler_pgbouncer`, `PG_READONLY_ROLE`, `public`, `none` and every `pg_*` name. This also
  applies to the app id;
- an existing role that is a superuser, has CREATEROLE, CREATEDB, REPLICATION or BYPASSRLS, or
  belongs to a role that does or to a `pg_*` role;
- an app role and a migration role that are members of one another, directly or through a group;
- an existing role without this app's marker that is not adoptable as above. If it really is the
  app's role, mark it by hand with the `COMMENT ON ROLE` the error message prints.

Nothing changes before these checks pass. Then each role is written in one transaction: it locks
`pg_authid` and `pg_auth_members` (no role can be created, altered or granted until it commits;
it waits at most 5 s for that lock), checks all of the above again against the role's oid from the
preflight, and only then creates the role if missing, writes its marker and sets its password. A
role that changed in between (dropped, made again, elevated, given a membership) stops the run
with its password untouched.

**Grant mode** is the default for `--database`. Each database keeps its owner, and the app role
gets:

- CONNECT and TEMPORARY on the database. The pooler role and (not for a tenant)
  `PG_READONLY_ROLE` get CONNECT. PUBLIC keeps its CONNECT. The run prints a warning that
  lists the login roles that reach the database only through PUBLIC, and those connected now.
- In every schema except `pg_*` and `information_schema`: USAGE and CREATE on the schema;
  SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER on all tables; USAGE, SELECT
  and UPDATE on all sequences.
- Default privileges for the database owner and each schema owner (superusers aside), so the
  tables and sequences they create later are the app role's too.

**`--revoke-public --keep-connect <roles>`** closes the database. First, CONNECT goes to the
owner, the former owner (after `--take-ownership`), the `--keep-connect` roles,
`PG_READONLY_ROLE` (for a tenant too: it reached the database through PUBLIC until then) and
the pooler role. Then PUBLIC's CONNECT and TEMPORARY are revoked. If a kept role or the
read-only role does not exist, the run stops before anything is revoked. The warning names the
roles that lose CONNECT.

With `--pooler`, a run that closes PUBLIC on any database (the default path, a
`--create-missing` database, `--revoke-public`) waits up to 60 s for the Pooler's auth role
`cnpg_pooler_pgbouncer`. If the role is still missing, the run stops before any SQL; otherwise
the role gets CONNECT on the database first.

Grant mode never changes the existing tables' owner, so DDL on those tables (ALTER, an index,
DROP) still needs their owner. When the migrations must change existing tables, use
`--take-ownership`.

**`--take-ownership`** moves ownership instead, database by database, and only inside the named
databases. It does not use `REASSIGN OWNED BY`, which moves *every* database and tablespace the
old owner has, in the whole cluster: the old owner's other databases and its tablespaces are
never touched. The move is refused when the old owner is a superuser or a `pg_*` role. Once the
preflight has passed, and before anything moves, the run records each database's oid, the owner
the preflight saw and the destination role in `infra_skills.ownership_transfer`. That table lives
in the `postgres` database, PUBLIC cannot read it, and the script makes it on first use. The
preflight first checks, from the catalogs alone, that the schema and its tables belong to the
superuser the script runs as, that they are plain tables and have the expected columns; only
`--take-ownership` then reads `ownership_transfer`. Then, per database, in one transaction inside
that database, with `lock_timeout` 5 s and `statement_timeout` 60 s (a lock another session holds
fails the move fast, with nothing changed):

1. `ALTER ... OWNER` for each of the old owner's objects in that database: schemas; tables,
   partitions, views, materialized views, sequences (those of a column follow their table),
   foreign tables and composite types; functions, procedures and aggregates; types, domains,
   enums, ranges and multiranges (array types follow); large objects. Its default privileges are
   copied to the new owner (its own entries stay). Extensions stay with the old owner, with a
   warning: Postgres has no `ALTER EXTENSION ... OWNER`;
2. `LOCK TABLE pg_catalog.pg_database IN SHARE ROW EXCLUSIVE MODE`, as late as possible: until
   the move commits, no other session can run `ALTER DATABASE ... OWNER` or `CREATE DATABASE`
   (they need ROW EXCLUSIVE on `pg_database`; checked on PG14);
3. a check, under that lock, against the ledger row: the database's oid, the old and new
   role's oids, and the live owner, which must be the recorded old owner (or already the new
   one, when an earlier run's move committed but was not marked done). An owner changed by hand
   since the move started rolls the transaction back and fails the run;
4. `ALTER DATABASE ... OWNER`, then CONNECT and TEMPORARY again for the old owner and the app
   role (`ALTER DATABASE ... OWNER` hands the old owner's own ACL entries to the new owner);
5. a check that no object in the database still belongs to the old owner (default privileges
   and extensions aside; the message names the kinds left, to move by hand), else the whole move
   rolls back;
6. commit, and the ledger row is marked done.

If a run stops halfway, the next run with the same destination reads the recorded owner and
completes the move, even when the database already shows the new owner. A run with another
destination (for example without `--migration-role` this time), or one where the database's
owner was changed by hand in between, is refused before any change. Objects owned by other roles
keep their owner.

**The migration role** has:

- no `statement_timeout` and no `idle_in_transaction_session_timeout`, while the app role keeps
  60s and 5min;
- its own small connection limit, on top of the app role's;
- explicit grants in the named databases only: CONNECT and TEMPORARY, and the same schema,
  table and sequence rights as the app role, plus default privileges from the database owner,
  the schema owners and the app role. Neither role may be a member of the other, by any path (the
  run refuses that), so the app role's rights in other databases don't reach it;
- the schemas named with `--migration-schema`: it owns them, and it has CREATE on their
  database, so it can create more schemas there. The app role gets USAGE, CREATE and DML on them.

Whatever the migration role creates is its own. Default privileges
(`ALTER DEFAULT PRIVILEGES FOR ROLE <app>_migrate ... TO <app>` in each database: DML on tables;
USAGE, SELECT and UPDATE on sequences; USAGE on schemas) give the app role its rights on those
objects the moment they exist, so a migrate Job needs no grants of its own. The app role cannot
alter or drop them. Default privileges cover only objects the migration role creates itself;
after a `SET ROLE` to another role, objects belong to that role.

The migration role cannot ALTER or DROP objects other roles own: the app role's tables (on the
default path the app role owns its database and everything it created) or an old owner's.
Nothing hands them over automatically. To let the migration role change existing objects, move
them with `--take-ownership` once:

```bash
tools/k3s/postgres.sh <env> --provision-credentials <app> --database <app> --take-ownership --migration-role
```

The run prints this hint whenever a migration role is set without `--take-ownership`.

The app role keeps CREATE on its schemas, so an app that still runs migrations on its runtime
pool keeps working (owner decision 2026-11-23, INFRA-243). Moving them to a migrate Job with the
`-db-migrate` Secret is the goal.

**The connection limit counts per role**, across all its databases and through the Pooler. In
session mode every client connection holds a server connection. Add up the pool sizes of every
process that uses the role (one pool per database, plus LISTEN connections and leases) and set
`--connection-limit` above that total. The Pooler's `default_pool_size` follows the limit.

**Re-runs** are safe: every statement is guarded or idempotent, and nothing that exists is
dropped. A re-run sets new passwords and rewrites the Secrets, so the app's pods need a restart
afterwards. With `--keep-password` an existing role's password is not touched and the Secrets get
the stored one. The run stops if a file has no usable password (decrypt it from `secrets.sops`
first) or if its `*_PASSWORD` values differ. A password is at least 24 characters. If openssl
fails, the run stops before any SQL.

**One run per app at a time.** Runs for the same app are not serialized: there is no lock across
runs. Two at once (two operators, or a CI job next to a manual run) are not supported; their
passwords and Secrets can cross. The checks above catch the cases that matter most (a password
rotated during a `--keep-password` run, a role or owner changed between the preflight and the
change), but they are no substitute for running one at a time.

**Passwords never reach the server in plaintext**, on any path. The script computes a
SCRAM-SHA-256 verifier on the client (`tools/k3s/pg-scram.pl`, core Perl: macOS's `/usr/bin/perl`
or the runner image's) and sends `ALTER ROLE ... PASSWORD 'SCRAM-SHA-256$4096:...'`, which
Postgres stores as it is. So no log setting (`log_statement`, `log_min_duration_statement`,
sampled logging, error statements) can show a password; at most a verifier. The plaintext goes
only into the Secret file. It never appears on a command line, and with `bash -x` it is not in the
trace either. Secrets are never exported: the script turns allexport off, and its secret
variables are declared `+x` (bash locals otherwise inherit an export from the caller's
environment), so no child process (kubectl, openssl, perl, yq) sees one in its environment. The password statement still runs with `log_statement` off. Connection limits and
timeouts are range-checked before any SQL, and the limit keeps the spelling it was given.

What the script does not do: it doesn't change the app's chart or settings. Key names the chart
reads beyond these five per database (for example a second journal database's name) belong in
the app's own configuration.

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
8. Optionally, give the tenant an email alias: set `TENANT_EMAIL_FORWARD_LIKE` or `TENANT_EMAIL_TO`
   in tenant.properties and re-run `tenant.sh <env> <tenant>` (see "Tenant email alias").

To roll back, run `tenant-admission.sh <env> --remove`, `network-policies.sh <env> --remove`
and `join-worker.sh <env> <node> --remove`. Removing a tenant's namespaces is deliberately
manual, because they hold its data.

## Tenant email alias

A tenant often needs an address of its own for service accounts it holds through you: a data
platform workspace, a cloud console, a status page. Sign these up with a tenant alias such as
`<tenant>@<MAIL_DOMAIN>`, not with a person's address, so the account survives people leaving
and the mail reaches whoever you route it to.

`tools/cloudflare/email-route.sh` manages such aliases as Cloudflare Email Routing rules
(forward only; Cloudflare receives the mail for `MAIL_DOMAIN`):

```bash
tools/cloudflare/email-route.sh <env> --list
tools/cloudflare/email-route.sh <env> acme --forward-like ops --dry-run   # acme@ forwards like ops@
tools/cloudflare/email-route.sh <env> acme --to ops-team@example.com     # a verified destination
tools/cloudflare/email-route.sh <env> acme --remove
```

- **Settings** in `envs/<env>/env.properties`: `MAIL_DOMAIN` (the zone), and optionally
  `CLOUDFLARE_EMAIL_TOKEN_FILE` (a file holding only the token; default: the token in
  `shared/secrets.plain/cloudflare.yaml`) and `CLOUDFLARE_EMAIL_ZONE_ID`. The token needs
  *Zone / Email Routing Rules: Edit*.
- **Idempotent.** A rule for the alias with the same destinations is a no-op. A rule with other
  destinations is reported and left alone.
- **Verified destinations only.** Cloudflare delivers only to destination addresses verified on
  the account. With *Email Routing Addresses: Read* on the account the script checks that list.
  A token scoped to the zone cannot read it; then a destination counts as verified only when an
  enabled rule of the zone already forwards to it, and anything else is refused. Add new
  destinations in the Cloudflare dashboard (Email Routing, Destination addresses).
- **From tenant.sh.** With `TENANT_EMAIL_FORWARD_LIKE=<alias>` (or `TENANT_EMAIL_TO=<address>`)
  in `tenants/<tenant>/tenant.properties`, `tenant.sh` creates `<tenant>@<MAIL_DOMAIN>`
  (`TENANT_EMAIL_ALIAS` changes the local part). `--plan` and `--dry-run=server` show the call
  without making it; `--skip-email` leaves it out.
- The alias forwards to you, the operating org. Forwarding it to the tenant's own people is a
  choice per tenant; it gives them the password resets of the accounts signed up with it.

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
