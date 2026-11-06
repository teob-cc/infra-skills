# Grafana across clusters

Every environment provisioned by `tools/k3s/observability.sh` runs its own Prometheus and
Grafana. With the settings below, one environment's Grafana (the *reading* cluster) also shows
the metrics of other environments (the *exporting* clusters), and named web pages may show
that Grafana in an iframe. Each part is switched by a property in `envs/<env>/env.properties`
and is off by default; with none of them set, the script renders exactly what it rendered
before.

```
 exporting cluster                                    reading cluster
 ┌─────────────────────────────────────┐              ┌──────────────────────────────────┐
 │ prometheus-server                   │              │ Grafana                          │
 │   ▲ /api/v1/ only                   │   HTTPS,     │   datasource Prometheus-<name>   │
 │ Ingress prometheus-export           │◀─basic auth──│   (user/password from Secret     │
 │   ipAllowList + basicAuth           │              │    grafana-remote-prometheus)    │
 │ Secret prometheus-export            │──── copied by grafana-remote-prometheus.sh ────▶│
 └─────────────────────────────────────┘              └──────────────────────────────────┘
```

## Properties

| Property | Set on | What it does |
|---|---|---|
| `PROMETHEUS_EXPORT_ALLOWED_CIDRS="203.0.113.0/24 198.51.100.7/32"` | exporting env | Serves the Prometheus query API at `https://<PROMETHEUS_EXPORT_HOST>/api/v1/` through Traefik, behind an `ipAllowList` of exactly these ranges and basic auth. Ensures the credential Secret and the DNS record. Unset: a run removes the Ingress and the two middlewares. |
| `PROMETHEUS_EXPORT_HOST` | exporting env | The export host. Default `prometheus-export.<HOSTNAME>`, which a `*.<HOSTNAME>` wildcard record covers. |
| `GRAFANA_REMOTE_PROMETHEUS="<name>=<url> ..."` | reading env | One Prometheus datasource per entry, named `Prometheus-<name>` with uid `Prometheus-<name>`, proxy access, basic auth, `timeInterval: 1m`, not the default datasource. `<name>` is lower-case letters, digits and dashes, at most 29 characters. `<url>` is the export's base URL, e.g. `https://prometheus-export.prod.example.com`. |
| `GRAFANA_FRAME_ANCESTORS="https://portal.example.com ..."` | reading env | Origins (`scheme://host[:port]`, a leading `*.` allowed) that may show Grafana in an iframe. Sets `security.allow_embedding` in `grafana.ini`, and the Pomerium route of the Grafana host answers `Content-Security-Policy: frame-ancestors 'self' <origins>`. |
| `GRAFANA_POMERIUM_JWT=true` | reading env | Grafana signs users in from the JWT Pomerium adds to every request, instead of asking them to sign in again. Off by default; its section says what changes for people (the role then follows `groups` on every request). |

Malformed values (a CIDR, a name, a URL or an origin that does not parse) fail the run before
anything changes.

## Secrets

| Secret (namespace `observability`) | Cluster | Keys | SOPS copy |
|---|---|---|---|
| `prometheus-export`, type `kubernetes.io/basic-auth` | exporting | `username` (always `grafana`), `password` | `envs/<exporting-env>/secrets.sops/prometheus-export.yaml` |
| `grafana-remote-prometheus` | reading | `<name>-username`, `<name>-password` per linked cluster | `envs/<reading-env>/secrets.sops/grafana-remote-prometheus.yaml` |

- `observability.sh` generates the export password once, when the Secret is missing or
  incomplete, applies it and encrypts it into the envs repo. When the cluster has lost the Secret
  but the SOPS copy exists, it restores the copy instead of generating a new password, so a
  rebuilt cluster keeps its readers. Commit the encrypted file.
- Traefik's `basicAuth` reads a Secret of type `kubernetes.io/basic-auth` by its `username` and
  `password` keys. There is no separate htpasswd key: Traefik refuses an Opaque basicAuth Secret
  that holds more than the one htpasswd key.
- Grafana gets the remote credentials as environment variables from `grafana-remote-prometheus`;
  the datasource YAML holds only the variable names. A `GRAFANA_REMOTE_PROMETHEUS` entry whose two
  keys are missing is left out with a warning.
