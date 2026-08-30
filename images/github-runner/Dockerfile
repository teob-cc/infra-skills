# Custom GitHub Actions Runner with Build Tools
# Based on summerwind/actions-runner-dind with all tools from library/base

# PIN THE BASE. This was `:latest`, which meant the runner binary baked into our image was
# whatever the base happened to ship on the day someone last rebuilt — invisible from the
# Dockerfile and drifting silently from what GitHub requires.
#
# That bit us on 2026-08-17: the image carried actions/runner 2.332.0 while GitHub had moved to
# 2.336.0, so every FRESH ephemeral runner pod self-updated on its first job pickup and the job it
# was picking up died at "Set up job". Roughly every other CI run failed, for days, with a failure
# that looks like a code problem and isn't.
#
# Keep this pinned to an explicit version+OS. Bumping it is then a one-line, reviewable change with
# a visible blast radius, and the OS can't shift under the toolchain layers below (which assume
# Ubuntu 24.04 / apt + lsb_release). The tell that a bump is due is "Runner update in progress"
# in pod logs. Two commands answer "bump to what?":
#
#   what GitHub requires:   gh api repos/actions/runner/releases/latest --jq .tag_name
#   what actually exists:   curl -s 'https://hub.docker.com/v2/repositories/summerwind/actions-runner-dind/tags?page_size=100' \
#                             | jq -r '.results[].name' | grep 'ubuntu-24.04$' | sort -V | tail -3
#
# The two can disagree — actions/runner releases run ahead of summerwind's image publishing.
# Pin the newest tag that EXISTS on Docker Hub; never pin a version the hub doesn't carry yet.
FROM summerwind/actions-runner-dind:v2.336.0-ubuntu-24.04

USER root

# Install base dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    protobuf-compiler \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# VERSION MANIFEST — every explicit pin in this image, in one place.
#
# Agent instructions (yes, you — the agent asked to "update the runner image"):
#
#   1. Each pin below carries the exact command that prints its newest version.
#      Run it. A PATCH or MINOR bump within the same major line: apply it here.
#      A MAJOR bump changes the toolchain under every CI job in the org — that
#      is a human decision; propose it in the PR description, don't apply it.
#   2. Commit on a branch and open a PR. Merging to main triggers
#      .github/workflows/build-runner-image.yml (path filter:
#      images/github-runner/**), which builds on the environment's own
#      self-hosted runners and pushes harbor.<base_domain>/library/github-runner.
#   3. WATCH THE BUILD — never fire and forget; the image takes tens of minutes
#      and a broken :latest tag breaks every CI job that follows:
#        gh run list  -R <org>/<infra-repo> -w "Build Custom GitHub Actions Runner Image" -L1
#        gh run watch -R <org>/<infra-repo> <run-id> --exit-status
#      A failure within seconds, with no job logs, means the workflow had nowhere
#      to run: RUNNER_ENVIRONMENT / BASE_DOMAIN repository variables unset, or
#      the environment has no self-hosted runners yet (provision them first —
#      tools/k3s/github-action-runner.sh <env> --bootstrap).
#   4. Roll out: tools/k3s/github-action-runner.sh <env> — it auto-detects the
#      fresh image in Harbor and replaces the runner deployment.
#
# Pinned elsewhere in this file (they live inside their own install layers):
#   - Temurin JDK major (currently 25). Latest LTS:
#       curl -s https://api.adoptium.net/v3/info/available_releases | jq .most_recent_lts
#     Patch level floats via apt at build time; a new LTS major is a human decision.
#   - Node.js major (currently 22, maintenance LTS until 2027-04). Active LTS:
#       curl -s https://endoflife.date/api/nodejs.json | jq -r '[.[]|select((.lts != false) and (.lts <= (now|strftime("%Y-%m-%d"))))][0].cycle'
#     Patch level floats via nodesource at build time; the major is a human decision.
#   - npm major (currently 11; floats within it at build): npm view npm version
#   - Rust: deliberately NOT pinned — rustup installs current stable at build
#     time, so every rebuild is also a Rust update. To pin instead:
#     sh.rustup.rs -s -- -y --default-toolchain <version>.
# ============================================================================

# Scala "Next" line. CAREFUL: `releases/latest` is the wrong query here — it returns
# whatever was published most recently, usually a 3.3.x LTS backport. Newest Next release:
#   gh api 'repos/scala/scala3/releases?per_page=30' --jq '[.[]|select(.prerelease|not)|.tag_name]' | jq -r 'sort_by(split(".")|map(tonumber? // 0))|last'
ENV SCALA3_VERSION=3.8.4

# sbt 1.x line (sbt 2.x exists — a MAJOR rewrite, ecosystem still migrating).
# Newest 1.x, minus the leading v:
#   gh api 'repos/sbt/sbt/releases?per_page=100' --jq '[.[]|select(.prerelease|not)|.tag_name|select(startswith("v1."))]|first'
ENV SBT_VERSION=1.13.0

