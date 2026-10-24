# PostgreSQL continuous backup and point-in-time recovery

`tools/k3s/postgres.sh` can give its CloudNativePG cluster (`postgres-cluster`) continuous backup:

- a **WAL archive**, where every finished WAL segment is copied to object storage within seconds;
- a **daily base backup**.

Together they allow recovery to any moment inside the retention window. The archive goes to the
environment's MinIO (`tools/k3s/minio.sh`), and the work is done by the
[Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/), a CNPG-I plugin that runs as a
sidecar next to Postgres. The plugin replaces the in-tree `spec.backup.barmanObjectStore`, which CNPG has
deprecated and will remove after 1.31.

The feature is off by default. Without it, the only copy of the database outside the PGDATA volume is
whatever `pg_dump` jobs the environment runs: the nightly k3s-storage sweep (`tools/backup.sh`) leaves
every CNPG volume out on purpose, because a file copy of live PGDATA is not a backup.

## What it protects against

| Failure | What you recover | Data lost |
|---|---|---|
| Logical error: a bad migration, `DROP TABLE`, a deleting bug | A new cluster at any second inside `PG_BACKUP_RETENTION`, read from MinIO on the node | Nothing before the moment you pick |
| Postgres volume lost, node intact | The cluster from MinIO, replayed to the last archived segment | Seconds: the segment being written |
| Node lost (disk, RAID, the whole machine) | The MinIO volume from the backup host, then the cluster from it | Everything after that night's 06:15 k3s-storage sweep, so up to a day |

MinIO is a single node on the same machine. The off-node copy is the k3s-storage sweep in
`tools/backup.sh`, which runs at 06:15 and does include the MinIO volume. The base backup is scheduled
for 02:00 UTC so that it is finished before the sweep. To shorten the node-loss window you need a second
object store off the node, which this setup does not provide.

## Turning it on

In `envs/<env>/env.properties`:

```properties
UP_OPTIONAL_STEPS="minio postgres backup"   # the order of the list does not matter
PG_WAL_ARCHIVE=minio
# PG_BACKUP_RETENTION=7d                    # recovery window: Nd, Nw or Nm
# PG_BACKUP_SCHEDULE="0 0 2 * * *"          # CNPG cron: seconds first, UTC
```

`tools/up.sh <env>` always runs `minio` before `postgres`. By hand, run `tools/k3s/minio.sh <env>` and
then `tools/k3s/postgres.sh <env>`. postgres.sh then sets up the following:

1. It installs the **Barman Cloud plugin** with Helm into the operator's namespace (`cnpg-system`).
   - The chart version is `BARMAN_PLUGIN_CHART_VERSION`, default 0.8.1, which is plugin v0.15.1.
   - The plugin needs CloudNativePG 1.26 or later, and cert-manager for the TLS between operator and
     plugin; `identity.sh` installs cert-manager.
   - A plugin that is already running is never upgraded: the new sidecar image would restart every
     instance. The script prints the upgrade command instead.
2. It sets up a **bucket and an access key** in MinIO.
   - The bucket is `PG_BACKUP_BUCKET`, default `cnpg-backups`. The MinIO user is `PG_BACKUP_S3_USER`,
     default `cnpg-backup`, with a policy that allows that bucket and nothing else.
   - The script makes them with the `mc` that ships in the MinIO image, inside the MinIO pod. The root
     key never leaves that pod, and the new key goes in over stdin.
   - The key is stored in Secret `postgres/postgres-cluster-backup-s3`. The first run generates it and
     SOPS-encrypts it into `envs/<env>/secrets.sops/postgres-cluster-backup-s3.yaml`; commit that file.
3. It creates the **ObjectStore** `postgres/postgres-cluster-minio`.
   - It points at the in-cluster endpoint `http://minio.minio.svc.cluster.local:9000`, not at the public
     `s3.<HOSTNAME>`.
   - It sets `retentionPolicy`, and gzip for both WAL and base backups.
