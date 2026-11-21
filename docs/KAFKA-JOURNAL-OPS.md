# kafka-journal stack — operations runbook

Operational procedures for the Apache Kafka + ScyllaDB persistence stack backing
kafka-journal apps (one per app-id, e.g. `myapp`). Referenced by the `kafka-journal`
Prometheus alert group (baked into `tools/k3s/observability.sh`; tests in
`tests/alert-rules/kafka-journal-test.yml`) and the `kafka-journal` Grafana dashboard (shipped by
`tools/k3s/kafka.sh`).

**Architecture recap:** events are appended to Kafka topics
(`journal.<category>`, 7-day retention) and replicated by the kafka-journal
replicator into Scylla keyspace `<app>_journal`. Kafka is the source of truth
for the last 7 days; Scylla is the long-term store. Durability = daily Scylla
snapshot + Kafka replay of the gap since that snapshot. **The daily snapshot
cadence must therefore stay well under the 7-day topic retention.**

Kafka runs on the Strimzi operator (`tools/k3s/kafka.sh`): Apache Kafka 4.3.2 in KRaft
mode, one node that is both controller and broker, SASL/SCRAM-SHA-512 on the internal
listener `:9093`, simple authorization. Apps connect to
`kafka-kafka-bootstrap.kafka.svc.cluster.local:9093` with `SASL_PLAINTEXT`.

Key handles:

```bash
export KUBECONFIG=$INFRA_ENVS_ROOT/<env>/kubeconfig.yaml   # or infra-envs/envs/<env>/
tools/k3s/kafka.sh  <env> --watch health|topics|groups|logs
tools/k3s/scylla.sh <env> --watch status|compactions|logs
tools/k3s/kafka.sh  <env> --show-credentials [app-id]
tools/k3s/scylla.sh <env> --show-credentials [app-id]
tools/k3s/kafka.sh  <env> --dashboard-only            # (re)apply the kafka-journal Grafana dashboard
```

Dashboard: Grafana → Shared → `kafka-journal` (uid `kafka-journal`), shipped by `kafka.sh` as the
ConfigMap `observability/grafana-dashboard-kafka-journal` from
`tools/k3s/kafka/kafka-journal-dashboard.json`. It shows broker and exporter scrape health,
partitions and their health, messages/s per topic, broker bytes in/out, replicator lag (both
sources below), consumer-group lag, teob-rust replicator assignment/stalls/rebalances, the
journal partitions nobody monitors, and the broker data volume.

Namespaces: `kafka` (operator `strimzi-cluster-operator`, broker `kafka-dual-role-0`,
`kafka-entity-operator` with the Topic and User Operators, `kafka-kafka-exporter`,
`kafbat-ui`), `scylla` / `scylla-operator` (member `scylla-dc1-rack1-0`), backup CronJob
`scylla-backup` in `scylla`. The UI is Kafbat at `console.<env>`, behind Pomerium; it is
read-only by default (`KAFBAT_UI_READONLY=true`), because it connects as the superuser and the
route admits any authenticated org member. Set `KAFBAT_UI_READONLY=false` only together with a
route narrowed to admins.

## Users, topics and the admin client {#users-topics}

- **App users** are `KafkaUser` resources in namespace `kafka` (label
  `strimzi.io/cluster: kafka`). `kafka.sh <env> --provision-credentials <app-id>` writes
  `secrets.plain/<app>-kafka.secret.yaml` (the SCRAM password Secret in `kafka` and the
  app's `<app>-kafka` Secret) and `kafka-users/<app>.yaml` (the KafkaUser). Encrypt the
  first, commit both. Every `kafka.sh` run re-applies `kafka-users/`, so a rebuilt cluster
  gets its users back. A rerun keeps the app's password (the live Secret, else the
  `secrets.plain` copy); `--rotate-password` makes a new one, after which the app restarts
  with the reapplied Secret.
- **Default ACLs** cover topics, consumer groups and transactional ids that start with
  `<app-id>.` (with the dot), plus cluster `IdempotentWrite`. App ids cannot contain a dot,
  so app `teob` (`teob.`) never reaches `teob-rust.*` of app `teob-rust`; a prefix without a
  separator, or with `-`, would. Apps whose names do not start with `<app-id>.` set
  `KAFKA_ACL_PREFIX` (`*` grants every resource of those types), or keep hand-written ACLs.
  Apps that manage their own users through Argo CD put the same KafkaUser in their chart.
- **ACL pattern types** are `literal` and `prefix`.
  The cluster resource takes no name: `resource: {type: cluster}`.
