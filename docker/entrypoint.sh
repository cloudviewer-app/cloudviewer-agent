#!/bin/sh
# shellcheck shell=sh
#
# Cloud Viewer agent container entrypoint (specs/30-agent-packaging §6).
#
# The container is the install: resolve the token, write agent.env, fetch
# the initial vector.yaml from the facade, then supervise exactly one
# child — Vector — while a 60 s poll loop stands in for the host package's
# systemd timer (no systemd in a container; the loop IS the timer).
#
# Environment:
#   CV_AGENT_TOKEN              per-server agent token (shown once in the
#                               portal at server creation)
#   CV_AGENT_TOKEN_FILE         file holding that token (Secret mounts)
#   CV_AGENT_ENROLL_TOKEN       fleet enrollment token (specs/12 §3): the
#                               container self-registers via the Hetzner
#                               metadata service (needs hostNetwork) and
#                               uses the minted per-server token instead
#   CV_AGENT_ENROLL_TOKEN_FILE  file holding the fleet token (Secret mounts)
#   CV_AGENT_FACADE_URL         facade base URL (default https://api.cloudviewer.app)
#
# Precedence: a per-server credential always wins over a fleet credential
# (an explicit server identity beats self-registration), and within each
# kind the mounted file wins over the env var. *_FILE paths that do not
# exist or are unreadable are treated as "not provided" — the Helm chart
# mounts one Secret and always sets both *_FILE vars, and which keys the
# Secret actually carries decides the mode; only ending up with NO
# credential at all is fatal.
#
# PROCFS_ROOT / SYSFS_ROOT are read by Vector's host_metrics source, not by
# this script: they arrive from the pod spec / `docker run -e` alongside the
# /host/proc and /host/sys read-only mounts (see the Helm chart and README).
# Deliberately not defaulted here — without the mounts a default would only
# make host_metrics silently read the container's own /proc.
set -eu

ETC_DIR=/etc/cloudviewer-agent
DATA_DIR=/var/lib/cloudviewer-agent
FETCH_CONFIG=/usr/libexec/cloudviewer-agent/fetch-config

fail() {
    printf 'cloudviewer-agent: error: %s\n' "$*" >&2
    exit 1
}

FACADE_URL="${CV_AGENT_FACADE_URL:-https://api.cloudviewer.app}"
FACADE_URL="${FACADE_URL%/}"

# --- Resolve the token ------------------------------------------------------
# File beats env within each credential kind: a mounted Secret is
# deliberate configuration, a stray env var more likely an accident. The
# command substitution trims the trailing newline a Secret file or
# `echo token > file` usually carries. See the header for why a missing
# *_FILE is "not provided" rather than fatal.
TOKEN="${CV_AGENT_TOKEN:-}"
if [ -n "${CV_AGENT_TOKEN_FILE:-}" ] && [ -r "$CV_AGENT_TOKEN_FILE" ]; then
    TOKEN="$(cat "$CV_AGENT_TOKEN_FILE")"
fi

if [ -z "$TOKEN" ]; then
    ENROLL_TOKEN="${CV_AGENT_ENROLL_TOKEN:-}"
    if [ -n "${CV_AGENT_ENROLL_TOKEN_FILE:-}" ] && [ -r "$CV_AGENT_ENROLL_TOKEN_FILE" ]; then
        ENROLL_TOKEN="$(cat "$CV_AGENT_ENROLL_TOKEN_FILE")"
    fi
    if [ -n "$ENROLL_TOKEN" ]; then
        # Fleet flow (specs/12 §3), shared implementation with the OS
        # package's ctl. A container restart re-runs this: the facade's
        # enrollment is idempotent — the same node re-registers onto the
        # same server row, the freshly minted token replaces the oldest
        # of the row's (max two) active tokens, and the fleet token
        # itself never persists anywhere. Failure exits 1 → restart-policy
        # crash loop, the desired visible failure (spec 30 §6); the
        # helper's stderr says exactly why (no metadata service = no
        # hostNetwork is the common Kubernetes mistake).
        TOKEN="$(CV_AGENT_ENROLL_TOKEN="$ENROLL_TOKEN" CV_AGENT_FACADE_URL="$FACADE_URL" \
            /usr/libexec/cloudviewer-agent/fleet-enroll)" || exit 1
    fi
