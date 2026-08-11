#!/bin/sh
# shellcheck shell=sh
#
# Cloud Viewer agent bootstrap — served at https://get.cloudviewer.app/agent
#
# Install:    curl -fsSL https://get.cloudviewer.app/agent | sh -s -- --token <agent_token>
# Uninstall:  curl -fsSL https://get.cloudviewer.app/agent | sh -s -- --uninstall
#
# This script is a BOOTSTRAP, not the installer: it configures the two
# signed package repositories (Cloud Viewer's and Vector's), installs the
# cloudviewer-agent package with the system package manager, and runs
# `cloudviewer-agent enroll`. After it finishes, nothing on the host is
# script-managed — every installed file is listed by `dpkg -L
# cloudviewer-agent` / `rpm -ql cloudviewer-agent`, verified by
# `dpkg --verify` / `rpm -V`, and upgraded through the package manager.
#
# Hosts installed by the pre-package version of this script (Vector binary
# under /opt/cloudviewer-agent) are migrated in place: the enrollment token
# survives, so no re-enrollment is needed.
#
# Requirements: root, systemd, curl, and apt or dnf/yum. Other systems:
# see https://github.com/cloudviewer-app/cloudviewer-agent#other-platforms
# (container image, or manual install of the payload files).
#
# Test/dev overrides (used by the test harness — not needed on servers):
#   CV_AGENT_ROOT       path prefix for all host paths (DESTDIR-style)
#   CV_AGENT_SYSTEMCTL  systemctl replacement binary
#   CV_AGENT_PKG        package-manager replacement binary (test stub)

set -eu

ROOT="${CV_AGENT_ROOT:-}"
SYSTEMCTL="${CV_AGENT_SYSTEMCTL:-systemctl}"

GET_BASE="https://get.cloudviewer.app"
FACADE_URL=""
TOKEN=""
ENROLL_TOKEN=""
MODE="install"

# The old (pre-package) layout, for migration and legacy uninstall.
OLD_OPT="$ROOT/opt/cloudviewer-agent"
OLD_UNIT_DIR="$ROOT/etc/systemd/system"
ETC_DIR="$ROOT/etc/cloudviewer-agent"
NEW_DATA_DIR="$ROOT/var/lib/cloudviewer-agent"
OLD_DATA_DIR="$ROOT/var/lib/vector"

