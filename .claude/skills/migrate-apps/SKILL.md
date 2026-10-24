---
name: migrate-apps
description: Move running ArgoCD-managed apps, with their Postgres data, secrets, images, routes and DNS, from one environment to another with a short write freeze and no data loss. Use when an environment must be emptied (hardware failure, reprovision, decommission) or apps change homes, including across envs repos and GitHub orgs.
argument-hint: "<source-env> <target-env>"
---

# Migrate apps between environments

The apps keep their public hostnames; DNS moves at the end. Data is copied twice: a full copy while
the source keeps serving, then, during a short freeze, only what changed. `tools/migrate-apps.sh`
does the data, freeze and DNS work from a plan file. The GitOps changes on the target are yours to
make, because only you can tell which chart defaults still point at the source.

Every mutating phase of the tool first prints what it will do and stops; it acts only with `--yes`.
Run each phase without `--yes` first and read the output.

## Before you start

1. Both environments are provisioned and reachable from this machine. Each has a kubeconfig under its
   envs root. When the envs roots differ (two envs repos, two orgs), export `SRC_ENVS_ROOT` and
   `DST_ENVS_ROOT`.
2. Ask the user, and record the answers where the work is tracked:
   - Which apps move, and which source-only data is dropped rather than moved.
   - Keep the hostnames and move DNS, or new hostnames? This skill assumes they are kept.
   - Freeze timing: right after the first copy is verified (more slack to roll back), or at a
     fixed time.
   - When the target belongs to another GitHub org, may the target's Dex admit the source org?
     The apps' group policies (`<org>:<team>`) then keep working unchanged.
3. Measure the path between the clusters. The data streams through this machine, so test
   throughput in both directions (pipe a few hundred MB of random data through `kubectl exec`).
   Divide the largest database's compressed dump by the slower direction. On a laptop, run
   long copies under `caffeinate` (macOS) or keep the machine from sleeping.

## Step 1 — Plan and inventory

Write the plan file next to the target env, for example `envs/<target>/migrations/<name>.yaml`.
It holds no secrets.

```yaml
source: <source-env>
target: <target-env>
apps: [shop, dashboard]                  # ArgoCD Application names on the source
extraWorkloads:                          # parent-owned raw manifests that belong to the apps
  - CronJob/default/shop-scheduler-tick
postgres:
  source: {namespace: postgres, cluster: postgres-cluster}
  target: {namespace: apps, cluster: apps-postgres}
databases:
  - name: shop
    passwordFrom: {namespace: default, secret: shop-db, key: POSTGRES_PASSWORD}
  - name: dashboard                      # append-only event journal: copied once, topped up at the freeze
    passwordFrom: {namespace: default, secret: dashboard-db, key: POSTGRES_PASSWORD}
    journal: {table: journal, ordering: ordering}
secrets:
  - {from: default, to: default, names: [shop-db, shop-api-keys, dashboard-db]}
secretRewrites:
  - {namespace: default, secret: shop-db, key: POSTGRES_HOST, value: apps-postgres-rw.apps.svc.cluster.local}
volumes:                                 # non-Postgres state, copied at the freeze
  - {source: {namespace: default, pvc: data-shop-minio-0},
     target: {namespace: default, pvc: data-shop-minio-0, statefulset: shop-minio}}
hosts: [shop.example.com, www.shop.example.com, dashboard.prod.example.com]
```

Run `tools/migrate-apps.sh <plan> inventory`. It lists each app's workloads, images, referenced
Secrets, PVCs, ingress hosts and the Pomerium routes to its Services, plus database sizes. It flags:

- `!` **resources that render into a namespace other than the Application's.** The chart pins it, so
  the target must use that namespace too.
- `!` **NetworkPolicies whose egress names the source Postgres.** On the target they silently block
  the new database: the pod's pool times out, it does not get an auth error.
- `?` **CronJobs and Deployments named after an app but owned by the parent app-of-apps.** Add the
  ones that belong to the app to `extraWorkloads`, or `freeze` leaves them running against the source.

Use a `journal` entry only for a table that is append-only, has a unique key, and has a
monotonically increasing ordering column (event-sourcing journals). Everything else is re-copied
in full at the freeze, so keep large mutable tables in mind when estimating the freeze.

## Step 2 — Target platform

- **Postgres:** a CNPG cluster on the target with the same major version and operand image as the
  source, sized for the biggest database plus its indexes. During a bulk restore, raise
  `maintenance_work_mem` and `max_wal_size`.
- **Certificates:** if the hosts' DNS zones are not in the target's Cloudflare token, add a
  ClusterIssuer that uses the source org's token (DNS-01). Certificates for the kept hostnames
  then issue before DNS moves.
- **Dex:** if the target is in another org, set `DEX_GITHUB_EXTRA_ORGS="<source-org>"` in the
  target's env.properties and run `tools/k3s/identity.sh <target>`. On an existing Dex this calls
  `provision::dex_ensure_github_orgs`, which adds the org to the live connector without touching
  the static clients. The source org may restrict third-party OAuth apps; if so, an org owner has
  to grant the target's OAuth app access, or members cannot sign in to the admin routes.

## Step 3 — Artifacts, secrets, roles, first copy

