#!/bin/sh
# shellcheck shell=sh
# postremove for cloudviewer-agent (shared by deb and rpm via nfpm).
#
# MUST be self-contained: at this point the package's files — including
# /usr/bin/cloudviewer-agent — are already gone, so the deregister call is
# inlined here rather than delegated to the ctl.
#
# Argument semantics differ per format:
#   deb: "remove" keeps config/token/data (distro convention: purge is the
#        explicit destructive act), "purge" deregisters and removes them.
#   rpm: no purge concept — 0 (erase) deregisters and removes, 1 (upgrade)
#        must touch nothing.
set -e

cleanup() {
    if [ -f /etc/cloudviewer-agent/agent.env ]; then
        # Best-effort deregistration BEFORE deleting agent.env — it holds
        # the token the call authenticates with. The portal entry retires
        # and disappears after 72 h; on failure the portal row just stays
        # until revoked by hand (the honest message says so).
        # shellcheck disable=SC1091
        . /etc/cloudviewer-agent/agent.env 2>/dev/null || true
        if [ -n "${CV_AGENT_TOKEN:-}" ] && [ -n "${CV_AGENT_FACADE_URL:-}" ]; then
            if curl -fsS -m 10 -X POST \
                -H "X-Agent-Token: $CV_AGENT_TOKEN" \
                "$CV_AGENT_FACADE_URL/v1/agent/deregister" >/dev/null 2>&1; then
                echo "cloudviewer-agent: server deregistered (portal entry retires, gone after 72 h)"
            else
                echo "cloudviewer-agent: deregistration could not be confirmed — check the portal; revoke the server there if it does not show as retired" >&2
            fi
        fi
    fi
    rm -rf /etc/cloudviewer-agent /var/lib/cloudviewer-agent /run/cloudviewer-agent
}

case "${1:-}" in
purge | 0)
    cleanup
    ;;
*)
    :
    ;;
esac

systemctl daemon-reload >/dev/null 2>&1 || true
