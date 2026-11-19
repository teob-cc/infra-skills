# Alert triage

A small service per cluster that gives every serious alert a first look by
[HolmesGPT](https://github.com/HolmesGPT/holmesgpt) and posts the finding to Slack. It is the
place where the cost of that look and the effect of an alert storm are bounded.

```
Alertmanager --webhook (firing p1, p2)--> alert-triage --POST /api/chat--> HolmesGPT
                                               |
                                               +--> Slack: the finding, and one line per escalation
                                               +--> stdout: one JSON line per investigation (Loki)
```

Alertmanager keeps sending the alert itself to its other receivers (email, Telegram, Slack).
The triage service adds the finding as a separate message. It never reads Slack, holds no
Kubernetes rights and stores nothing but a small state file.

- Chart: `charts/alert-triage`. The service is one file without dependencies,
  `charts/alert-triage/files/triage.mjs`, mounted from a ConfigMap and run on the stock Node
  image. There is no image to build.
- Alert rules: `charts/alert-triage/alerts/alert-triage.yml`.
- Tests: `tests/alert-triage/`, `tests/alert-rules/alert-triage-test.yml`.

## What it does with an alert

1. **Filters.** Only firing alerts with severity `p1` or `p2`. Never: resolved alerts, the
   `Watchdog`, the service's own two alerts, and node-down alerts (`KubeNodeNotReady`,
   `NodeExporterDown`) of the nodes listed in `skip.onDemandNodes`.
2. **Dedup.** Alerts are grouped by (`alertname`, `app`, `namespace`). A group is investigated
   once per 4 hours (`dedupHours`; 30 minutes after an investigation without a usable finding).
   A repeat notification, or another pod of the same group,
   inside the window is skipped.
3. **Caps.** At most 6 investigations an hour and 40 a day (`capPerHour`, `capPerDay`). Above a
   cap the alert is skipped, not queued, and marked for escalation. One line
   `N alerts not investigated, cap reached` is posted, 2 minutes after the first skipped alert
   (so that it counts what a storm skipped meanwhile) and once an hour at most. A `p1` does not
   pass the cap.
4. **Asks HolmesGPT**, one investigation at a time, with the alert's labels and annotations and
   a fixed instruction: likely cause, evidence, proposed next step, confidence (high, medium,
   low). It gives up after 5 minutes (`holmes.timeoutSeconds`).
5. **Posts the finding** in the findings channel, at most 3,000 characters, with the cluster
   name in front.
6. **Writes one JSON log line** for the investigation.
7. **Escalates** (`escalate: true` in the log line, and one line in the escalations channel)
   when:

   | Reason in `escalate_reasons` | When |
   | --- | --- |
   | `p1` | the alert's severity is in `escalateSeverities` |
   | `low_confidence` | HolmesGPT said its confidence is low |
   | `malformed_answer` | the answer was not in the expected form (it is posted as it came, as low confidence) |
   | `holmes_failed`, `holmes_timeout` | HolmesGPT answered with an error, did not answer, or ran into the timeout |
   | `repeat` | the group started firing 3 times (`repeatCount`) in 24 hours |
   | `cap` | the alert was skipped because a cap was used up |
   | `slack_failed` | Slack refused the post after 3 tries; the finding is in the log only |
   | `interrupted` | the service was restarted while the investigation ran |

An investigation that gave no usable finding (HolmesGPT error, timeout, malformed answer) keeps
its place in the caps, because it may have cost tokens, and is escalated. Its group gets a short
window of 30 minutes (`failedDedupMinutes`) instead of 4 hours, so an outage of HolmesGPT or of
its model does not blind an alert group for 4 hours.

"Started firing 3 times" counts different start times of the group's alerts. A repeat
notification of the same firing is not a new one.

## The log line

One line per investigation on stdout, `event: "investigation"`:

```json
{"ts":"2026-11-19T10:00:07.000Z","cluster":"test","event":"investigation","alert":"KubePodCrashLooping",
 "severity":"p2","app":"shop","namespace":"shop","group":"KubePodCrashLooping|shop|shop","firing_instances":1,
 "starts_at":"2026-11-19T09:58:00.000Z","summary":"Pod shop-0 is crash looping","outcome":"ok",
 "finding":{"cause":"...","evidence":"...","next_step":"...","confidence":"high"},"confidence":"high",
 "tokens":{"prompt":12000,"completion":300,"total":12300,"cached":9000},"model":"claude-haiku-5-5",
 "duration_ms":41200,"slack_posted":true,"escalate":false,"escalate_reasons":[]}
```