```bash
tools/migrate-apps.sh <plan> artifacts --yes   # images + OCI chart deps, digests preserved
tools/migrate-apps.sh <plan> secrets --yes     # metadata stripped; never prints values
tools/migrate-apps.sh <plan> roles --yes       # owner roles keep their source passwords
tools/migrate-apps.sh <plan> copy --yes        # small DBs streamed; journal DBs dumped into the
                                               # target volume and restored there with -j
tools/migrate-apps.sh <plan> status            # follow the detached restores
```

- **secrets:** a Secret that already exists on the target with different data, and not from a
  migration, is skipped and reported. Resolve each one by hand, never by overwriting.
- **artifacts:** the app repos' CI keeps building for the source registry until you repoint it.
  The target's values must name the target registry.
- **copy:** a journal restore runs inside the target cluster and survives this machine sleeping.
  Indexes created on the source after the dump are missing on the target: compare `pg_index`
  on both sides and create the missing ones before the freeze, because building them during the
  delta blocks its inserts.

## Step 4 — GitOps tree on the target

For each app, copy its directory and Application from the source envs repo into the target's,
then rewrite:

- **Registry host:** the source Harbor becomes the target Harbor, and so do chart dependencies'
  `repository`. Also check every values key the chart defaults to the source registry. A digest-only
  image with a chart-default repository keeps pulling from the source until it is overridden.
- **Namespace and backends:** the Application destination, raw manifests (CronJobs, NetworkPolicies),
  and the `<svc>.<ns>.svc` names inside them and in the routes.
- **Database peers** in chart NetworkPolicies: point them at the target CNPG cluster's namespace and
  `cnpg.io/cluster` label.
- **Cert issuer annotations,** including the ones that come from chart values, not just the
  ingresses you copied.
- **Hold every app with side effects at 0 replicas, and suspend its CronJobs.** That covers anything
  that writes to the journal, sends mail, bills, or long-polls a bot token. A second live copy
  double-writes or fights the source for the Telegram poll. Stateless apps may run.
- **Routes:** append the source's routes for the apps to the target's `pomerium-routes.yaml`, with
  backends rewritten. Apply them with `tools/k3s/apply-pomerium-routes.sh <target>` from an up-to-date
  checkout (routes are last-writer-wins).

Push, then wait until ArgoCD shows the apps Synced. Then smoke-test every host against the target
before DNS moves:

```bash
curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' --resolve <host>:443:<target-ip> https://<host>/
```

## Step 5 — Freeze, delta, verify

Confirm with the user before the freeze unless they already approved it.

```bash
tools/migrate-apps.sh <plan> freeze --yes   # ArgoCD auto-sync off FIRST, then Deployments to 0,
                                            # CronJobs suspended; state saved for rollback
tools/migrate-apps.sh <plan> delta --yes    # journal rows above the watermark (minus --margin),
                                            # everything else re-copied, sequences, volumes
tools/migrate-apps.sh <plan> verify         # exact per-table counts and journal max, both sides
```

- **freeze** removes ArgoCD auto-sync from the apps and from their parent before scaling. An
  automated sync of any pending commit otherwise restores the replicas within seconds, and the
  source keeps writing during the delta. Freeze refuses to run twice: a second run would record
  the zeros as the originals.
- **delta** uses the target's restored `max(ordering)` minus `--margin` (default 200000) as the
  watermark, and inserts with `ON CONFLICT DO NOTHING`. The margin covers transactions that were
  still uncommitted when the first dump took its snapshot.
- **verify** must report every database equal. If not, investigate first: `rollback` is always
  available, the target is not live yet.

## Step 6 — Start on the target, move DNS, validate

1. Set the held apps to their replicas and resume their CronJobs in the target's GitOps tree, then
   push. If an app's database was re-copied while it was running, restart it: its pool does not
   always recover from the forced disconnect.
2. Repeat the `--resolve` smoke test.
3. Run `tools/migrate-apps.sh <plan> dns --yes`. It creates explicit A records per host, so a
   wildcard that still serves the source's platform hosts stays where it is.
4. Validate over public DNS (`dig @1.1.1.1`, then plain `curl`):
   - every host returns its expected status with a valid certificate;
   - a journal app is appending: `max(ordering)` grows past the verified value;
   - CronJobs complete;
   - the apps' logs are clean. One-off startup errors during catch-up are normal; repeated ones
     are not.
5. Only now stop the source, if that is the goal. Check that its CI runners are idle, then:
   `CHECKPOINT` on its Postgres, `sync`, power off.

## Rollback

- Before DNS moves: `tools/migrate-apps.sh <plan> rollback --yes`. It restores replicas, CronJobs
  and the ArgoCD sync policies from the freeze state.
- After DNS moves: run `dns-rollback --yes` first, then `rollback --yes`. Anything written on the
  target in between is not carried back.

## After the move

- **Backups:** the target now holds the only live copy. Give the moved databases and volumes a
  backup there (dump CronJobs, NAS coverage) before the source is wiped. The source's backup
  Applications do not come along by themselves.
- **CI:** point the app repos' CI (registry, deploy environment) at the target, or its next deploy
  goes to the old environment.
- **Leftovers on the source:** list what stayed behind (buckets CI used, idle databases, registries).
  Get an explicit drop or keep from the user for each before the source is reprovisioned.