- No value is printed or passed as a command argument by either script. The only file a value
  touches is the git-ignored `secrets.plain/` copy that `tools/sops/encrypt.sh` reads, and it is
  removed again whatever happens.

## Order of runs

1. **Exporting cluster.** Set `PROMETHEUS_EXPORT_ALLOWED_CIDRS` to the address the reading
   cluster's traffic leaves from (its node's public IP, or its NAT address), then
   ```bash
   tools/k3s/observability.sh <exporting-env> --export-only
   ```
   `--export-only` puts up the Secret, the Middlewares and the Ingress and upgrades no
   release; a full run does the same as part of the Prometheus step. It makes no DNS record:
   a wildcard record covers the default host, otherwise run once without the flag or create
   the record by hand. Commit `secrets.sops/prometheus-export.yaml` in that env's envs repo.
2. **Link.** Copy the credential into the reading cluster. Both sides are given explicitly, so
   the two envs may live in different envs repos:
   ```bash
   tools/k3s/grafana-remote-prometheus.sh <reading-env> <name> \
     --from <exporting-env> --from-envs-root ../other-envs/envs --from-kubeconfig ../other-envs/envs/<exporting-env>/kubeconfig.yaml \
     --to-envs-root ../infra-envs/envs --to-kubeconfig ../infra-envs/envs/<reading-env>/kubeconfig.yaml
   ```
   `--from-context` and `--to-context` pick a context other than the kubeconfig's current one.
   Each context has to contain its env's name, and the two have to reach different API servers.
   The script prints the `GRAFANA_REMOTE_PROMETHEUS` entry to add. Commit
   `secrets.sops/grafana-remote-prometheus.yaml` in the reading env's envs repo.
3. **Reading cluster.** Add `<name>=https://<export host>` to `GRAFANA_REMOTE_PROMETHEUS`, then
   ```bash
   tools/k3s/observability.sh <reading-env>
   ```
   In Grafana, *Connections → Data sources → Prometheus-<name> → Test* should succeed.

Re-running the link after the export password changed (a new Secret on the exporting side)
updates that name's keys only and restarts Grafana, which reads the keys at start.

## Framing

With `GRAFANA_FRAME_ANCESTORS` set, Grafana allows embedding and the Pomerium route carries the
CSP header. Browsers obey `frame-ancestors` over the `X-Frame-Options: SAMEORIGIN` Pomerium sends
by default, so only `'self'` and the listed origins can frame Grafana. The route file is
rewritten on every run (`envs/<env>/pomerium-routes.yaml`), and the header comes from the
script, so editing it by hand does not last.

`grafana.ini` is written only together with the Dex SSO block. A run that skips that block
(`--skip-sso`, no Dex client, no GitHub org) cannot apply `allow_embedding` and says so; the
route header is still set. Once the live release has `allow_embedding`, a run that would drop it
is refused (`ALLOW_GRAFANA_REGRESSION=true` accepts the loss).

The framing page and Grafana should be on the same site (the same registrable domain, e.g.
`portal.example.com` and `grafana.prod.example.com`). The Pomerium and Grafana session cookies
are `SameSite=Lax` by default, and browsers do not send those to a cross-site iframe, so a
cross-site page would show a sign-in loop.

## Sign-in through Pomerium (`GRAFANA_POMERIUM_JWT`)

Pomerium adds a signed assertion to every request of the Grafana route
(`X-Pomerium-Jwt-Assertion`; `aud` and `iss` are the route's host, plus the user's `email` and
`groups`). With `GRAFANA_POMERIUM_JWT=true`, `grafana.ini` gets an `auth.jwt` section that signs
the user in from it:

- `header_name: X-Pomerium-Jwt-Assertion`, `email_claim` and `username_claim`: `email`;
- `jwk_set_url: https://<AUTH_HOST>/.well-known/pomerium/jwks.json`, where `AUTH_HOST` is
  Pomerium's authenticate host, by default `auth.<HOSTNAME>` as in `tools/k3s/identity.sh`;