- **Topics** are created by the apps (`auto.create.topics.enable=false`) or declared as
  `KafkaTopic` resources. The Topic Operator owns a topic with a KafkaTopic: **deleting
  the KafkaTopic deletes the topic and its journal.** Argo-managed KafkaTopics keep
  `argocd.argoproj.io/sync-options: Prune=false,Delete=false`.
- **Admin client:** the superuser is the KafkaUser `admin`; its Secret `admin` in `kafka`
  holds `password` and a ready `sasl.jaas.config`. The Kafka CLI tools live in the broker
  pod under `/opt/kafka/bin`. `kafka.sh --watch` feeds them the client properties on
  stdin; for a one-off command do the same:

  ```bash
  JAAS=$(kubectl -n kafka get secret admin -o jsonpath='{.data.sasl\.jaas\.config}' | base64 -d)
  printf 'security.protocol=SASL_PLAINTEXT\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=%s\n' "$JAAS" |
    kubectl -n kafka exec -i kafka-dual-role-0 -c kafka -- \
      env KAFKA_HEAP_OPTS=-Xmx256m /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server kafka-kafka-bootstrap.kafka.svc.cluster.local:9093 \
        --command-config /dev/stdin --describe --group <group>
  ```

  The `env KAFKA_HEAP_OPTS=-Xmx256m` matters: the container's `KAFKA_HEAP_OPTS` is the
  broker's own heap (`-Xms` = `-Xmx`, 1g by default), and a CLI JVM started with it inside
  the broker's memory limit can get the broker OOM-killed.