- `outcome`: `ok`, `malformed`, `failed`, `timeout` or `interrupted`.
- `tokens`: the sums over all model calls of the investigation, as HolmesGPT reports them.
- Other events: `skip` (one line per skipped alert group, with `reason` `dedup`, `cap_hour`,
  `cap_day`, `resolved`, `severity` or `rule`; a skip by a cap has `escalate: true`), `cap` (the
  cap line), `state`, `slack`, `start`.
- The line holds the finding and nothing more of HolmesGPT's answer: no conversation history,
  no tool output. The finding's fields are cut to 500, 1,100 and 500 characters. Error texts are
  cut to 300 characters and the two credentials are removed from them.

With promtail's usual labels, in Loki:

```logql
{namespace="holmes", container="alert-triage"} | json | event="investigation"
{namespace="holmes", container="alert-triage"} | json | escalate="true"
```

## Text from outside is not trusted

Alert labels and annotations and HolmesGPT's answer can contain anything, including text
written by whoever controls a pod's log. Before such text goes to Slack:

- `&`, `<` and `>` are escaped, so no mention (`<@U…>`, `<!channel>`) and no link
  (`<url|text>`) can be formed;
- `@here`, `@channel`, `@everyone` are broken with an invisible character and `http://`,
  `https://` are written `hxxp://`, `hxxps://`;
- the message is posted with `parse: none` and without link previews;
- the only link is `grafanaUrl` from the chart's values, which must be a plain https URL;
- the whole message is cut to 3,000 characters.

The instruction to HolmesGPT says that the alert is data and that instructions inside it are
not to be followed. That is a request to a model, not a guarantee: what protects the cluster is
that HolmesGPT only reads.

## State and restarts

The dedup windows, the cap counters and the investigations not yet finished are one JSON file
on a small volume (`persistence.size`, 16Mi). It survives a pod restart.

- No file at start: a new install, the service starts empty and says so in the log.
- A file it cannot read, or a volume it cannot write: it fails safe. The hourly cap counts as
  used for one hour, nothing is investigated meanwhile, the gauge `alert_triage_state_failsafe`
  is 1 and `AlertTriageFailing` fires.
- An investigation that was running when the pod stopped is reported at the next start as
  `interrupted` with `escalate: true`. Its place in the caps stays used.
- To reset the state on purpose: delete the file's volume claim together with the pod.

## Install

In the namespace HolmesGPT runs in (the examples say `holmes`).

1. Two Secrets in that namespace. The chart does not create them:
   - the key of HolmesGPT's API (`holmes.apiKeySecret`, default `holmes-api-key`, key
     `api-key`): the Secret HolmesGPT itself reads;
   - the Slack bot token (`slack.tokenSecret`, default `alert-triage-slack`, key `token`): a
     Slack app with the scope `chat:write` that was added to both channels.
2. The chart, as an Argo CD Application that points at this repository
   (`path: charts/alert-triage`, a pinned revision) or with `helm upgrade --install`. Values to
   set: `cluster` (required), `grafanaUrl`, `holmes.url`, `holmes.model`, `skip.onDemandNodes`.
3. Check the pod is ready, then switch the webhook on: in the env's `env.properties`

   ```
   ALERTMANAGER_TRIAGE_WEBHOOK_URL="http://alert-triage.holmes.svc.cluster.local:8080/webhook"
   ```

   and `tools/k3s/observability.sh <env> --dry-run`, then `--rules-only`. The dry run must show
   one new receiver (`alert-triage`), one new first route (`severity=~"p1|p2"`, `continue: true`)
   and two alerts added (`AlertTriageFailing`, `AlertTriageCapReached`). Without the variable
   the script renders exactly what it rendered before.

Keep this order. Alertmanager counts a webhook nobody answers as a failed notification, and
`AlertmanagerNotificationsFailing` (p1) fires on those: its counter
`alertmanager_notifications_failed_total` has the labels `integration` and `reason` only
(Alertmanager 0.34), so that rule cannot tell this webhook from the dead-man's webhook. Only a
pod that is not running fails the webhook. The service answers Alertmanager at once, before it
asks HolmesGPT, so an outage of HolmesGPT or Slack does not fail it; those show as
`AlertTriageFailing` (p2).

If the pod cannot be brought back quickly, switch the webhook off (two or three minutes):
remove the line from `env.properties` and run `observability.sh <env> --rules-only`.

