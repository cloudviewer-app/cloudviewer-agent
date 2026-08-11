# Cloud Viewer agent container image (specs/30-agent-packaging §6).
#
# The image IS the installer for container hosts: upstream's Vector binary
# plus our POSIX-sh entrypoint and config poller — no binaries of our own,
# so the audit surface stays "read two small shell scripts".
#
# Build context is the REPO ROOT (the COPY below reaches into agent/):
#   docker build -f docker/Dockerfile .
#
# release.yml overrides VECTOR_VERSION via --build-arg when the release
# train bumps the pin; the default here is the tested version for the
# current train. ARG must precede FROM to be usable in it.
ARG VECTOR_VERSION=0.57.0

# Alpine, not distroless: the entrypoint and poller are POSIX sh. Verified
# from upstream's distribution/docker/alpine/Dockerfile: the image carries
# ca-certificates + tzdata, the binary at /usr/local/bin/vector, and NO curl.
FROM timberio/vector:${VECTOR_VERSION}-alpine

# curl, because the poller uses it: keeping the container poller byte-
# identical to the host version beats porting it to busybox wget's
# divergent flag set (spec 30 §6).
RUN apk add --no-cache curl

# The poller and the manifest renderer live at the same FHS paths the OS
# package installs them to (spec 30 §3) — the same scripts, identical
# everywhere they run. Both are required: the poller fetches the facade's
# parameter manifest and render-config turns it into vector.yaml locally
# (specs/17 §4 — the facade sends parameters, never config or code).
# --chmod needs BuildKit (default in current docker and always in buildx).
COPY --chmod=0755 agent/libexec/fetch-config /usr/libexec/cloudviewer-agent/fetch-config
COPY --chmod=0755 agent/libexec/render-config /usr/libexec/cloudviewer-agent/render-config
COPY --chmod=0755 agent/libexec/fleet-enroll /usr/libexec/cloudviewer-agent/fleet-enroll
COPY --chmod=0755 docker/entrypoint.sh /entrypoint.sh

# org.opencontainers.image.source is what links the GHCR package to the
# public repo (GHCR uses it to attach the package to
# github.com/cloudviewer-app/cloudviewer-agent and inherit its visibility).
LABEL org.opencontainers.image.title="cloudviewer-agent" \
      org.opencontainers.image.description="Cloud Viewer monitoring agent: Vector plus the Cloud Viewer entrypoint and config poller" \
      org.opencontainers.image.source="https://github.com/cloudviewer-app/cloudviewer-agent" \
      org.opencontainers.image.url="https://cloudviewer.app" \
      org.opencontainers.image.vendor="Cloud Viewer" \
      org.opencontainers.image.licenses="Apache-2.0"

# Configuration comes in via env / mounted Secret (CV_AGENT_TOKEN,
# CV_AGENT_TOKEN_FILE, CV_AGENT_FACADE_URL) — see docker/entrypoint.sh
# header. PROCFS_ROOT/SYSFS_ROOT are supplied by the pod spec / docker run
# alongside the /host/proc and /host/sys mounts, never baked in here.
ENTRYPOINT ["/entrypoint.sh"]