4. A **new** cluster gets `spec.plugins: [{name: barman-cloud.cloudnative-pg.io, isWALArchiver: true}]`
   in its manifest, so WAL is archived from the first segment on.
5. It creates a **ScheduledBackup** `postgres-cluster-daily` with `method: plugin` and `immediate: true`,
   so the first base backup runs at once and the recovery window starts today.

The objects end up in the bucket like this:

```
s3://cnpg-backups/postgres-cluster/base/<YYYYMMDDTHHMMSS>/{backup.info,data.tar.gz}
s3://cnpg-backups/postgres-cluster/wals/<timeline+segment>/...gz
```

### On a cluster that already runs

postgres.sh never changes the spec of a running cluster. If the cluster has no plugin entry, the script
prints the JSON patch that adds it, the same way it does for image drift:

```bash
kubectl -n postgres patch cluster postgres-cluster --type=json -p '[{"op":"add","path":"/spec/plugins","value":[{"name":"barman-cloud.cloudnative-pg.io","isWALArchiver":true,"parameters":{"barmanObjectName":"postgres-cluster-minio"}}]}]'
```

Applying it injects the sidecar, which restarts the instance; with one instance that is a short outage.
After that, run postgres.sh again and it creates the ScheduledBackup. If the cluster still carries an
in-tree `spec.backup.barmanObjectStore`, the script says so. Follow the plugin's
[migration guide](https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/) first: two archivers
must never run at once.

If the operator is older than 1.26, the script stops with an error. Upgrade the operator first (see the
`CNPG_VERSION` note in postgres.sh).

## Checking that it works

```bash
kubectl -n postgres get cluster postgres-cluster -o json \
  | jq '.status.conditions[] | select(.type=="ContinuousArchiving")'        # status "True"
kubectl -n postgres get backups                                            # PHASE completed
kubectl -n postgres get objectstore postgres-cluster-minio -o jsonpath='{.status}' | jq
#   serverRecoveryWindow.postgres-cluster.firstRecoverabilityPoint / lastSuccessfulBackupTime
kubectl -n postgres exec postgres-cluster-1 -c postgres -- \
  psql -U postgres -Atc "select last_archived_wal, last_archived_time, failed_count from pg_stat_archiver"
kubectl -n postgres logs postgres-cluster-1 -c plugin-barman-cloud --tail=50   # the sidecar
```

A few failures in `failed_count` right after a recovery bootstrap are normal: the recovery job tries
its timeline history file before the sidecar is ready. What matters is that `last_archived_wal` keeps
moving.

Deleting the ScheduledBackup also deletes its Backup objects (`backupOwnerReference: self`). The
objects in the bucket stay.

## Sizing

Barman takes full base backups; there is no incremental mode. The retention policy is a recovery window:
it keeps every base backup newer than *now − window*, plus the newest one older than that. With daily
backups and `7d`, that is about **eight compressed copies of the database**, plus seven to eight days of
WAL. local-path does not enforce `MINIO_STORAGE`, so it is the free space on `/data` that has to hold
this. The NAS keeps `BACKUP_RETENTION` (default 30 days) of rdiff increments of the MinIO volume, and
every daily base backup is a new file in it.

For a large database, weekly base backups keep far less:

```properties
PG_BACKUP_SCHEDULE="0 0 2 * * 0"   # Sundays 02:00 UTC
```

With the same `7d` window that is two base backups. The cost is a longer WAL replay when you restore.

## Restore drill: point-in-time recovery into a new cluster

Run this drill after turning the feature on, and again every quarter. It is also the procedure for a
logical error. It recovers into a **separate** cluster and leaves `postgres-cluster` alone.

