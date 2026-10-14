# Rust runner updates

The runner carries Rust 1.99.0, rustfmt, Clippy, protobuf tooling and cargo-audit
0.22.2. Applications should still pin their own compiler in `rust-toolchain.toml`.
wsgrpc builds in a Debian 13 container so its runtime does not inherit Ubuntu's
libc requirements.

GitHub runner 2.338.0 is installed over the digest-pinned Summerwind Ubuntu 24.04
base. Summerwind has no 2.338.0 image tag yet. The runner archive is checked against
the SHA-256 published by GitHub; ARC's scripts and container hooks are retained.
When Summerwind publishes a matching image, replace the base and remove the
payload replacement together.

Build through the environment repository's `build-runner-image.yml`, passing a
reviewed full `skills_ref` commit and `publish_latest=false`. The workflow builds
and checks the candidate before pushing it. Checks cover the runner version,
compiler version, audit tool, protoc, Helm, Buildx, yq and a Rust compile as the
runner user. Tags and OCI revision labels use the checked-out infra-skills commit,
not the caller's commit. Builds also publish SBOM and provenance attestations.

Record the resulting digest in the environment's `env.properties`:

```properties
RUNNER_IMAGE_REF=harbor.<base-domain>/library/github-runner@sha256:<digest>
```

Run `tools/k3s/github-action-runner.sh <env>` from the reviewed checkout to apply
the pinned image. Check the Kubernetes context first. Let active jobs finish;
do not delete running pods to force an upgrade. Validate a fresh runner with
`rustc --version`, `cargo audit --version` and a build before promoting the
candidate to the shared `latest` tag. Keep the previous digest for rollback.

The bootstrap image remains available, but `RUNNER_IMAGE_REF` must be unset for
bootstrap. A configured reference is validated as a digest and is never silently
replaced with `latest` during subsequent provisioning.