- `expect_claims: {"aud": "<GRAFANA_HOST>"}`, so a token minted for another route is refused;
- `auto_sign_up: true`, and the same `role_attribute_path` on `groups` (plus
  `allow_assign_grafana_admin`) as the Dex `generic_oauth` block.

This is what makes a framed Grafana usable. Without it a reader with no Grafana session gets
Grafana's login page inside the iframe, and a sign-in through GitHub cannot complete there
(GitHub refuses to be framed). A Grafana session also lapses after 7 idle days by default.

**What changes for people.** Through the route a reader is always the person Pomerium names:

- a valid assertion wins over a Grafana session cookie, so the local `admin` account cannot be
  used through the route, and "Sign out" in Grafana leads straight back in;
- the org role is set from `groups` on every request, so a role given by hand in Grafana lasts
  until that person's next request. Roles belong in the GitHub teams the mapping names;
- a user that exists already (made by the Dex sign-in) is matched by e-mail and keeps its id.

In-cluster callers that use the Service (`provision::grafana_api`, mcp-grafana) do not go
through Pomerium, carry no assertion, and are not affected.

**What a wrong setting does.** Grafana tries the assertion first. When it cannot verify one
(wrong `AUTH_HOST`, unreachable key set, audience mismatch) it falls back to its other sign-in
methods: a reader with a Grafana session stays in, and anyone else gets the login page, as
before the setting. Nobody is locked out; the setting just has no effect, and an iframe shows
the login page again. Grafana's log names the reason on every refused request
(`client=auth.client.jwt error="[jwt.invalid] failed to verify JWT: ..."`). Checked on Grafana
12.4 with tokens shaped like Pomerium's: wrong audience, expired, wrong key, unknown key id.
A token without an `email` claim is refused the same way (`jwt.missing_claim`).

## Undo

| To undo | Do |
|---|---|
| The export | Remove `PROMETHEUS_EXPORT_ALLOWED_CIDRS` and run `observability.sh <exporting-env>`: the Ingress and both middlewares go. The Secret and its SOPS copy stay, so switching back on keeps the readers' credential; to retire it, `kubectl -n observability delete secret prometheus-export` and delete the SOPS file. A DNS record created for a non-wildcard host stays in Cloudflare until removed there. |
| A remote datasource | Remove the entry from `GRAFANA_REMOTE_PROMETHEUS` and run `ALLOW_GRAFANA_REGRESSION=true observability.sh <reading-env>` (without it the run refuses to drop a live datasource). Then drop its keys: `grafana-remote-prometheus.sh <reading-env> <name> --remove --to-envs-root ... --to-kubeconfig ...`, which refuses while Grafana still reads them. Commit the SOPS file. |
| Framing | Remove `GRAFANA_FRAME_ANCESTORS` and run `ALLOW_GRAFANA_REGRESSION=true observability.sh <reading-env>`: `allow_embedding` goes and the route comes back without the header. |
| Sign-in through Pomerium | Remove `GRAFANA_POMERIUM_JWT` (or set it to `false`) and run `observability.sh <reading-env>`. |

## What a reader of the reading cluster's Grafana can see

Anyone who can open the reading cluster's Grafana can query the exporting cluster's Prometheus
through `Prometheus-<name>`: Editors and Admins in Explore, Viewers through dashboards and
through Grafana's query API, with any query they write:

- every series it holds, with all label values (namespaces, pods, nodes, services, database and
  queue names, the `ALERTS` series of its firing alerts), for its whole retention;
- the rest of `/api/v1/`: scrape targets with their in-cluster addresses (`/api/v1/targets`),
  alerting and recording rules, alerts, and the Prometheus configuration (`/api/v1/status/config`;
  Prometheus redacts the secrets in it).

They cannot see the exporting cluster's logs (Loki is not exported), its Grafana, or anything
outside `/api/v1/`. The admin API (`/api/v1/admin/...`) and the remote-write receiver are off
unless Prometheus is started with their flags, which `observability.sh` does not pass. The
datasource password is write-only in Grafana, and provisioned datasources are not editable in the
UI, so a reader cannot read it back or point the datasource elsewhere.

Series from another cluster carry no label naming it; the datasource does. Dashboards that
should show one cluster or another take a datasource variable of type Prometheus.