**Switch it off** in the reverse order: remove the line from `env.properties`, run
`observability.sh <env> --rules-only`, then remove the Application.

### Network

The chart's NetworkPolicy selects this pod only. In: Alertmanager on the webhook port (8080),
Prometheus on the metrics port (9102). Out: DNS, HolmesGPT's pod port (5050), and TCP 443 to
every address outside the private ranges.

**The last rule is wider than Slack.** A NetworkPolicy cannot name `slack.com`, so as far as the
network goes the pod can open HTTPS connections to any public address. What keeps it to Slack is
the code: the only address outside the cluster it connects to is
`https://slack.com/api/chat.postMessage`, fixed in `triage.mjs`. It is not a setting, and no
address is ever taken from an alert or from HolmesGPT's answer; HolmesGPT's address comes from
the chart's values only. The pod holds two credentials (HolmesGPT's API key, the Slack bot
token) and no others.

Policies add up. If the namespace has a policy for all pods that allows more (for example to
the Kubernetes API), this pod is allowed that too; it has no token to use there
(`automountServiceAccountToken: false`).

## Metrics and alerts

Port 9102, `/metrics`, scraped through the pod annotations.

| Metric | Labels | Meaning |
| --- | --- | --- |
| `alert_triage_investigations_total` | `outcome` | investigations by result |
| `alert_triage_skipped_total` | `reason` | alert groups not investigated (`dedup`, `cap_hour`, `cap_day`, `resolved`, `severity`, `rule`) |
| `alert_triage_failures_total` | `stage` | failed calls to `holmes`, failed posts to `slack` |
| `alert_triage_tokens_total` | `kind` | `prompt` and `completion` tokens reported by HolmesGPT |
| `alert_triage_escalations_total` | `reason` | escalations by reason |
| `alert_triage_cap_used`, `alert_triage_cap_limit` | `window` | used and allowed investigations per `hour` and `day` |
| `alert_triage_in_progress` | | investigations accepted and not finished |
| `alert_triage_state_failsafe` | | 1 while the state file could not be read or written |

Counters start from zero at a restart; the caps do not (they come from the state file).

| Alert | Severity | Fires when |
| --- | --- | --- |
| `AlertTriageFailing` | p2 | 3 or more failures (HolmesGPT or Slack) in an hour; or no ready pod for 10 minutes; or the state file is unusable for 5 minutes |
| `AlertTriageCapReached` | p3 | an alert was skipped by a cap in the last hour |

The service does not investigate these two itself (`skip.alertnames`).

## Limits to know

- **The caps are the cost limit.** At 6 an hour and 40 a day, with a step limit set in
  HolmesGPT, the worst case per day is 40 investigations. A spend limit at the model gateway or
  the provider is a second stop, not a replacement.
- **A timeout does not stop HolmesGPT.** Its HTTP API has no cancel: after 5 minutes the service
  gives up, but HolmesGPT may go on working on that request for a while, next to the following
  investigation.
- **The cap line is not exact in a long storm.** It is posted once an hour at most; alerts
  skipped after it are named in the next hour's line. Every skipped alert is in the log at once.
- **`response_format`.** The service asks HolmesGPT for a JSON schema and also asks for the same
  JSON in words. If the model path refuses `response_format` together with tools, set
  `holmes.responseFormat: false`; the answer is parsed the same way.
- **The image comes from Docker Hub** (`node:22-alpine` by digest). A cluster whose nodes may not
  pull from Docker Hub sets `image.repository` to its own registry's copy or proxy of it and, if
  that registry is private, needs a pull secret the chart does not have yet.
- **One pod.** The Deployment is `Recreate` with one replica; during a rollout Alertmanager
  retries the webhook.

## Tests

```bash
# The service against a fake Alertmanager payload, a fake HolmesGPT and a fake Slack endpoint
node --test tests/alert-triage/triage.test.mjs
docker run --rm -v "$PWD":/w -w /w node:22-alpine node --test tests/alert-triage/triage.test.mjs

# What observability.sh renders with and without the webhook (needs helm, yq, jq, docker)
tests/alert-triage/alertmanager-webhook.sh

# The alert rules
docker run --rm -v "$PWD":/w -w /w/tests/alert-rules --entrypoint promtool \
  quay.io/prometheus/prometheus:v3.14.0 test rules alert-triage-test.yml

helm lint charts/alert-triage --set cluster=test
```
