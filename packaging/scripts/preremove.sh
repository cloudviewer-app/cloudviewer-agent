#!/bin/sh
# shellcheck shell=sh
# preremove for cloudviewer-agent (shared by deb and rpm via nfpm).
#
# deb passes "remove"/"upgrade"/...; rpm passes 0 (erase) or 1 (upgrade).
# On an rpm upgrade the units must stay up — postinstall of the new version
# re-asserts them; stopping here would open a monitoring gap.
set -e

case "${1:-}" in
upgrade | 1)
    :
    ;;
*)
    systemctl disable --now cloudviewer-agent.service cloudviewer-agent-config.timer >/dev/null 2>&1 || true
    ;;
esac