usage() {
    cat <<'EOF'
Cloud Viewer agent bootstrap

Usage:
  install:    sh install.sh --token <agent_token> [--facade-url <url>]
              sh install.sh --enroll-token <fleet_token> [--facade-url <url>]
  uninstall:  sh install.sh --uninstall

Options:
  --token <t>         agent token from the Cloud Viewer portal (shown once at
                      server creation). Optional when a pre-provisioned
                      /etc/cloudviewer-agent/agent.env exists (or on migration
                      from an older install — the stored token is reused).
  --enroll-token <t>  fleet enrollment token (portal → Add server → Fleet
                      enrollment): the server self-registers via the Hetzner
                      Cloud metadata service — no per-server portal step.
                      Hetzner Cloud only; dedicated (Robot) servers use
                      --token.
  --facade-url <u>    facade base URL (default https://api.cloudviewer.app)
  --uninstall         remove the agent, its config, and its data
  --help              show this help
EOF
}

log() { printf '%s\n' "$*"; }
fail() {
    printf 'cloudviewer-agent: error: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
    --token)
        [ $# -ge 2 ] || fail "--token needs a value"
        TOKEN="$2"
        shift 2
        ;;
    --enroll-token)
        [ $# -ge 2 ] || fail "--enroll-token needs a value"
        ENROLL_TOKEN="$2"
        shift 2
        ;;
    --facade-url)
        [ $# -ge 2 ] || fail "--facade-url needs a value"
        FACADE_URL="${2%/}"
        shift 2
        ;;
    --uninstall)
        MODE="uninstall"
        shift
        ;;
    --help | -h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        fail "unknown argument: $1"
        ;;
    esac
done

require_environment() {
    command -v curl >/dev/null 2>&1 || fail "required command not found: curl"
    if [ -z "$ROOT" ]; then
        [ "$(id -u)" = "0" ] || fail "run as root (the bootstrap configures package repositories and systemd)"
        [ -d /run/systemd/system ] || fail "systemd is required (no /run/systemd/system)"
    fi
}

# pkg_kind: apt | dnf | yum | none — which package path this host takes.
# CV_AGENT_PKG forces a stub in tests.
pkg_kind() {
    if [ -n "${CV_AGENT_PKG:-}" ]; then
        echo "${CV_AGENT_PKG_KIND:-apt}"
        return
    fi
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo yum
    else
        echo none
    fi
}

pkg_run() {
    if [ -n "${CV_AGENT_PKG:-}" ]; then
        "$CV_AGENT_PKG" "$@"
    else
        "$@"
    fi
}

# ---- repo setup -------------------------------------------------------------

setup_apt_repos() {
    keyring_dir="$ROOT/usr/share/keyrings"
    sources_dir="$ROOT/etc/apt/sources.list.d"
    mkdir -p "$keyring_dir" "$sources_dir"

    log "configuring the Cloud Viewer apt repository ..."
    curl -fsSL "$GET_BASE/keys/cloudviewer.gpg" -o "$keyring_dir/cloudviewer.gpg" ||
        fail "could not download the Cloud Viewer signing key"
    cat >"$sources_dir/cloudviewer.list" <<EOF
deb [signed-by=/usr/share/keyrings/cloudviewer.gpg] $GET_BASE/apt stable main
EOF

    # Vector's own repository (Datadog-operated) supplies the collector
    # binary; this package only depends on it. Skip when vector is already
    # installed — the host has its own arrangement (their repo, their pin)
    # and we must not second-guess it.
    if ! command -v vector >/dev/null 2>&1 && [ ! -f "$sources_dir/vector.list" ]; then
        log "configuring the Vector apt repository (apt.vector.dev) ..."
        # TODO(verify): key list and repo line against the current
        # vector.dev install docs before first release (specs/30 §13).
        rm -f "$keyring_dir/datadog-archive-keyring.gpg"
        for key in DATADOG_APT_KEY_CURRENT.public DATADOG_APT_KEY_C0962C7D.public DATADOG_APT_KEY_F14F620E.public; do
            curl -fsSL "https://keys.datadoghq.com/$key" 2>/dev/null |
                gpg --dearmor >>"$keyring_dir/datadog-archive-keyring.gpg" 2>/dev/null || true
        done
        [ -s "$keyring_dir/datadog-archive-keyring.gpg" ] ||
            fail "could not download the Vector (Datadog) signing keys"
        cat >"$sources_dir/vector.list" <<'EOF'
deb [signed-by=/usr/share/keyrings/datadog-archive-keyring.gpg] https://apt.vector.dev/ stable vector-0
EOF
    fi

    pkg_run apt-get update -qq
    pkg_run apt-get install -y cloudviewer-agent
}

setup_rpm_repos() {
    repos_dir="$ROOT/etc/yum.repos.d"
    mkdir -p "$repos_dir"

    log "configuring the Cloud Viewer rpm repository ..."
    cat >"$repos_dir/cloudviewer.repo" <<EOF
[cloudviewer]
name=Cloud Viewer
baseurl=$GET_BASE/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$GET_BASE/keys/cloudviewer.gpg
EOF

    if ! command -v vector >/dev/null 2>&1 && [ ! -f "$repos_dir/vector.repo" ]; then
        log "configuring the Vector rpm repository (yum.vector.dev) ..."
        # TODO(verify): baseurl/key against the current vector.dev install
        # docs before first release (specs/30 §13).
        cat >"$repos_dir/vector.repo" <<'EOF'
[vector]
name=Vector
baseurl=https://yum.vector.dev/stable/vector-0/$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://keys.datadoghq.com/DATADOG_RPM_KEY_CURRENT.public
EOF
    fi

    pkg_run "$1" install -y cloudviewer-agent
}

# ---- migration from the pre-package layout ----------------------------------

# The old script put Vector at /opt/cloudviewer-agent/bin/vector, wrote units
# into /etc/systemd/system, symlinked cloudviewer-report into /usr/local/bin,
# and (incorrectly — the collision specs/12 §6 forbids) used /var/lib/vector
# as data_dir. agent.env lives at the SAME path the package uses, so the
# token survives migration untouched and postinstall auto-enrolls from it.
migrate_old_layout() {
    [ -d "$OLD_OPT" ] || return 0
    log "migrating pre-package install (found $OLD_OPT) ..."

    "$SYSTEMCTL" disable --now cloudviewer-agent.service cloudviewer-agent-config.timer 2>/dev/null || true
    rm -f "$OLD_UNIT_DIR/cloudviewer-agent.service" \
        "$OLD_UNIT_DIR/cloudviewer-agent-config.service" \
        "$OLD_UNIT_DIR/cloudviewer-agent-config.timer"
    "$SYSTEMCTL" daemon-reload 2>/dev/null || true

    # Buffered data: only claim /var/lib/vector when no foreign Vector
    # service exists — if the customer runs their own Vector, that directory
    # is (also) theirs and must not be touched; losing our old buffers is
    # the safe price.
    if [ -d "$OLD_DATA_DIR" ] && ! "$SYSTEMCTL" is-enabled vector.service >/dev/null 2>&1; then
        mkdir -p "$NEW_DATA_DIR"
        # Move contents, tolerate an empty dir.
        find "$OLD_DATA_DIR" -mindepth 1 -maxdepth 1 -exec mv {} "$NEW_DATA_DIR/" \; 2>/dev/null || true
        rmdir "$OLD_DATA_DIR" 2>/dev/null || true
    fi

    rm -rf "$OLD_OPT"
    rm -f "$ROOT/usr/local/bin/cloudviewer-report"
    log "old layout removed; the stored enrollment token is reused."
}

# ---- install ----------------------------------------------------------------

install_agent() {
    require_environment

    if [ -n "$TOKEN" ] && [ -n "$ENROLL_TOKEN" ]; then
        fail "--token and --enroll-token are mutually exclusive — a server enrolls with one identity"
    fi

    # Nothing to enroll with → fail before touching the system, unless a
    # pre-provisioned/preserved agent.env can complete enrollment (that
    # file may carry either a per-server CV_AGENT_TOKEN or a fleet
    # CV_AGENT_ENROLL_TOKEN — `cloudviewer-agent enroll` handles both).
    if [ -z "$TOKEN" ] && [ -z "$ENROLL_TOKEN" ] && [ ! -f "$ETC_DIR/agent.env" ]; then
        usage >&2
        fail "--token or --enroll-token is required (from the portal's add-server page)"
    fi

    kind="$(pkg_kind)"
    [ "$kind" != "none" ] ||
        fail "no supported package manager (need apt or dnf/yum) — for other platforms see https://github.com/cloudviewer-app/cloudviewer-agent#other-platforms"

    migrate_old_layout

    case "$kind" in
    apt) setup_apt_repos ;;
    dnf) setup_rpm_repos dnf ;;
    yum) setup_rpm_repos yum ;;
    esac

    # Enrollment: an explicit token wins; otherwise postinstall already
    # completed it from the existing agent.env and this is a no-op refresh.
    # --enroll-token passes straight through to the ctl's fleet flow
    # (specs/12 §3): it reads the instance id from the Hetzner metadata
    # service, self-registers, and stores the minted per-server token —
    # and it is a no-op when the host is already enrolled.
    enroll_bin="cloudviewer-agent"
    [ -n "${CV_AGENT_PKG:-}" ] && enroll_bin="${CV_AGENT_ENROLL_BIN:-cloudviewer-agent}"
    if [ -n "$TOKEN" ]; then
        if [ -n "$FACADE_URL" ]; then
            "$enroll_bin" enroll --token "$TOKEN" --facade-url "$FACADE_URL"
        else
            "$enroll_bin" enroll --token "$TOKEN"
        fi
    elif [ -n "$ENROLL_TOKEN" ]; then
        if [ -n "$FACADE_URL" ]; then
            "$enroll_bin" enroll --enroll-token "$ENROLL_TOKEN" --facade-url "$FACADE_URL"
        else
            "$enroll_bin" enroll --enroll-token "$ENROLL_TOKEN"
        fi
    elif [ -f "$ETC_DIR/agent.env" ]; then
        # Covers both pre-provisioned shapes: a CV_AGENT_TOKEN file
        # refreshes in place, a CV_AGENT_ENROLL_TOKEN file (specs/30 §8.2)
        # runs the fleet flow and ends with the minted token only.
        "$enroll_bin" enroll --quiet
        log "enrolled from the existing agent.env."
    fi

    log ""
    log "Cloud Viewer agent installed as a system package."
    log "  contents: dpkg -L cloudviewer-agent   (or: rpm -ql cloudviewer-agent)"
    log "  service:  systemctl status cloudviewer-agent"
    log "  updates:  arrive through your package manager from the signed repo"
}

