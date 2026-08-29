# Contributing

This repo is maintained for our own production use and released as-is. That shapes how
contributions work:

- **PRs are welcome** — and are the fastest path to a change. A PR that follows the
  conventions below and explains *why* (ideally with the incident or limitation that
  motivated it) will be reviewed seriously.
- **Issues are read on a best-effort basis** — expect an answer within about a week, and
  expect "PRs welcome" as a frequent answer. If you need the platform delivered, kept
  current, and backed by humans, that is the commercial offering at
  [pragmasoft.nl](https://pragmasoft.nl).
- **Scope is guarded.** Requests that widen the platform toward hobby setups
  (single-VPS mode, Docker-Compose mode, Raspberry Pi) will be declined — see
  "Who this is for" in the README. New *providers* for existing verticals are the most
  welcome kind of contribution — see [docs/VERTICALS.md](docs/VERTICALS.md).

## Conventions

- Scripts are plain bash, sourced from `tools/provision-common.sh`; first argument is the
  environment name; validate the kubectl context before changing anything; support
  `--skip-*` flags for independent components. Read `CLAUDE.md` — it is the authoritative
  guide (for humans too).
- **Never** hardcode domains, orgs, IPs, or credentials; derive from `env.properties` and
  the secrets files. A hardcoded value is a bug even when it works.
- No phoning home. No telemetry. No credential ever written outside the operator's own
  envs repo. These properties are the product; PRs that erode them will be rejected
  regardless of usefulness.
- Comments explain *why* (the constraint or the incident), not *what*.

## Testing a change

There is no CI that can provision servers on your behalf. State in the PR which environment
shape you tested against (bare-metal / Cloud VM, fresh / reprovision) and paste the relevant
verification output (`tools/doctor.sh <env>` is the standard smoke test).
