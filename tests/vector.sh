#!/usr/bin/env bash
# Vector-level tests: what only the real Vector binary can check. Runs the
# pinned upstream image (timberio/vector:<docker/Dockerfile's
# VECTOR_VERSION>-debian), so it needs docker — nothing else:
#
#   1. `vector validate` of every config render-config can produce (all
#      tiers, manifest v1 and v2, disk health on and off): every rendered
#      shape must load and its VRL must compile.
#   2. `vector test` of the disk-health VRL against the specs/44 golden
#      fixtures (tests/fixtures/disk-health, expectations in
#      tests/disk_health_vector_tests.py), run on a config rendered by
#      render-config itself — the VRL under test is the shipped one.
#   3. End to end, as root in a throwaway container: the UNMODIFIED
#      collector (first without smartctl, then with a stub smartctl that
#      answers with the fixtures), the unmodified reader at its installed
#      path, and Vector running the rendered exec source → console sink,
#      whose text output must be the lines the facade's ingest parses.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDERER="$REPO_DIR/agent/libexec/render-config"
FIXTURES="$REPO_DIR/tests/fixtures/disk-health"
VECTOR_VERSION="$(sed -n 's/^ARG VECTOR_VERSION=//p' "$REPO_DIR/docker/Dockerfile")"
[ -n "$VECTOR_VERSION" ] || {
    echo "FAIL: no ARG VECTOR_VERSION in docker/Dockerfile" >&2
    exit 1
}
IMAGE="timberio/vector:${VECTOR_VERSION}-debian"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
fail() {
    echo "FAIL: $*" >&2
    exit 1
}
ok() {
    PASS=$((PASS + 1))
    echo "ok: $*"
}

command -v docker >/dev/null 2>&1 || fail "docker is required (runs $IMAGE)"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
vector() { docker run --rm -v "$TMP:/work" "$IMAGE" "$@"; }

# render <out> <manifest-lines...>: render-config with the reader present
# (this checkout's agent/libexec) and a fixed identity.
render() {
    out="$1"
    shift
    printf '%s\n' "$@" >"$TMP/manifest"
    env CV_AGENT_TOKEN=golden-token CV_AGENT_FACADE_URL=https://api.example.test \
        CV_AGENT_LIBEXEC_DIR="$REPO_DIR/agent/libexec" \
        sh "$RENDERER" "$TMP/manifest" >"$TMP/$out" || fail "render-config failed for $out"
}

# ---- 1. every rendered shape loads in Vector -------------------------------

shapes=""
for tier in free pro team; do
    journald=true
    auth=false
    [ "$tier" = free ] && journald=false
    [ "$tier" = team ] && auth=true
    render "v1-$tier.yaml" manifest_version=1 "tier=$tier" "ships_journald=$journald" "ships_auth_logs=$auth"
    shapes="$shapes v1-$tier.yaml"
    for disk in true false; do
        render "v2-$tier-disk-$disk.yaml" manifest_version=2 "tier=$tier" "ships_journald=$journald" \
            "ships_auth_logs=$auth" "ships_disk_health=$disk"
        shapes="$shapes v2-$tier-disk-$disk.yaml"
    done
done
for f in $shapes; do
    vector validate --no-environment "/work/$f" >"$TMP/validate.out" 2>&1 ||
        fail "vector validate rejected $f: $(cat "$TMP/validate.out")"
done
ok "vector $VECTOR_VERSION validates all 9 rendered shapes (v1/v2, free/pro/team, disk health on/off)"

# ---- 2. disk-health VRL against the golden fixtures -------------------------

