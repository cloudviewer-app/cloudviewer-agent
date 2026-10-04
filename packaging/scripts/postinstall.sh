#!/bin/sh
# shellcheck shell=sh
# postinstall for cloudviewer-agent (shared by deb and rpm via nfpm).
#
# Deliberately does NOT enable or start anything on a fresh install:
# enrollment is an identity decision, not a packaging side effect. The one
# exception is a pre-provisioned agent.env (cloud-init write_files, config
# management) — then enrollment completes here so a declarative install
# needs no imperative step at all. On upgrades the same call refreshes the
# config and re-asserts the units.
set -e

# Dedicated system user for the config poller
# (cloudviewer-agent-config.service). The poller is the network-facing
# curl/parse surface against a potentially hostile facade, so it must not
# be root — but it must own /etc/cloudviewer-agent to install configs. A
# user of its own gives privilege separation both ways: a compromised
# poller yields an unprivileged account, and the vector user (which runs
# the collector) can read configs but never write its own.
if ! getent passwd cloudviewer-agent >/dev/null 2>&1; then
    nologin=/usr/sbin/nologin
    [ -x "$nologin" ] || nologin=/sbin/nologin # RHEL-family path
    useradd --system --no-create-home --shell "$nologin" cloudviewer-agent 2>/dev/null || true
fi

# Dependencies are configured before us, so the vector user (created by the
# vector package) exists here; tolerate its absence anyway for the tarball/
# container layouts that reuse these scripts' files without the dependency.
mkdir -p /etc/cloudviewer-agent /var/lib/cloudviewer-agent
chown cloudviewer-agent /etc/cloudviewer-agent 2>/dev/null || true
if getent passwd vector >/dev/null 2>&1; then
    chgrp vector /etc/cloudviewer-agent 2>/dev/null || true
    chown vector:vector /var/lib/cloudviewer-agent 2>/dev/null || true
fi
# 2750: setgid, so every file the unprivileged poller creates in here
# inherits the vector group — that is what lets it produce
# vector-group-readable configs without any chgrp rights of its own.
chmod 2750 /etc/cloudviewer-agent

systemctl daemon-reload >/dev/null 2>&1 || true
# /run/cloudviewer-agent (tmpfiles.d) now rather than at the next boot, so
# `cloudviewer-agent enable disk-health` works right away. Creating a
# directory enables nothing: the disk-health units stay disabled.
systemd-tmpfiles --create /usr/lib/tmpfiles.d/cloudviewer-agent.conf >/dev/null 2>&1 || true

if [ -f /etc/cloudviewer-agent/manifest ]; then
    # Upgrade of an enrolled host: re-render vector.yaml from the CACHED
    # manifest so this package's (possibly changed) template applies now —
    # the facade's ETag is unchanged, so the poller alone would never
    # re-render. No network involved; best-effort so a render problem
    # cannot fail the package transaction.
    cloudviewer-agent render || true
elif [ -f /etc/cloudviewer-agent/agent.env ]; then
    # Pre-provisioned agent.env (cloud-init write_files, config
    # management): complete enrollment here so a declarative install needs
    # no imperative step. Best-effort: a facade outage during a fleet
    # rollout must not fail the package transaction.
    cloudviewer-agent enroll --quiet || true
else
    echo "cloudviewer-agent installed but not enrolled."
    echo "Enroll with: cloudviewer-agent enroll --token <agent_token>"
fi