# ---- uninstall --------------------------------------------------------------

uninstall_agent() {
    require_environment

    # Package-managed install → the package manager owns removal; its purge
    # path deregisters and cleans up (packaging/scripts/postremove.sh).
    if command -v dpkg >/dev/null 2>&1 && dpkg -s cloudviewer-agent >/dev/null 2>&1; then
        pkg_run apt-get purge -y cloudviewer-agent
        return
    fi
    if command -v rpm >/dev/null 2>&1 && rpm -q cloudviewer-agent >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            pkg_run dnf remove -y cloudviewer-agent
        else
            pkg_run yum remove -y cloudviewer-agent
        fi
        return
    fi

    # Legacy (pre-package) layout — same behavior as the old script's
    # --uninstall: best-effort deregistration BEFORE agent.env is deleted.
    DEREGISTERED=""
    if [ -f "$ETC_DIR/agent.env" ]; then
        # shellcheck disable=SC1091
        . "$ETC_DIR/agent.env" 2>/dev/null || true
        if [ -n "${CV_AGENT_TOKEN:-}" ] && [ -n "${CV_AGENT_FACADE_URL:-}" ]; then
            if curl -fsS -m 10 -X POST \
                -H "X-Agent-Token: $CV_AGENT_TOKEN" \
                "$CV_AGENT_FACADE_URL/v1/agent/deregister" >/dev/null 2>&1; then
                DEREGISTERED=1
            fi
        fi
    fi
    "$SYSTEMCTL" disable --now cloudviewer-agent.service cloudviewer-agent-config.timer 2>/dev/null || true
    rm -f "$OLD_UNIT_DIR/cloudviewer-agent.service" \
        "$OLD_UNIT_DIR/cloudviewer-agent-config.service" \
        "$OLD_UNIT_DIR/cloudviewer-agent-config.timer"
    "$SYSTEMCTL" daemon-reload 2>/dev/null || true
    rm -rf "$ETC_DIR" "$OLD_OPT" "$OLD_DATA_DIR" "$NEW_DATA_DIR"
    rm -f "$ROOT/usr/local/bin/cloudviewer-report"
    log "Cloud Viewer agent removed (binary, config, token, units, and buffered data)."
    if [ -n "$DEREGISTERED" ]; then
        log "The server was deregistered: its portal entry shows as retired and disappears after 72 hours."
    else
        log "Deregistration could not be confirmed — it may still have gone through. Check the portal:"
        log "if the server does not show as retired, revoke or delete it there."
    fi
}

case "$MODE" in
install) install_agent ;;
uninstall) uninstall_agent ;;
esac
