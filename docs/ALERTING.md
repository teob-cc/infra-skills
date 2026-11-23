# Alerting: coverage and runbook

`tools/k3s/observability.sh` ships the infrastructure alert rules with the Prometheus
release. They cover the platform from the hardware up to Kubernetes and the platform
services, along the four golden signals: latency, traffic, errors and saturation.
Application alerts are not part of this set. They live in the envs repo as fragments
(`envs/shared/alerts/*.yml`, `envs/<env>/alerts/*.yml`), which the script merges in.

Every rule carries `severity` (p1, p2 or p3) and `app: infra`. Alertmanager routes them
like this:

| Severity | Meaning | Channels | Repeat |
|---|---|---|---|
| p1 | Outage now, or data at risk | Telegram and email, no group wait | hourly |
| p2 | Degraded, or an outage within hours | Telegram and email | every 4 h |
| p3 | Needs attention this week | email, and Telegram once a day | daily |

A p1 alert inhibits p2 and p3 alerts that share its `alertname` and `app`. The
`Watchdog` alert always fires. It goes to the dead-man heartbeat (`ALERTMANAGER_DEADMAN_URL`)
or to a null receiver, and never to a human channel.

Slack is an optional third channel for p1 and p2; see [Slack](#slack) below.

To change rules on a running env, use `observability.sh <env> --dry-run` first. It
renders the upgrade server-side and diffs the three ConfigMaps against the live ones.
Then run `observability.sh <env> --rules-only`, which upgrades only the `prometheus`
release, so Grafana, Loki and the log shipper stay untouched.

## Coverage

| Layer | Latency | Traffic | Errors | Saturation |
|---|---|---|---|---|
| Hardware | NodeDiskReadLatencyHigh, NodeDiskWriteLatencyHigh | | MdRaidDegraded, MdRaidDiskFailed, MdRaidInactive, NvmeControllerNotLive, NodeFilesystemReadOnly, NodeMemory(Un)CorrectableErrors | NodeHardwareTemperatureCritical, MdRaidRebuildStuck |
| Node | NodeClockSkew, NodeClockNotSynchronising | | NodeNetworkErrors, NodeOOMKills, NodeExporterDown, NodeTextfileScrapeError | NodeCPUSaturated, NodeCPUUtilisationHigh, NodeMemoryLow/Critical, NodeMemoryPressureStalls, NodeIOStalled, NodeConntrackNearLimit, NodeFileDescriptorsNearLimit, NodeFilesystemSpace*/InodesLow/FillingUp |
| Control plane | KubeAPIServerLatencyHigh, KubeAPIServerListLatencyHigh, K3sDatastoreLatencyHigh, KubeletPLEGSlow | | KubeAPIServerDown, KubeAPIServerErrorsHigh, K3sDatastoreErrors, KubeletDown, KubeNodeNotReady, KubeStateMetricsDown | KubeAPIServerThrottling, K3sDatastoreLarge, KubeletTooManyPods, KubeNodePressure, KubeNodeUnschedulable |
| Workloads | | | KubePodCrashLooping, KubePodImagePullFailing, KubeContainerOOMKilled, KubeDeploymentReplicasUnavailable, KubeDeploymentRolloutStuck, KubeStatefulSetReplicasNotReady, KubeDaemonSetUnavailable, KubeJobFailed, KubeCronJobLastRunFailed, PodNotReady, PodContainerRestarting | KubePodUnschedulable, KubePersistentVolumeFillingUp/Full, KubePersistentVolumeClaimPending |
| DNS | CoreDNSLatencyHigh | | CoreDNSDown, CoreDNSErrorsHigh, CoreDNSForwardFailing | CoreDNSForwardFailing (concurrency limit) |
| Certificates | | | CertManagerCertificateNotReady, CertManagerAbsent | CertManagerCertificateExpiringSoon/ExpiryCritical, K3sCertificateExpiringSoon/ExpiryCritical, K3sCACertificateExpiring |
| Edge (Traefik) | TraefikSlowRequests | TraefikTrafficStopped | TraefikHighErrorRate, TraefikMetricsMissing, PlatformServiceErrorsHigh | |
| Platform services | | | PlatformWorkloadDown (Traefik, CoreDNS, cert-manager, Pomerium, Dex, Harbor, Argo CD, CNPG operator), DexErrors, DexMetricsMissing, ArgoCDAppUnhealthy, ArgoCDAppSyncFailing, ArgoCDAppOutOfSync, ArgoCDMetricsMissing | |
| Postgres (CNPG) | CNPGReplicationLagHigh | | CNPGInstanceDown, CNPGArchivingFailing, CNPGLastBackupFailed, CNPGFenced | CNPGConnectionsNearLimit, CNPGTransactionIDAgeHigh, CNPGLongRunningTransaction, CNPGWALArchiveBacklog, CNPGBackupStale |
| Backups | | | NasBackupStale, NasBackupMetricMissing, KubeCronJobLastRunFailed | |
| Alerting pipeline | | Watchdog (dead-man heartbeat) | AlertmanagerDown, AlertmanagerScrapeMissing, AlertmanagerNotificationsFailing, AlertmanagerEmailNotificationsFailing, AlertmanagerConfigReloadFailed, PrometheusAlertmanagerUnreachable, PrometheusNotificationErrors, PrometheusRuleEvaluationFailures, PrometheusConfigReloadFailed, PrometheusTSDBFailing, ScrapeTargetDown | |

Each cell that is empty is a gap on purpose:

- A node and its control plane have no meaningful "traffic" signal of their own; the
  edge carries that signal.
- Harbor and Pomerium expose no metrics as installed. Their availability is their
  Deployments' readiness (PlatformWorkloadDown), and their errors are read from
  Traefik's per-service counters (PlatformServiceErrorsHigh).
- SMART wear and media-error counters need smartctl and a textfile-collector script on
  each node, which is not part of this set yet.

### Scrape jobs behind the rules

The plain `prometheus` chart scrapes the API server, the kubelet and cAdvisor,
kube-state-metrics, node-exporter, and every pod or Service with a
`prometheus.io/scrape` annotation; that covers Traefik, CoreDNS and cert-manager. The
script adds the jobs the chart lacks:

| Job | Target | Feeds |
|---|---|---|
| `alertmanager` | Alertmanager Service, port `http` | alerting pipeline |
| `cnpg` | every CNPG instance pod (`cnpg.io/podRole=instance`), port `metrics` :9187 | infra-cnpg |
| `argocd` | Argo CD pods, port `metrics` | platform-services (Argo CD) |
| `dex` | Service `dex`, port `telemetry` :5558 | platform-services (Dex) |
| `postgres-exporter`, `mysql-exporter`, `kafka`, `kafka-exporter`, `scylla` | the data stacks | their own groups |

k3s serves the API server and kubelet metrics from one process, so most control-plane
series appear twice (jobs `kubernetes-api-servers` and `kubernetes-nodes`). Every rule
pins one job.

### On-demand nodes

A worker that is powered on only when it is needed (a GPU box, a burst worker) would
page as a dead node every time it is switched off. Label such a node
`infra-skills/on-demand=true`:

```bash
kubectl label node <node> infra-skills/on-demand=true
```

Add the label to `NODE_LABELS` in the worker's `env.properties` as well, so
`join-worker.sh` puts it back when the node registers again.

While a labelled node is not Ready it is parked, and the rules leave it alone:
KubeNodeNotReady, KubeletDown, NodeExporterDown and ScrapeTargetDown skip the node,
PodNotReady skips the pods on it, and KubeDaemonSetUnavailable does not count them. The
recording rule `node:on_demand_parked` holds one series per parked node. As soon as the
node is Ready again, every rule applies to it like to any other node, so a failing
exporter or pod on a joined on-demand node still alerts.

`observability.sh` knows about parked nodes too. node-exporter runs on every node, so
with a parked node its DaemonSet is never fully ready and `helm --wait` would time out.
The script then upgrades the `prometheus` release without `--wait` and waits for the
Deployments and the Alertmanager StatefulSet instead.

Nothing tells a parked node from one that crashed: both are simply not Ready. Do not
label a node that must stay up. Workloads that need the node are still watched: a pod
that waits for a parked node fires KubePodUnschedulable.

### Tenant workers

A tenant worker (`join-worker.sh --tenant`, label `node-restriction.kubernetes.io/tenant`)
runs only its tenant's pods, plus node-exporter: the ops org owns the node, so its disk and
memory are watched like any other (INFRA-227). The node-exporter DaemonSet tolerates the
tenant taint, and `tenant-admission.sh` admits exactly that DaemonSet there
(`TENANT_NODE_DAEMONSETS`). Promtail does not run there (its Loki credentials).

Prometheus scrapes a tenant worker's node-exporter (hostNetwork) over the tailnet on
tcp:9100, from the cluster server's address. The tailnet policy must grant the server's tag
that port on `tag:tenant-<tenant>` (INFRA-219); `provision-hetzner-cloud.sh` checks it.
Every rule applies to a tenant worker as to any node. NodeExporterDown fires when the node is
dead or when the 9100 grant is missing.

## Runbook

The alert descriptions carry the first steps; this section adds context per group.

### Hardware

Disk latency is measured per physical device (`nvme*`, `sd*`, `vd*`) with an IOPS floor,
so a single slow flush on an idle disk does not count. A failing disk usually slows
down before mdadm drops it, so compare the two RAID members: if one member alone is slow,
that disk needs replacing. The `smartctl -a` output and `dmesg` (resets, I/O errors)
confirm it. Give the serial from NvmeControllerNotLive to the hosting provider.

### Node

The saturation rules use pressure stall information (PSI), which counts the time tasks
wait for CPU, memory or I/O. PSI is a better signal than utilisation: a node at 90% CPU
whose tasks do not wait is fine. NodeExporterDown means every node and hardware rule for
that node is blind, so fix it first.

### Control plane

All environments built by these scripts run k3s with kine and SQLite at
`/var/lib/rancher/k3s/server/db/state.db`. Datastore latency is almost always disk
latency (see NodeIOStalled), or a database bloated by an object kind created in a loop.
`kubectl get --raw /metrics | grep apiserver_storage_objects` lists object counts by kind.

### Workloads

PodNotReady and PodContainerRestarting are the generic backstop; the Kube* rules name
the cause. CronJobs are judged by their latest run only. A failed Job that a CronJob
created stays in its history long after the next run succeeded, so KubeJobFailed skips
those Jobs. local-path volumes report the host filesystem rather than the claim,
so the PVC rules skip the `local-path` class and leave it to NodeFilesystemSpace*.

### DNS

CoreDNS forwards external names to the node's resolvers. When CoreDNSForwardFailing fires,
check `resolvectl status` on the node before suspecting CoreDNS.

### Certificates

Let's Encrypt certificates renew 30 days before expiry, so under 14 days left means
renewal is failing. k3s renews its own leaf certificates when it starts within 120 days
of expiry; on a server that is never restarted they run out after a year. When
K3sCertificateExpiringSoon fires, restart k3s (`systemctl restart k3s`; `k3s-agent` on
workers) or run `k3s certificate rotate`.

### Edge

All public traffic enters through Traefik. TraefikHighErrorRate and TraefikSlowRequests
have traffic floors, so a quiet env with a few probes an hour does not page on a single
failure. Find the backend with
`sum by (service, code) (rate(traefik_service_requests_total{code=~"5.."}[5m]))`.
Long-lived streams (SSE, websockets) count as slow requests, so check per service before
blaming the edge.

### Platform services

PlatformWorkloadDown pages when a Deployment or StatefulSet in a platform namespace
(`kube-system`, cert-manager, sso, harbor, argocd, cnpg-system) has no ready replica for
10 minutes. Pomerium proxies the protected apps, so its 5xx in PlatformServiceErrorsHigh
may come from an app behind it; Pomerium's log names the upstream.

### ArgoCD

ArgoCDAppOutOfSync fires after 6 hours of drift with auto-sync on. That is usually a
field a controller mutates (CRD defaults, CNPG or Strimzi status-like fields); add an
`ignoreDifferences` entry for it rather than silencing the alert.

### CNPG

The archiving and backup rules are inert until a cluster has a backup target (the Barman
Cloud plugin or an in-tree object store). Without one, CNPG's `archive_command` succeeds
without storing anything, and the backup timestamps stay at 0. The backup rules match
both the in-tree `cnpg_collector_*backup_timestamp` metrics and the plugin's.
After you enable backups, check that `{job="cnpg",__name__=~".*last_available_backup_timestamp"}`
returns a recent timestamp.

### Alerting pipeline

Nothing inside the cluster can report the death of Prometheus, Alertmanager or the node,
so only the external dead-man heartbeat covers those. Set it up per env:

1. Create a check at a heartbeat service (period 5 min, grace 10 min).
2. Store its URL as the `url` key of Secret `observability/alertmanager-deadman`.
3. Re-run with `--rules-only`.

AlertmanagerNotificationsFailing (p1) means Slack, Telegram or another receiver rejects or
cannot receive alerts; its description names the usual causes for that integration.
AlertmanagerEmailNotificationsFailing (p3) means the SMTP relay key is not authorised
for the sender domain.

## Slack

Alertmanager can post p1 and p2 alerts to a Slack channel by itself, next to Telegram
and email. Both keep every alert they get without Slack; p3 and the Watchdog never go to
Slack. The receiver is off until the env has a Secret `alertmanager-slack`. Without that
Secret the generated Alertmanager config is byte-for-byte the one without Slack.

A message has a title with severity, env, alert name and state, like
`[P1] [prod] KubeAPIServerDown (FIRING)`, linked to the alert list of the env's Grafana,
and one line per alert: its state, its summary and a runbook link. A group of more than
ten alerts shows the first ten. Resolved alerts are posted too.

### Switch it on for an env

1. In Slack, create an app with the single bot scope `chat:write`, install it to the
   workspace and add it to the channel (`/invite @<app>`). Keep its bot token
   (`xoxb-...`). An app that is not in the channel gets `not_in_channel` from Slack.
2. Create `envs/<env>/secrets.plain/alertmanager-slack.yaml`, the same shape as
   `alertmanager-telegram.yaml`:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: alertmanager-slack
     namespace: observability
   type: Opaque
   stringData:
     token: <the bot token>
   ```

3. Encrypt it, commit the file under `secrets.sops/`, and apply it with the kubeconfig
   of that env named explicitly, because `sops/apply.sh` writes to the current context:

   ```bash
   tools/sops/encrypt.sh <env> alertmanager-slack.yaml
   KUBECONFIG=<envs repo>/envs/<env>/kubeconfig.yaml tools/sops/apply.sh <env> alertmanager-slack.yaml
   ```

4. The channel defaults to `#infra-alerts`. For another one, set it in
   `envs/<env>/env.properties`, in quotes: `ALERTMANAGER_SLACK_CHANNEL="#ops-alerts"`.
   `ALERTMANAGER_SLACK_LINK_URL` changes where the title links to.
5. Look at the change, then roll it out:

   ```bash
   tools/k3s/observability.sh <env> --dry-run      # writes nothing
   tools/k3s/observability.sh <env> --rules-only   # upgrades only the prometheus release
   ```

   The dry run prints `Slack receiver on: ...` and the diff of `alertmanager.yml` shows
   one new receiver `ops-slack` and two new route legs, nothing else. The first real run
   adds a volume to the Alertmanager StatefulSet, so its pod restarts once.

The token is read by Alertmanager from the mounted file
(`/etc/alertmanager/slack/token`). It is in no ConfigMap, no Helm value and no output of
the script, and the script never creates or changes this Secret.

### Check it

Send a test alert to Alertmanager (it resolves by itself after five minutes):

```bash
kubectl -n observability port-forward svc/prometheus-alertmanager 9093:9093 &
curl -s -XPOST -H 'Content-Type: application/json' http://127.0.0.1:9093/api/v2/alerts \
  -d '[{"labels":{"alertname":"SlackTest","severity":"p2","app":"infra","env":"<env>"},
        "annotations":{"summary":"Test alert, ignore"}}]'
```

It must appear in the channel and in Telegram within a minute. If it does not reach
Slack, AlertmanagerNotificationsFailing fires with `integration="slack"`, and the
Alertmanager log names Slack's answer: `invalid_auth` (wrong or revoked token),
`not_in_channel` or `channel_not_found` (the app was not added to the channel, or the
channel name is wrong), `missing_scope` (the app lacks `chat:write`).

### Switch it off

Delete the Secret and run `--rules-only` again; the config goes back to the one without
Slack. Remove `secrets.sops/alertmanager-slack.yaml` from the envs repo as well,
otherwise the next `sops/apply.sh <env>` puts the Secret back.

```bash
kubectl -n observability delete secret alertmanager-slack
tools/k3s/observability.sh <env> --rules-only
```

### Test for the generated config

`tests/alertmanager-config/run.sh` renders the Alertmanager config for a fake env without
a cluster, with and without the Slack and dead-man Secrets. It checks the config with
`amtool check-config`, checks with `amtool config routes test` which receivers a p1, p2,
p3, Watchdog and an unlabelled alert reach, and compares the config without Slack with
`tests/alertmanager-config/expected/`. Run it after any change to the `alertmanager:`
block of `observability.sh`; `--update` rewrites the expected files after a wanted
change.
