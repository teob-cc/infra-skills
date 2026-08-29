# kafka-journal stack — operations runbook

Operational procedures for the Redpanda + ScyllaDB persistence stack backing
kafka-journal apps (one per app-id, e.g. `myapp`). Referenced by the `kafka-journal`
Prometheus alert group (baked into `tools/k3s/observability.sh`,
mirrored in `envs/<env>/apps/observability/kafka-journal-alert-rules.yaml`).

**Architecture recap:** events are appended to Redpanda topics
(`journal.<category>`, 7-day retention) and replicated by the kafka-journal
replicator into Scylla keyspace `<app>_journal`. Kafka is the source of truth
for the last 7 days; Scylla is the long-term store. Durability = daily Scylla
snapshot + Kafka replay of the gap since that snapshot. **The daily snapshot
cadence must therefore stay well under the 7-day topic retention.**

Key handles:

```bash
export KUBECONFIG=$INFRA_ENVS_ROOT/<env>/kubeconfig.yaml   # or infra-envs/envs/<env>/
tools/k3s/redpanda.sh <env> --watch health|topics|groups|logs
tools/k3s/scylla.sh   <env> --watch status|compactions|logs
tools/k3s/redpanda.sh <env> --show-credentials [app-id]
tools/k3s/scylla.sh   <env> --show-credentials [app-id]
```

Namespaces: `redpanda` (operator + broker `redpanda-0`), `scylla` /
`scylla-operator` (member `scylla-dc1-rack1-0`), backup CronJob `scylla-backup`
in `scylla`.

## Restart procedures {#restart}

Single-node stack — restarts mean brief unavailability, apps retry.

- **Redpanda broker:** `kubectl -n redpanda delete pod redpanda-0`. The
  StatefulSet reschedules onto the pinned node (static local PV). Verify with
  `--watch health`.
- **Scylla member:** `kubectl -n scylla delete pod scylla-dc1-rack1-0`. Wait
  for `UN` in `--watch status`. Expect a few minutes of commitlog replay.
- **Operators** are stateless: `kubectl -n redpanda rollout restart deploy/redpanda-operator`,
  `kubectl -n scylla-operator rollout restart deploy/scylla-operator`.
- Full-node reboot: both come back on their own; local-path/local PVs survive
  (`/data/redpanda`, `/data/scylla` on the node).

## Replicator stall / lag {#replicator-stall}

Alerts: `KafkaJournalReplicatorStalled` (p1), `KafkaJournalReplicatorLagHigh` (p2).

1. Confirm from the broker's view: `tools/k3s/redpanda.sh <env> --watch groups`
   — look at the replicator group's lag per partition.
2. Check the replicator pod (deployed as `<app>-replicator`): logs,
   restarts, OOM. A restart usually resumes from committed offsets — this is
   the first fix: `kubectl rollout restart deploy/<app>-replicator`.
3. If the replicator is up but not progressing, check Scylla: is it reachable
   (`ScyllaDown` also firing?), write latency in the `scylla-overview`
   dashboard, disk space on `/data`.
4. **Time budget:** unreplicated events age out of Kafka after 7 days. A stall
   is a p1 long before that; escalate hard if lag is older than ~3 days.
5. After recovery, watch lag drain in the `kafka-journal` dashboard.

## Scylla loss / restore {#scylla-loss}

Alert: `ScyllaDown` (p2 — appends keep working; reads and replication degrade).

Transient loss: fix the pod/node (see restarts). Data loss (PV gone, corrupt
sstables) — restore from snapshot + Kafka replay:

1. Stop the replicator (scale to 0) so it doesn't write into a half-restored store.
2. Reprovision the Scylla node if needed: `tools/k3s/scylla.sh <env>`
   (idempotent; recreates the CR against the static PV). If the PV content is
   corrupt, wipe `/data/scylla` on the node first (privileged pod or SSH).
3. Recreate roles/keyspaces: `tools/k3s/scylla.sh <env> --provision-credentials <app-id>`
   (regenerates the app password — reapply/re-encrypt the secret, restart the app).