fi

# Missing credential = immediate exit 1 and a restart-policy crash loop —
# the desired visible failure (spec 30 §6): visibly broken beats silently
# unenrolled.
[ -n "$TOKEN" ] ||
    fail "no credential: set CV_AGENT_TOKEN(_FILE) with a per-server token, or CV_AGENT_ENROLL_TOKEN(_FILE) with a fleet enrollment token (portal → Add server)"

# --- agent.env --------------------------------------------------------------
# The same file the OS package's `enroll` writes; fetch-config sources it.
# 0600 because it holds the token — defense in depth even on a filesystem
# that is entirely ours.
mkdir -p "$ETC_DIR" "$DATA_DIR"
umask 077
cat >"$ETC_DIR/agent.env" <<EOF
CV_AGENT_TOKEN=$TOKEN
CV_AGENT_FACADE_URL=$FACADE_URL
EOF
chmod 600 "$ETC_DIR/agent.env"

CV_AGENT_ETC_DIR="$ETC_DIR"
export CV_AGENT_ETC_DIR

# --- Initial config ---------------------------------------------------------
# fetch-config exits non-zero only on auth failures / unexpected facade
# responses, and it already prints the friendly detail (unknown vs revoked
# token) — we just add the outcome and crash.
"$FETCH_CONFIG" ||
    fail "initial config fetch failed — fix the token (or CV_AGENT_FACADE_URL) and restart the container"
# fetch-config treats an unreachable facade as "keep the current config",
# which is right for a running agent but useless on first boot with nothing
# cached: Vector cannot start without a config, so surface that case with a
# real message instead of letting Vector crash on a missing file.
[ -s "$ETC_DIR/vector.yaml" ] ||
    fail "no config to start with: the facade at $FACADE_URL was unreachable and no cached config exists"

# --- Run Vector, keep polling -----------------------------------------------
# Namespaced data dir per specs/12 §6 — never /var/lib/vector, which a
# customer's own Vector could share via a host mount and corrupt buffers.
VECTOR_DATA_DIR="$DATA_DIR"
export VECTOR_DATA_DIR

vector --config "$ETC_DIR/vector.yaml" --watch-config &
vector_pid=$!

# Forward stop signals so Vector can flush its buffers; the flag stops the
# poll loop at once instead of finishing the current minute.
stopping=""
trap 'stopping=1; kill -TERM "$vector_pid" 2>/dev/null || true' TERM INT

# The poll loop — this shell stays PID 1, supervising exactly one child.
# 1 s ticks rather than one big sleep 60, so a dead Vector is noticed (and
# the container restarted) within a second instead of at the next minute
# boundary; every 60th tick runs the config poll. sleep is backgrounded
# under an interruptible `wait` so a TERM lands immediately. Poll failures
# are tolerated: a transient facade error or a just-revoked token must not
# kill a running collector (ingest is already blocked server-side; the
# helper logs why).
sleep_pid=""
tick=0
while [ -z "$stopping" ] && kill -0 "$vector_pid" 2>/dev/null; do
    sleep 1 &
    sleep_pid=$!
    wait "$sleep_pid" || true
    [ -n "$stopping" ] && break
    kill -0 "$vector_pid" 2>/dev/null || break
    tick=$((tick + 1))
    if [ "$tick" -ge 60 ]; then
        tick=0
        "$FETCH_CONFIG" || true
    fi
done
# Don't leave a stray sleep holding the container open.
if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null || true; fi

# Reap Vector and adopt its exit code. A `wait` interrupted by our own trap
# returns 128+signal without reaping — loop until the status is Vector's.
rc=""
while [ -z "$rc" ]; do
    if wait "$vector_pid"; then
        rc=0
    else
        rc=$?
        if [ "$rc" -gt 128 ] && kill -0 "$vector_pid" 2>/dev/null; then
            rc="" # our wait was interrupted; Vector still runs — wait again
        fi
    fi
done
exit "$rc"