1. **Choose the target time.** It must lie inside the recovery window: after `firstRecoverabilityPoint`
   (see "Checking that it works") and before the last archived segment. For a drill, write a marker row,
   note the time, then change something after it:

   ```bash
   P="kubectl -n postgres exec -i postgres-cluster-1 -c postgres -- psql -U postgres -d app -Atq"
   $P -c "create table if not exists restore_drill(at timestamptz default now(), note text)"
   $P -c "insert into restore_drill(note) values ('before target')"
   T=$($P -c "select to_char(now() at time zone 'utc','YYYY-MM-DD HH24:MI:SS.US')||'+00'"); echo "$T"
   sleep 2; $P -c "insert into restore_drill(note) values ('after target')"
   $P -c "select pg_switch_wal()"   # a separate statement: closes the segment so it is archived now
   ```

   Make `pg_switch_wal()` its own `psql -c` call. If it runs in the same transaction as the insert, the
   commit lands in the next segment, which is not archived yet.

2. **Create the recovery cluster.** It uses the same ObjectStore and reads the folder
   `serverName: postgres-cluster`, or `PG_BACKUP_SERVER_NAME` if that is set, as it is after a node-loss
   recovery. It has no `spec.plugins`, so it archives nothing and cannot write into the original's
   folder.

   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   metadata:
     name: pg-restore-drill
     namespace: postgres
   spec:
     instances: 1
     imageName: <the imageName of postgres-cluster>      # the same major version
     storage:
       size: <at least the database size>
       storageClass: local-path
     bootstrap:
       recovery:
         source: origin
         recoveryTarget:
           targetTime: "<T from step 1, e.g. 2026-10-24 11:05:20.179780+00>"
     externalClusters:
       - name: origin
         plugin:
           name: barman-cloud.cloudnative-pg.io
           parameters:
             barmanObjectName: postgres-cluster-minio
             serverName: postgres-cluster               # or PG_BACKUP_SERVER_NAME
   ```

   ```bash
   kubectl apply --dry-run=server -f drill.yaml && kubectl apply -f drill.yaml
   kubectl -n postgres get cluster pg-restore-drill -w        # "Cluster in healthy state"
   ```

   The recovery job (`pg-restore-drill-1-full-recovery-*`) restores the base backup taken before T,
   replays WAL up to T, and promotes the result onto a new timeline. Leaving `recoveryTarget` out
   replays everything that was archived.

3. **Verify.** The marker row is there and the later change is not:

   ```bash
   kubectl -n postgres exec pg-restore-drill-1 -c postgres -- psql -U postgres -d app -Atc "select note from restore_drill"
   # before target
   kubectl -n postgres exec pg-restore-drill-1 -c postgres -- psql -U postgres -Atc "select timeline_id from pg_control_checkpoint()"
   ```

   Record how long the recovery took. That is your restore time for a database of this size.

4. **For a real logical error,** copy what you need out of the drill cluster with
   `pg_dump -t <table>` piped to `psql` on `postgres-cluster`, then drop the drill cluster.

5. **Clean up:** `kubectl -n postgres delete cluster pg-restore-drill`; the PVC goes with it.

This was tested end to end on a throwaway k3s v1.35 cluster with CNPG 1.30.1, plugin v0.15.1, PostgreSQL
16.15 and the pinned Chainguard MinIO. The drill above, a recovery with `PG_RECOVER_TARGET_TIME` and the
node-loss procedure below each came back with exactly the rows written before the target. The backups
and the drill also work with the platform NetworkPolicies of `tools/k3s/network-policies.sh` in place:
`minio` admits S3 clients on 9000 from any namespace, and in `cnpg-system` operator and plugin share a
namespace.

## Losing the node: recovery from the backup host

The PGDATA volume is gone. The MinIO volume survives in the backup host's `<env>-k3s-storage` rdiff
repository, as of the last 06:15 sweep.

1. **Rebuild the node and the core stack** (Steps 1–7 of the provision skill, or `tools/up.sh <env>` up
   to `minio`). The envs repo restores the SOPS copy of the plugin's key.

2. **Bring MinIO back with its old data:**

   ```bash
   tools/k3s/minio.sh <env>                     # new, empty PVC; new root credentials are fine
   kubectl -n minio scale deploy/minio --replicas=0
   PV=$(kubectl -n minio get pvc minio-data -o jsonpath='{.spec.volumeName}')
   # On the node: restore the PVC directory from the backup host into the new one, e.g.
   #   rdiff-backup restore --at now <user>@<backup-host>::<base>/<env>-k3s-storage/<old pvc dir> \
   #     /data/k3s-storage/${PV}_minio_minio-data
   #   chown -R 65532:65532 /data/k3s-storage/${PV}_minio_minio-data
   kubectl -n minio scale deploy/minio --replicas=1
   ```

   MinIO keeps its users and policies in the data directory (`.minio.sys`), so the plugin's user comes
   back with it, even though the new root key is different. postgres.sh then sets that user's key again
   from the Secret: from the SOPS copy, or a freshly generated key if there is none.

3. **Recover the cluster with postgres.sh,** which needs two more lines in env.properties:

   ```properties
   PG_RECOVER_FROM=postgres-cluster                  # the folder to read
   PG_BACKUP_SERVER_NAME=postgres-cluster-20261024   # the folder to archive into from now on
   # PG_RECOVER_TARGET_TIME="2026-10-24 05:00:00+00" # optional; unset = replay everything archived
   ```

   ```bash
   tools/k3s/postgres.sh <env>
   ```

   The new `postgres-cluster` bootstraps with `bootstrap.recovery` instead of `initdb`. The plugin refuses
   to archive into a folder that already holds WAL, so the recovered cluster writes to the new folder
   `PG_BACKUP_SERVER_NAME`, and the script refuses to start if the two names are the same. Database roles
   keep their passwords, because they come from the backup, so the apps' `<app>-db` Secrets from the envs
   repo still match. CNPG sets new passwords for `postgres-cluster-app` and `postgres-cluster-superuser`.

4. **Afterwards:**
   - Remove `PG_RECOVER_FROM` from env.properties; a later run warns while it is still there.
   - **Keep `PG_BACKUP_SERVER_NAME`.**
   - The old folder `postgres-cluster/` is no longer pruned by anyone. Delete it once the new folder has a
     base backup and you no longer need the old points in time.

## md5 to SCRAM

New clusters get `scram-sha-256` on their private-range `pg_hba` lines. CloudNativePG adds
`host all all all scram-sha-256` itself for PostgreSQL 14 and later, and `password_encryption` has
defaulted to `scram-sha-256` since PostgreSQL 14.

An `md5` line accepts SCRAM passwords as well. A `scram-sha-256` line locks out any role whose stored
password is still an MD5 hash. On an existing cluster that still has `md5` lines, postgres.sh prints a
check and a patch. Apply the patch only if the check returns no rows:

```bash
kubectl -n postgres exec postgres-cluster-1 -c postgres -- \
  psql -U postgres -Atc "select rolname from pg_authid where rolpassword like 'md5%'"
```

If the query lists roles, give each of them its password again: `ALTER ROLE ... PASSWORD`, or
`postgres.sh --provision-credentials <app>` for app roles. With `password_encryption = scram-sha-256` the
new hash is SCRAM. The patch changes `pg_hba`, which CNPG reloads without a restart.

## The MinIO public endpoint

minio.sh also serves MinIO at `https://s3.<HOSTNAME>` by default, for clients outside the cluster. The
plugin does not need it. Two settings change that:

- `MINIO_ALLOWED_CIDRS="203.0.113.7/32 ..."` puts a Traefik ipAllowList in front of the endpoint. The
  private and Tailscale ranges are always allowed.
- `MINIO_PUBLIC_INGRESS=false` removes the endpoint altogether.

The plugin's key cannot reach any bucket other than its own, whatever the endpoint allows.
