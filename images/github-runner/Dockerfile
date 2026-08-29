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
# Ubuntu 24.04 / apt + lsb_release). Check https://hub.docker.com/r/summerwind/actions-runner-dind/tags
# when GitHub starts requiring a newer runner; the tell is "Runner update in progress" in pod logs.
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

# Version variables (matching builder image)
ENV SCALA3_VERSION=3.8.2
ENV SBT_VERSION=1.12.6
ENV YARN_VERSION=1.22.22
ENV PNPM_VERSION=10.31.0
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
ENV PLAYWRIGHT_VERSION=1.58.2
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
ARG HELM_VERSION=v3.19.0
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-amd64

# Install yq
ARG YQ_VERSION=v4.44.6
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

# Ensure runner user cank write to home directory
RUN mkdir -p ~/.config/jgit ~/.cache ~/.npm ~/.sbt ~/.ivy2

# Set PATH for runner user
ENV PATH="/usr/local/cargo/bin:/usr/local/sbt/bin:${PATH}"
