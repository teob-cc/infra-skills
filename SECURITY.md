# Security Policy

## Reporting a vulnerability

Email **security@pragmasoft.nl** with the details. Please do not open a public issue for
anything exploitable. You will get an acknowledgement within 3 business days.

If the report concerns a component we bundle rather than our own code (K3s, Dex, Pomerium,
ArgoCD, Harbor, cert-manager, …), report it upstream first; tell us anyway if the default
configuration shipped here makes it worse.

## Scope notes

- The scripts run with the operator's own credentials against the operator's own accounts.
  There is no vendor service, no shared control plane, and nothing phones home — the attack
  surface is your clusters and your repos, configured by code you can read.
- Secrets handling is SOPS + age; `secrets.plain/` must never be committed. If you find a
  path where a script could leak a secret into logs, a commit, or the conversation with an
  agent, that is in scope and we want to know.