python3 "$REPO_DIR/tests/disk_health_vector_tests.py" "$FIXTURES" >"$TMP/disk-health.tests.json"
vector test /work/v2-pro-disk-true.yaml /work/disk-health.tests.json >"$TMP/test.out" 2>&1 || {
    cat "$TMP/test.out" >&2
    fail "vector test: disk-health VRL failed the golden fixtures"
}
grep '^test ' "$TMP/test.out"
n="$(grep -c '^test .* passed$' "$TMP/test.out")"
[ "$n" -ge 14 ] || fail "expected at least 14 passing vector tests, got $n"
ok "vector test → disk-health VRL matches the specs/44 §9 fixtures ($n tests)"

# ---- 3. end to end: collector → reader → exec source → gauges ----------------

# The rendered free-tier config with disk health on (no journald: the
# container has no journal), its sinks swapped for a console sink that
# writes the same text codec the facade's ingest receives.
sed '/^sinks:/,$d' "$TMP/v2-free-disk-true.yaml" >"$TMP/e2e.yaml"
cat >>"$TMP/e2e.yaml" <<'EOF'
sinks:
  out:
    type: console
    inputs: [disk_health_metrics]
    encoding:
      codec: text
EOF

# smartctl stand-in: a pretty `--scan -j` listing (with a RAID-passthrough
# device and a duplicate the collector must filter), and the robot2
# fixtures as compact JSON with smartctl's real exit status 8 (disk failing).
for d in nvme0 nvme1; do
    python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))' \
        "$FIXTURES/robot2-$d.json" >"$TMP/$d.json"
done
cat >"$TMP/scan.json" <<'EOF'
{
  "json_format_version": [
    1,
    0
  ],
  "smartctl": {
    "version": [
      7,
      4
    ],
    "argv": [
      "smartctl",
      "--scan",
      "-j"
    ],
    "exit_status": 0
  },
  "devices": [
    {
      "name": "/dev/nvme0",
      "info_name": "/dev/nvme0",
      "type": "nvme",
      "protocol": "NVMe"
    },
    {
      "name": "/dev/bus/0",
      "info_name": "/dev/bus/0 [megaraid_disk_00]",
      "type": "megaraid,0",
      "protocol": "SCSI"
    },
    {
      "name": "/dev/nvme1",
      "info_name": "/dev/nvme1",
      "type": "nvme",
      "protocol": "NVMe"
    },
    {
      "name": "/dev/nvme0",
      "info_name": "/dev/nvme0",
      "type": "nvme",
      "protocol": "NVMe"
    }
  ]
}
EOF
cat >"$TMP/smartctl" <<'EOF'
#!/bin/sh
echo "$*" >>/work/argv.log
case "$*" in
"--scan -j") cat /work/scan.json ;;
"--json=c -i -H -A -n standby /dev/nvme0") cat /work/nvme0.json; exit 8 ;;
"--json=c -i -H -A -n standby /dev/nvme1") cat /work/nvme1.json; exit 8 ;;
*) echo "stub smartctl: unexpected argv: $*" >&2; exit 64 ;;
esac
EOF
cat >"$TMP/e2e.sh" <<'EOF'
set -eu
mkdir -p /run/cloudviewer-agent /var/lib/cloudviewer-agent
collect=/usr/libexec/cloudviewer-agent/disk-health-collect
# smartctl absent (the image has no smartmontools)
"$collect"
cp /run/cloudviewer-agent/disk-health.ndjson /work/missing.ndjson
# smartctl present
install -m 0755 /work/smartctl /usr/sbin/smartctl
"$collect"
cp /run/cloudviewer-agent/disk-health.ndjson /work/run.ndjson
stat -c '%a %U' /run/cloudviewer-agent/disk-health.ndjson >/work/mode
ls -A /run/cloudviewer-agent >/work/ls
/usr/libexec/cloudviewer-agent/disk-health-read >/work/read.out
timeout 8 vector --quiet --config /work/e2e.yaml >/work/vector.out 2>/work/vector.err || true
EOF
docker run --rm -v "$TMP:/work" \
    -v "$REPO_DIR/agent/libexec/disk-health-collect:/usr/libexec/cloudviewer-agent/disk-health-collect:ro" \
    -v "$REPO_DIR/agent/libexec/disk-health-read:/usr/libexec/cloudviewer-agent/disk-health-read:ro" \
    --entrypoint sh "$IMAGE" /work/e2e.sh || fail "e2e container failed"