4. Restore the newest archive from `/data/users/scylla-backups/` (or the
   offsite copy under your backup host's remote-backup base dir): untar into the matching
   `<data>/data/<keyspace>/<table>/` upload dirs and run
   `nodetool refresh <keyspace> <table>` per table, or use `sstableloader`.
5. Restart the replicator. It re-consumes from its committed offsets; events
   between the snapshot and the offsets are already in Kafka and will be
   re-replicated. kafka-journal writes are idempotent per (key, seqNr) — replay
   over restored data is safe.
6. Verify: app reads return, lag drains to zero, next nightly snapshot succeeds.

## Redpanda loss / pointer reset {#redpanda-loss}

Alert: `RedpandaDown` (p1 — journal appends are failing).

Transient loss: restart (see above). Data loss on `/data/redpanda` is more
serious — the last ≤7 days of the journal live only there until replicated:

1. Reprovision: `tools/k3s/redpanda.sh <env>` (idempotent). If the PV content
   is corrupt, wipe `/data/redpanda` on the node first. Recreate app users:
   `--provision-credentials <app-id>` (reapply/re-encrypt secrets).
2. Topics are auto-recreated (topic bootstrap Job / app auto-create). Events
   already replicated to Scylla are safe; events appended-but-not-yet-replicated
   are lost — check replicator lag *before* the incident (Prometheus history)
   to size the loss window.
3. **Pointer reset:** kafka-journal stores per-entity journal pointers
   (metajournal) in Scylla that reference Kafka offsets. After a broker wipe,
   offsets restart at 0 and stale pointers point past the log head. Reset the
   replicator group so it starts from the (new) beginning:
   `rpk group delete <replicator-group>` (via
   `kubectl -n redpanda exec redpanda-0 -c redpanda -- rpk ...` with superuser
   creds from `--show-credentials`), then follow the kafka-journal pointer-reset
   procedure app-side (your application's docs) before re-enabling writers.
4. Post-incident: confirm `rpk cluster health`, lag = 0, and run a manual
   snapshot to re-baseline durability.

## Disk full {#disk-full}

Alerts: `KafkaJournalDataDiskLow` (p2), plus the generic `NodeFilesystemSpaceLow`
on `/data` (all local PVs share the `vg0-data` volume — sizes are declarative,
NOT enforced).

- Biggest consumers under `/data`: `k3s-storage` (local-path PVCs), `rancher`,
  `users` (backup staging), `redpanda`, `scylla`.
- Quick wins: prune backup staging retention (`users/*-backups`), 
  `nodetool clearsnapshot` leftovers in `/data/scylla`, old Harbor/Nexus blobs.
- Redpanda refuses writes near disk-full (storage min free bytes); Scylla
  compaction needs headroom ~ the size of the largest sstable set.
- Structural fix: shrink topic retention, grow the LVM volume, or move a
  consumer elsewhere. PV "sizes" can be raised by editing the PV + PVC objects
  (local volumes don't enforce them).

## Snapshot cadence {#snapshot-cadence}

Alert: `ScyllaSnapshotOverdue` (p1 at >26h — this is the durability line).

- Mechanism: `scylla-backup` CronJob (05:00, ns `scylla`) runs
  `nodetool snapshot` via kubectl-exec, tars the snapshot hardlinks from
  `/data/scylla` into `/data/users/scylla-backups/` (7d in-PVC retention),
  clears the snapshot, and stamps
  `scylla_snapshot_last_success_timestamp_seconds` via the node-exporter
  textfile collector. The node's 06:00 rdiff cron ships the staging dir to the
  backup NAS (90d retention).
- Manual run / re-baseline: `tools/k3s/scylla.sh <env> --snapshot-now` (then
  stamp is refreshed by the next cron run; the alert clears on the next
  successful CronJob).
- Debug: `kubectl -n scylla get cronjob,job`, job logs; check the textfile
  stamp on the node (`/var/lib/node_exporter/textfile/scylla_snapshot.prom`);
  check node-exporter scrape (`nas_backup_*` metrics prove the collector works).

## Upgrades {#upgrades}

- Pins live in the scripts: `REDPANDA_OPERATOR_VERSION` / `REDPANDA_IMAGE_TAG`
  (`redpanda.sh`), `SCYLLA_OPERATOR_VERSION` / `SCYLLA_IMAGE_TAG` /
  `SCYLLA_AGENT_VERSION` (`scylla.sh`).
- Order: operator first, then the CR image tag. Single node = downtime window;
  do it in a quiet window with a fresh snapshot taken first.
- Broker upgrades: one minor at a time (Redpanda supports rolling from the
  previous feature release). Scylla: patch releases freely within 2025.1;
  major/minor jumps need the Scylla upgrade guide (sstable format).
- The weekly upstream-canary CI lane (kafka-journal fork) is the early-warning
  for client/broker incompatibilities before any broker bump.

## Drills {#drills}

Quarterly, on your reference env:

1. **Snapshot-restore drill:** take `--snapshot-now`, drop + restore
   `<app>_journal` per [Scylla loss](#scylla-loss) on a scratch keyspace, verify
   row counts.
2. **Alert drill:** scale the redpanda statefulset to 0
   (`kubectl -n redpanda patch redpanda redpanda --type merge -p '{"spec":{"clusterSpec":{"statefulset":{"replicas":0}}}}'`
   or simply delete the pod repeatedly) → `RedpandaDown` fires within ~6m;
   scale back, confirm resolve. Later: scale replicator to 0 with traffic →
   `KafkaJournalReplicatorStalled`.
3. **Failure-mode review:** check lag history and disk trends for the quarter.
