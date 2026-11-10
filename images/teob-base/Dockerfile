# teob-base — runtime base image for JVM services built on this platform
#
# Eclipse Temurin 25 JRE on UBI 10 minimal, plus Node.js 26 and the Claude Code CLI so a
# service can ship an agent (MCP server) next to the JVM. Applications reference it as
# `dockerBaseImage` (sbt-native-packager) or `FROM`:
#
#   harbor.<base_domain>/library/teob-base:latest
#
# Built by .github/workflows/build-teob-base-image.yml on the environment's own runners and
# pushed to that environment's Harbor (tools/k3s/harbor-image.sh <env> teob-base). The upstream
# JRE comes through Harbor's Docker Hub proxy project so builds never hit Docker Hub rate limits.
ARG HARBOR_REGISTRY
FROM ${HARBOR_REGISTRY}/dockerhub-proxy/library/eclipse-temurin:25-ubi10-minimal

USER root

# Node.js from the official tarball: UBI minimal has no nodejs package. Node 26 links libatomic.so.1,
# which the minimal image does not ship.
ENV NODE_VERSION=26.13.0
ARG NODE_SHA256=5848553868b402d3fabb5b09270649977780a390f832155721025a08b5104455
RUN microdnf install -y tar gzip findutils libatomic && \
    curl -fsSL --retry 5 --retry-all-errors "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" -o /tmp/node.tgz && \
    echo "${NODE_SHA256}  /tmp/node.tgz" | sha256sum -c - && \
    tar xzf /tmp/node.tgz -C /usr/local --strip-components=1 --no-same-owner && \
    rm /tmp/node.tgz && \
    microdnf clean all && \
    node -v && npm -v

# Claude Code CLI for services that bundle an agent.
RUN npm install -g @anthropic-ai/claude-code && \
    (claude --version 2>/dev/null || true)

# /opt/teob/agent        - MCP server, copied in by the application's own image build
# /opt/teob/agent/skills - mounted from a ConfigMap at runtime
# Owned by the sbt-native-packager daemon user (1001:0).
RUN mkdir -p /opt/teob/agent/skills && chown -R 1001:0 /opt/teob

USER 1001