# Yarn classic — 1.22.22 is the FINAL 1.x release; expect no updates, ever.
# Yarn 2+ ("berry") is a per-project corepack concern, not this image's. Verify:
#   npm view yarn version
ENV YARN_VERSION=1.22.22

# pnpm 10.x line (11.x exists — MAJOR; pnpm majors track project lockfiles, so
# coordinate with the repos building on this runner before crossing):
#   npm view pnpm@10 version
ENV PNPM_VERSION=10.34.5

# Playwright — bumping this also refreshes the Chromium pre-installed below:
#   npm view @playwright/test version
ENV PLAYWRIGHT_VERSION=1.62.1

# Helm 3.x line (Helm 4 exists — MAJOR; the deploy workflows and bundled charts assume 3):
#   gh api 'repos/helm/helm/releases?per_page=100' --jq '[.[]|select(.prerelease|not)|.tag_name|select(startswith("v3."))]|first'
ARG HELM_VERSION=v3.21.4

# yq — here `releases/latest` is fine:
#   gh api repos/mikefarah/yq/releases/latest --jq .tag_name
ARG YQ_VERSION=v4.53.6

ENV PATH="/usr/local/sbt/bin:$PATH"

# Use bash for parameter expansion
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install Temurin JDK 25
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | apt-key add - \
    && echo "deb https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y temurin-25-jdk \
    && rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/temurin-25-jdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Install Node.js 22
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global npm@11

# Playwright: pin version and pre-install Chromium binary + OS deps into the image.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN npm install --global @playwright/test@${PLAYWRIGHT_VERSION} \
    && npx playwright install-deps chromium \
    && mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" \
    && npx playwright install chromium \
    && chmod -R 777 "$PLAYWRIGHT_BROWSERS_PATH"

# Install Yarn and PNPM
RUN npm install --global yarn@${YARN_VERSION} pnpm@${PNPM_VERSION} \
    && pnpm config set store-dir .pnpm-store

# Install Rust toolchain
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path \
    && rustup component add rustfmt clippy

# Install Scala (using GitHub releases like builder image)
RUN mkdir -p /usr/share/scala \
    && curl -fsSL "https://github.com/scala/scala3/releases/download/${SCALA3_VERSION}/scala3-${SCALA3_VERSION}-x86_64-pc-linux.tar.gz" | tar xz -C /usr/share/scala --strip-components=1 \
    && ln -s /usr/share/scala/bin/* /usr/local/bin/

# Install SBT (using GitHub releases like builder image)
RUN mkdir -p "/usr/local/sbt" \
    && curl -fsSL "https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz" | tar xz -C /usr/local/sbt --strip-components=1 --exclude=bin/sbtn-x86_64-pc-win32.exe --exclude=bin/sbtn-x86_64-apple-darwin \
    && sbt --allow-empty -Dsbt.rootdir=true sbtVersion

# Warm up SBT cache with Scala 3
RUN mkdir -p /tmp/sbt-warmup/project \
    && cd /tmp/sbt-warmup \
    && echo "scalaVersion := \"${SCALA3_VERSION}\"" > build.sbt \
    && echo "sbt.version=${SBT_VERSION}" > project/build.properties \
    && echo "--enable-native-access=ALL-UNNAMED" > .jvmopts \
    && echo "case object Temp" > Temp.scala \
    && mkdir -p "/root/.sbt/1.0/plugins" \
    && sbt compile \
    && cd / \
    && rm -rf /tmp/sbt-warmup \
    && rm -rf /tmp/.sbt && mkdir -p /tmp/.sbt && chmod 1777 /tmp/.sbt

# Install Helm (the deploy workflows lint/package charts and push them as OCI)
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-amd64

# Install yq
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Verify installations
RUN java -version \
    && scala -version \
    && sbt --version \
    && node -v \
    && npm -v \
    && yarn -v \
    && pnpm -v \
    && rustc --version \
    && cargo --version \
    && helm version \
    && yq --version

# Ensure PATH is available for runner user in all contexts
RUN echo 'export PATH="/usr/local/sbt/bin:${PATH}"' >> /etc/profile.d/sbt.sh \
    && chmod +x /etc/profile.d/sbt.sh

# Pre-create directories that npm/pnpm/jgit will need and set proper ownership
# Make /home/runner world-writable so runner can create subdirectories
RUN mkdir -p /home/runner/.config /home/runner/.cache /home/runner/.npm /home/runner/.sbt /home/runner/.ivy2 \
    && chown -R runner:runner /home/runner \
    && chmod -R 755 /home/runner

USER runner

# Ensure runner user can write to home directory
RUN mkdir -p ~/.config/jgit ~/.cache ~/.npm ~/.sbt ~/.ivy2

# Set PATH for runner user
ENV PATH="/usr/local/cargo/bin:/usr/local/sbt/bin:${PATH}"