| Task | Kafka (`/opt/kafka/bin`) |
|---|---|
| cluster health | `kafka-metadata-quorum.sh describe --status`, `kubectl -n kafka get kafka kafka` |
| list topics with their config | `kafka-topics.sh --describe` |
| change a topic setting | `kafka-configs.sh --alter --entity-type topics --entity-name <t> --add-config k=v` (or the KafkaTopic's `config`) |
| list / describe consumer groups | `kafka-consumer-groups.sh --list` / `--describe --group <g>` |
| delete a consumer group | `kafka-consumer-groups.sh --delete --group <g>` |
| rewind a group to the start | `kafka-consumer-groups.sh --reset-offsets --group <g> --all-topics --to-earliest --execute`; the group must have no active members, so stop its consumers first (scale to 0 through git) |
| create a user | a `KafkaUser` (`--provision-credentials`) |

## Restart procedures {#restart}

Single-node stack — restarts mean brief unavailability, apps retry.

- **Kafka broker:** `kubectl -n kafka delete pod kafka-dual-role-0`. The StrimziPodSet
  recreates it on the pinned node (static local PV). Or let Strimzi roll it:
  `kubectl -n kafka annotate strimzipodset kafka-dual-role strimzi.io/manual-rolling-update=true`.
  Verify with `--watch health`.
- **Scylla member:** `kubectl -n scylla delete pod scylla-dc1-rack1-0`. Wait
  for `UN` in `--watch status`. Expect a few minutes of commitlog replay.
- **Operators** are stateless: `kubectl -n kafka rollout restart deploy/strimzi-cluster-operator`,
  `kubectl -n kafka rollout restart deploy/kafka-entity-operator`,
  `kubectl -n scylla-operator rollout restart deploy/scylla-operator`.
- Full-node reboot: both come back on their own; local-path/local PVs survive
  (`/data/kafka`, `/data/scylla` on the node).

## Replicator stall / lag {#replicator-stall}

Alerts: `KafkaJournalReplicatorStalled` (p1), `KafkaJournalReplicatorLagHigh` (p2),
`KafkaJournalReplicatorUnmonitored` (warning), `KafkaExporterDown` (p2: every lag alert is
blind while it lasts, since the log end comes from the exporter). Each alert names the journal
topic and partition.

Lag is the broker's log end (`kafka_topic_partition_current_offset`) minus the replicator's
position, and the position has two sources, one per journal implementation:

- **teob-rust apps** commit no Kafka offsets; the replicator keeps its position in Scylla and
  exports it as `teob_replicator_published_next{topic,partition}` on the app's `:9090/metrics`
  (the app's pods need the `prometheus.io/scrape` annotations). The rules take the max over
  pods (after a rebalance the pod that lost a partition keeps its old, lower value) and hold the
  last value for a day after the pods are gone, so a replicator that is scaled to 0 or
  crash-looping still stalls instead of vanishing. Recording rules
  `kafka_journal:replicator_published_next:max` and `kafka_journal:replicator_lag:offsets`.
- **kafka-journal-pekko apps** commit consumer-group offsets, so `kafka_consumergroup_lag`
  covers them. Only groups matching `KAFKA_REPLICATOR_GROUP_REGEX` count (env.properties or
  environment of `observability.sh`; default `.*replicator.*`, which matches kafka-journal's
  `<prefix>replicator.<keyspace>.<topic>`); these alerts also name the group. An app's own
  consumers or a dead-letter reader with lag neither fire nor hide a stalled replicator.

Journal topics are those matching `KAFKA_JOURNAL_TOPIC_REGEX` (default `.+[.]journal[.].+`).

- `KafkaJournalReplicatorLagHigh`: more than 10k offsets behind for 15m.
- `KafkaJournalReplicatorStalled`: behind, and the position has not moved for 15m, held 15m.
  It measures the position, not the age of the oldest unreplicated event: nothing fires when
  an event ages past the 7-day retention unreplicated (teob-rust counts that afterwards in
  `teob_replicator_source_expired_total`), so the budget below runs from when the stall began.
- `KafkaJournalReplicatorUnmonitored`: a journal partition has events but neither source
  reports a position for it, for 1h. The other two cannot fire for it. Usually the app is not
  scraped yet; for a pekko app, its replicator group has never committed.

1. Confirm in the `kafka-journal` dashboard (replicator lag per partition) or from the
   broker's view: `tools/k3s/kafka.sh <env> --watch groups` — for a pekko app, look at the
   replicator group's lag per partition (teob-rust replicators have no committed offsets).
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

## Kafka loss / pointer reset {#kafka-loss}

Alert: `KafkaBrokerDown` (p1 — journal appends are failing).

Transient loss: restart (see above), and check `kubectl -n kafka get kafka kafka -o yaml`
status and the operator log.

**Kafka CR deleted, data intact** (by hand, by `--force-cleanup`, by a mistaken Argo sync):
Strimzi keeps the KRaft cluster ID only in the CR's `status.clusterId`, so a new CR gets a
new ID and the broker crash-loops with `Invalid cluster.id in .../meta.properties`. Rerun
`tools/k3s/kafka.sh <env>`: when the CR is missing or has no ID yet, it creates it paused,
restores the ID into the status and unpauses (Strimzi's recovery procedure).

- **Where the ID comes from:** ConfigMap `kafka-cluster-id` in `kafka`. kafka.sh records
  the ID as soon as the CR status carries one, and replaces a recorded ID only once the
  cluster is Ready: a CR recreated outside kafka.sh gets a new ID and crash-loops, and must
  not overwrite the ID its data needs.
- **Override, `KAFKA_CLUSTER_ID=<id>`:** for when the namespace is gone (and the ConfigMap
  with it) but `/data/kafka` is kept. The ID is the `cluster.id=` line of
  `/data/kafka/kafka-log0/meta.properties` on the node, and also what the crash-loop error
  says it read. If the CR still exists with another ID, kafka.sh stops: delete the Kafka CR
  first (the PV and PVC stay), then rerun with the override.

Data loss on `/data/kafka` is more serious — the last ≤7 days of the journal live only
there until replicated:

1. Reprovision: `tools/k3s/kafka.sh <env>` (idempotent). If the PV content is corrupt,
   delete the Kafka CR and its PVC, wipe `/data/kafka` on the node, clear the PV's
   `claimRef.uid` (or delete the PV; kafka.sh recreates it) and rerun. The KafkaUsers and
   their Secrets live in the Kubernetes API, not on the volume, so they survive a data wipe
   and the User Operator writes them into the new broker, `admin` included, with its old
   password. After a namespace loss they come back from `kafka-users/` and the password
   Secrets (`tools/sops/apply.sh <env>`); `admin` then gets a new password, which the
   Kafbat UI picks up on restart.
2. Topics are recreated from their KafkaTopics, or by the apps. Events already
   replicated to Scylla are safe; events appended-but-not-yet-replicated are lost —
   check replicator lag *before* the incident (Prometheus history) to size the loss window.
3. **Pointer reset:** kafka-journal stores per-entity journal pointers
   (metajournal) in Scylla that reference Kafka offsets, and some apps keep consumer
   offsets of their own there as well. After a broker wipe, offsets restart at 0 and
   stale pointers point past the log head. Delete the replicator group so it starts
   from the (new) beginning: `kafka-consumer-groups.sh --delete --group <replicator-group>`
   (admin client, see [above](#users-topics)), then follow the kafka-journal
   pointer-reset procedure app-side (your application's docs) before re-enabling writers.
4. Post-incident: confirm `--watch health`, lag = 0, and run a manual
   snapshot to re-baseline durability.

## Migrating from Redpanda {#migrate-from-redpanda}

Earlier versions of this stack ran Redpanda (`tools/k3s/redpanda.sh`, since removed). A
`tools/up.sh` run that would reach the retired `redpanda` step stops until the env lists
`kafka` in `UP_OPTIONAL_STEPS` instead. A journal cannot be carried over: a new broker
restarts every offset at 0, and topic copies (MirrorMaker) do not keep offsets. Stop the
apps, remove Redpanda, reset their journal state ([pointer reset](#kafka-loss)), run
`tools/k3s/kafka.sh <env>` and point the apps at Kafka. Redpanda `User` resources become
KafkaUsers with `patternType: prefix` (Redpanda said `prefixed`). If
`envs/<env>/pomerium-routes.yaml` still routes `console.<env>` to Redpanda Console, run
kafka.sh once with `--force-console` to replace that route.

## Disk full {#disk-full}

Alerts: `KafkaJournalDataDiskLow` (p2), plus the generic `NodeFilesystemSpaceLow`
on `/data` (all local PVs share the `vg0-data` volume — sizes are declarative,
NOT enforced; a static local PV reports the whole filesystem).

- Biggest consumers under `/data`: `k3s-storage` (local-path PVCs), `rancher`,
  `users` (backup staging), `kafka`, `scylla`.
- Quick wins: prune backup staging retention (`users/*-backups`),
  `nodetool clearsnapshot` leftovers in `/data/scylla`, old Harbor/Nexus blobs.
- Kafka has no write floor: when the log directory fills up, the broker takes it
  offline and stops. Act at the alert, not at 100%. Scylla compaction needs headroom
  ~ the size of the largest sstable set.
- Structural fix: shrink topic retention (`retention.ms` / `retention.bytes` on the
  topic), grow the LVM volume, or move a consumer elsewhere. PV "sizes" can be raised by
  editing the PV + PVC objects (local volumes don't enforce them).

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

- Pins live in the scripts: `STRIMZI_VERSION`, `KAFKA_VERSION`, `KAFKA_METADATA_VERSION`,
  `KAFBAT_UI_IMAGE` (`kafka.sh`), `SCYLLA_OPERATOR_VERSION` / `SCYLLA_IMAGE_TAG` /
  `SCYLLA_AGENT_VERSION` (`scylla.sh`). The JMX exporter rules in
  `tools/k3s/kafka/kafka-metrics-config.yml` come from the Strimzi release's
  `packaging/examples/metrics/kafka-metrics.yaml`; refresh them with the operator.
- A Strimzi release supports a fixed set of Kafka versions (its `kafka-versions.yaml`;
  1.3.1: 4.2.0–4.3.2). A newer Kafka waits for the Strimzi release that adds it; dev
  compose and CI pin the same Kafka version as the cluster and move with it.
- Kafka order, one step per run of `kafka.sh`:
  1. **Operator:** bump `STRIMZI_VERSION`. kafka.sh applies the chart's CRDs
     server-side before `helm upgrade` (Helm itself never upgrades CRDs). The operator
     rolls the broker onto its own image of the same Kafka version.
  2. **Kafka:** bump `KAFKA_VERSION` (keep `KAFKA_METADATA_VERSION`). The broker rolls;
     single node = a short outage. Check apps and lag.
  3. **Metadata:** once the new version runs well, bump `KAFKA_METADATA_VERSION` (e.g.
     `4.3-IV0`). Some metadata versions cannot be downgraded: this is the point of no
     return.
- Scylla: operator first, then the CR image tag; patch releases freely within 2025.1;
  major/minor jumps need the Scylla upgrade guide (sstable format).
- Single node = downtime window; do it in a quiet window with a fresh snapshot taken first.
- The weekly upstream-canary CI lane (kafka-journal fork) is the early-warning
  for client/broker incompatibilities before any broker bump. Kafka 4 dropped the old
  client protocol versions (KIP-896): clients need kafka-clients 2.1 or newer.

## Drills {#drills}

Quarterly, on your reference env:

1. **Snapshot-restore drill:** take `--snapshot-now`, drop + restore
   `<app>_journal` per [Scylla loss](#scylla-loss) on a scratch keyspace, verify
   row counts.
2. **Alert drill:** make the scrape fail without touching the broker: point the metrics
   Service at a closed port,
   `kubectl -n kafka patch svc kafka-metrics --type json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'`
   → `KafkaBrokerDown` fires within ~6m; set it back to 9404 (or rerun kafka.sh), confirm
   resolve. (A NetworkPolicy cannot do this: policies add up, and Strimzi's own policy
   opens 9404.) Later: scale the replicator to 0 with traffic →
   `KafkaJournalReplicatorStalled` after about 30m (for a teob-rust app the held position keeps
   the lag growing after its pods are gone).
3. **Failure-mode review:** check lag history and disk trends for the quarter.