[ "$(wc -l <"$TMP/missing.ndjson" | tr -d ' ')" = 1 ] || fail "without smartctl the file must hold only the status line"
grep -q '"status":"smartctl missing"' "$TMP/missing.ndjson" || fail "missing status line: $(cat "$TMP/missing.ndjson")"
ok "collector without smartctl → only the 'smartctl missing' status line"

printf '%s\n' "--scan -j" \
    "--json=c -i -H -A -n standby /dev/nvme0" \
    "--json=c -i -H -A -n standby /dev/nvme1" >"$TMP/argv.want"
diff -u "$TMP/argv.want" "$TMP/argv.log" || fail "collector ran smartctl with other arguments than the fixed ones"
[ "$(cat "$TMP/mode")" = "644 root" ] || fail "disk-health.ndjson must be 0644 root, got $(cat "$TMP/mode")"
[ "$(cat "$TMP/ls")" = "disk-health.ndjson" ] || fail "temp files left behind: $(cat "$TMP/ls")"
[ "$(wc -l <"$TMP/run.ndjson" | tr -d ' ')" = 3 ] || fail "want 2 device lines + status line"
cmp -s <(head -n 1 "$TMP/run.ndjson") "$TMP/nvme0.json" || fail "smartctl output must be written unchanged"
tail -n 1 "$TMP/run.ndjson" | grep -q '"status":"ok","scan_exit_status":0,"devices":2}}$' ||
    fail "bad status line: $(tail -n 1 "$TMP/run.ndjson")"
ok "collector → fixed argv only, /dev/bus/0 and duplicates filtered, raw lines + status, atomic 0644"

grep -v -E '^(smart|mdstat)	' "$TMP/read.out" && fail "reader printed an unprefixed line"
[ "$(grep -c '^smart	' "$TMP/read.out")" = 3 ] || fail "reader must print the collector's 3 lines"
ok "reader → every line prefixed smart<TAB> / mdstat<TAB>"

out="$TMP/vector.out"
[ -s "$out" ] || fail "vector produced no metrics: $(cat "$TMP/vector.err")"
for want in \
    'disk_smart_critical_warning{device="nvme0"} = 4' \
    'disk_smart_critical_warning{device="nvme1"} = 4' \
    'disk_smart_passed{device="nvme0",model="SAMSUNG MZVLB512HBJQ-00007",serial="FIXTURE-R2-N0"} = 0' \
    'disk_smart_percentage_used{device="nvme1"} = 171' \
    'disk_smart_written_bytes{device="nvme0"} = 286754639872000' \
    'disk_smart_available_spare_threshold_ratio{device="nvme0"} = 0.1' \
    'disk_smart_up{device="nvme1"} = 1'; do
    grep -qF " $want" "$out" || fail "e2e output lacks: $want"$'\n'"$(cat "$out")"
done
grep -qE ' disk_health_collected_timestamp_seconds\{\} = [0-9]{10}$' "$out" || fail "e2e output lacks the collected timestamp"
grep -q 'bus' "$out" && fail "a filtered device reached the output"
# Vector's native metric text, the shape facade/internal/metrics parses:
# <RFC3339> name{tags} = value — absolute gauges only.
bad="$(grep -v -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z [a-z_]+\{[^}]*\} = [0-9.e+-]+$' "$out" || true)"
[ -z "$bad" ] || fail "lines the facade ingest would not take as absolute gauges:"$'\n'"$bad"
ok "e2e → exec source (bytes framing) + VRL + log_to_metric ship $(wc -l <"$out" | tr -d ' ') absolute gauges in the ingest's text format"

echo
echo "all $PASS vector tests passed"
