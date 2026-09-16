# teob-base — runtime base image for JVM services built on this platform
#
# Eclipse Temurin 25 JRE on UBI 10 minimal, plus Node.js 22 and the Claude Code CLI so a
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

# Node.js from the official tarball: UBI minimal has no nodejs package.
ENV NODE_VERSION=22.13.1
RUN microdnf install -y tar gzip findutils && \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" | \
    tar xz -C /usr/local --strip-components=1 --no-same-owner && \
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
