#!/usr/bin/env python3
"""Vector unit tests for the disk-health VRL (specs/44 §9), as JSON.

Usage: disk_health_vector_tests.py <fixtures-dir> > disk-health.tests.json

tests/vector.sh runs the output with `vector test` together with a
vector.yaml rendered by render-config itself, so what is tested is exactly
the VRL a host runs — there is no second copy of it anywhere.

Each scenario feeds one disk-health-read run (the lines that helper prints:
`smart<TAB>…` and `mdstat<TAB>…`) into disk_health_parse and checks the one
event it emits, `{"metrics": [...]}`:

  * every expected gauge is present exactly once with exactly these labels
    and this value, and the array holds nothing else (so "no series" and
    "dropped" are real assertions, not the absence of a check);
  * the §5 instant alert rules the §9 table names (critical: critical
    warning > 0, verdict failed, array degraded; warning: wear >= 100 %)
    fire for exactly the listed series.

Values below are literals from the fixtures (the §9 table), never derived
from the fixture files by this script.
"""

import json
import os
import sys

FIXTURES = sys.argv[1]
STATUS_TIME = 1759500000  # the collector's status-line timestamp in every scenario


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


def smart(doc):
    """One smartctl line as the collector writes it (--json=c: compact)."""
    if isinstance(doc, str):
        doc = json.loads(fixture(doc))
    return "smart\t" + json.dumps(doc, separators=(",", ":"), ensure_ascii=False)


def status(**extra):
    st = {"time": STATUS_TIME, "status": "ok", "scan_exit_status": 0, "devices": 2}
    st.update(extra)
    return smart({"cloudviewer_disk_health": st})


def mdstat(text):
    """/proc/mdstat as disk-health-read prints it, one prefixed line each."""
    if text.endswith(".txt"):
        text = fixture(text)
    return ["mdstat\t" + line for line in text.split("\n")[:-1]]


def run(*parts):
    lines = []
    for p in parts:
        lines.extend(p if isinstance(p, list) else [p])
    return "\n".join(lines) + "\n"


# ---- expectations -----------------------------------------------------------


def g(name, value, **tags):
    return (name, tags, float(value))


def collected():
    return [g("disk_health_collected_timestamp_seconds", STATUS_TIME)]


def nvme(dev, model, serial, *, passed, cw, pct, spare, thr, media, temp, hours, written_units, unsafe):
    return [
        g("disk_smart_up", 1, device=dev),
        g("disk_smart_passed", passed, device=dev, model=model, serial=serial),
        g("disk_smart_critical_warning", cw, device=dev),
        g("disk_smart_percentage_used", pct, device=dev),
        g("disk_smart_available_spare_ratio", spare, device=dev),
        g("disk_smart_available_spare_threshold_ratio", thr, device=dev),
        g("disk_smart_media_errors", media, device=dev),
        g("disk_smart_temperature_celsius", temp, device=dev),
        g("disk_smart_power_on_hours", hours, device=dev),
        g("disk_smart_written_bytes", written_units * 512000, device=dev),
        g("disk_smart_unsafe_shutdowns", unsafe, device=dev),
    ]


def array(name, *, disks=None, active=None, degraded, sync):
    out = []
    if disks is not None:
        out += [g("md_array_disks", disks, array=name), g("md_array_disks_active", active, array=name)]
    return out + [g("md_array_degraded", degraded, array=name), g("md_array_sync_ratio", sync, array=name)]


ROBOT1 = nvme("nvme0", "KXG60ZNV512G TOSHIBA", "FIXTURE-R1-N0", passed=1, cw=0, pct=188, spare=1, thr=0.1,
              media=0, temp=48, hours=53811, written_units=635442948, unsafe=4) + \
    nvme("nvme1", "KXG60ZNV512G TOSHIBA", "FIXTURE-R1-N1", passed=1, cw=0, pct=201, spare=1, thr=0.1,
         media=0, temp=45, hours=53812, written_units=622522482, unsafe=4)
ROBOT2 = nvme("nvme0", "SAMSUNG MZVLB512HBJQ-00007", "FIXTURE-R2-N0", passed=0, cw=4, pct=171, spare=1, thr=0.1,
              media=0, temp=28, hours=43996, written_units=560067656, unsafe=1) + \
    nvme("nvme1", "SAMSUNG MZVLB512HBJQ-00007", "FIXTURE-R2-N1", passed=0, cw=4, pct=171, spare=1, thr=0.1,
         media=0, temp=31, hours=42629, written_units=558361707, unsafe=1)
CLEAN3 = [m for a in ("md127", "md0", "md1") for m in array(a, disks=2, active=2, degraded=0, sync=1)]

# ---- synthetic inputs for the §4 sandbox rules ------------------------------

ATA_SSD = {
    "json_format_version": [1, 0],
    "smartctl": {"version": [7, 4], "exit_status": 0},
    "device": {"name": "/dev/sda", "info_name": "/dev/sda [SAT]", "type": "sat", "protocol": "ATA"},
    "model_name": "Samsung SSD 870 EVO 1TB",
    "serial_number": "S6PTNX0R000001",
    "smart_status": {"passed": True},
    "ata_smart_attributes": {"revision": 1, "table": [
        {"id": 233, "name": "Media_Wearout_Indicator", "value": 50, "worst": 50, "thresh": 0, "raw": {"value": 0, "string": "0"}},
        {"id": 5, "name": "Reallocated_Sector_Ct", "value": 100, "worst": 100, "thresh": 10, "raw": {"value": 3, "string": "3"}},
        {"id": 9, "name": "Power_On_Hours", "value": 97, "worst": 97, "thresh": 0, "raw": {"value": 12000, "string": "12000"}},
        {"id": 177, "name": "Wear_Leveling_Count", "value": 93, "worst": 93, "thresh": 0, "raw": {"value": 61, "string": "61"}},
        {"id": 197, "name": "Current_Pending_Sector", "value": 100, "worst": 100, "thresh": 0, "raw": {"value": 1, "string": "1"}},
        {"id": 198, "name": "Offline_Uncorrectable", "value": 100, "worst": 100, "thresh": 0, "raw": {"value": 0, "string": "0"}},
    ]},
    "temperature": {"current": 31},
    "power_on_time": {"hours": 12000},
}

# Firmware that starts its wear attribute above 100: 231 is preferred over
# 233, and 1 - 120/100 clamps to 0.
ATA_FRESH = {
    "smartctl": {"exit_status": 0},
    "device": {"name": "/dev/sdb", "type": "sat", "protocol": "ATA"},
    "ata_smart_attributes": {"table": [
        {"id": 233, "name": "Media_Wearout_Indicator", "value": 80, "raw": {"value": 0}},
        {"id": 231, "name": "SSD_Life_Left", "value": 120, "raw": {"value": 0}},
    ]},
}

# -n standby on a sleeping HDD: smartctl answers exit 2 and skips the disk.
STANDBY = {
    "json_format_version": [1, 0],
    "smartctl": {"version": [7, 4], "argv": ["smartctl", "--json=c", "-i", "-H", "-A", "-n", "standby", "/dev/sdb"],
                 "messages": [{"string": "Device is in STANDBY mode, exit(2)", "severity": "information"}],
                 "exit_status": 2},
    "device": {"name": "/dev/sdb", "info_name": "/dev/sdb [SAT]", "type": "sat", "protocol": "ATA"},
}
# Open failure: no device object at all, the name only in argv.
OPEN_FAILED = {
    "json_format_version": [1, 0],
    "smartctl": {"version": [7, 4], "argv": ["smartctl", "--json=c", "-i", "-H", "-A", "-n", "standby", "/dev/sdc"],
                 "messages": [{"string": "Smartctl open device: /dev/sdc failed: No such device", "severity": "error"}],
                 "exit_status": 2},
}


def minimal(dev, exit_status=0, **extra):
    doc = {"smartctl": {"exit_status": exit_status}, "device": {"name": dev}}
    doc.update(extra)
    return doc


HOSTILE_MODEL = minimal(
    "/dev/nvme7",
    model_name='  <Evil>"Model"; rm -rf /ÄÖ 0123456789012345678901234567890123456789  ',
    serial_number="S3R1AL\u0000\n{x}",
    smart_status={"passed": True},
)

MDSTAT_EDGE = """Personalities : [raid1] [raid0]
md_d0 : active raid1 sda1[0] sdb1[1]
      100 blocks [2/2] [UU]

md5 : active raid1 sdc1[0](F) sdd1[1]
      100 blocks super 1.2 [2/2] [UU]

md6 : inactive sde1[0](S)
      100 blocks super 1.2

md7 : active raid1 sdf1[1] sdg1[0]
      100 blocks super 1.2 [2/2] [UU]
      [==========>..........]  check = 50.0% (50/100) finish=1.0min speed=1K/sec

md8 : active raid1 sdh1[1] sdi1[0]
      100 blocks super 1.2 [2/1] [U_]
      [==>..................]  recovery = 12.6% (13/100) finish=1.0min speed=1K/sec

md9 : active raid1 sdj1[1] sdk1[0]
      100 blocks super 1.2 [2/2] [UU]
      \tresync=DELAYED

md10 : active raid0 sdl1[1] sdm1[0]
      200 blocks super 1.2 512k chunks
      
md11 : active raid0 sdn1[1] sdo1[0](F)
      200 blocks super 1.2 512k chunks

unused devices: <none>
"""

# (name, reader output, expected gauges, expected alerts)
SCENARIOS = [
    ("robot1: Toshiba 188/201 % worn yet PASSED, clean RAID1 -> wear warnings, no critical",
     run(smart("robot1-nvme0.json"), smart("robot1-nvme1.json"), status(), mdstat("robot1-mdstat.txt")),
     collected() + ROBOT1 + CLEAN3,
     ["warning worn_out nvme0", "warning worn_out nvme1"]),
    ("robot2: Samsung critical_warning 0x04, verdict failed -> both criticals, no md series",
     run(smart("robot2-nvme0.json"), smart("robot2-nvme1.json"), status(), mdstat("robot2-mdstat.txt")),
     collected() + ROBOT2,
     ["critical critical_warning nvme0", "critical critical_warning nvme1",
      "critical passed nvme0", "critical passed nvme1",
      "warning worn_out nvme0", "warning worn_out nvme1"]),
    ("robot1-mdstat: three arrays, none degraded, sync 1",
     run(mdstat("robot1-mdstat.txt")),
     CLEAN3, []),
    ("degraded-mdstat: md127 and md0 (F) degraded, md1 clean",
     run(mdstat("degraded-mdstat.txt")),
     array("md127", disks=2, active=1, degraded=1, sync=1)
     + array("md0", disks=2, active=1, degraded=1, sync=1)
     + array("md1", disks=2, active=2, degraded=0, sync=1),
     ["critical degraded md127", "critical degraded md0"]),
    ("resync-mdstat: md1 sync ratio 0.074",
     run(mdstat("resync-mdstat.txt")),
     array("md127", disks=2, active=2, degraded=0, sync=1)
     + array("md0", disks=2, active=2, degraded=0, sync=1)
     + array("md1", disks=2, active=2, degraded=0, sync=0.074),
     []),
    ("robot2-mdstat: no arrays, no series",
     run(mdstat("robot2-mdstat.txt")),
     [], []),
    ("mdstat edge cases: (F) alone degrades, check/recovery/DELAYED progress, no [n/m] counts members, bad names dropped",
     run(mdstat(MDSTAT_EDGE)),
     array("md5", disks=2, active=2, degraded=1, sync=1)
     # inactive, only a spare: spares are neither expected nor active
     + array("md6", disks=0, active=0, degraded=0, sync=1)
     + array("md7", disks=2, active=2, degraded=0, sync=0.5)
     + array("md8", disks=2, active=1, degraded=1, sync=0.126)
     + array("md9", disks=2, active=2, degraded=0, sync=0)
     # raid0 has no [n/m]: members counted, (F) expected but not active
     + array("md10", disks=2, active=2, degraded=0, sync=1)
     + array("md11", disks=2, active=1, degraded=1, sync=1),
     ["critical degraded md5", "critical degraded md8", "critical degraded md11"]),
    ("smartctl missing: only the collector's status line",
     run(smart({"cloudviewer_disk_health": {"time": STATUS_TIME, "status": "smartctl missing"}}), mdstat("robot2-mdstat.txt")),
     collected(), []),
    ("ATA SSD: attributes 5/197/198 raw, wear 1 - normalized/100 preferring 177, then 231, then 233, clamped",
     run(smart(ATA_SSD), smart(ATA_FRESH), status()),
     collected() + [
         g("disk_smart_up", 1, device="sda"),
         g("disk_smart_passed", 1, device="sda", model="Samsung SSD 870 EVO 1TB", serial="S6PTNX0R000001"),
         g("disk_smart_temperature_celsius", 31, device="sda"),
         g("disk_smart_power_on_hours", 12000, device="sda"),
         g("disk_smart_reallocated_sectors", 3, device="sda"),
         g("disk_smart_pending_sectors", 1, device="sda"),
         g("disk_smart_offline_uncorrectable", 0, device="sda"),
         g("disk_smart_wear_ratio", 1 - 93 / 100, device="sda"),
         g("disk_smart_up", 1, device="sdb"),
         g("disk_smart_wear_ratio", 0, device="sdb"),
     ], []),
    ("not answered (exit bits 1/2/4, or no exit status): up 0 and nothing else; 8 = failing still answers",
     run(smart(STANDBY), smart(OPEN_FAILED),
         smart(minimal("/dev/sdd", exit_status=4, smart_status={"passed": True}, temperature={"current": 40})),
         smart(minimal("/dev/sde", exit_status=1, temperature={"current": 40})),
         smart({"device": {"name": "/dev/sdf"}, "temperature": {"current": 40}}),
         smart(minimal("/dev/sdg", exit_status=8 | 64, temperature={"current": 40}))),
     [g("disk_smart_up", 0, device=d) for d in ("sdb", "sdc", "sdd", "sde", "sdf")]
     + [g("disk_smart_up", 1, device="sdg"), g("disk_smart_temperature_celsius", 40, device="sdg")], []),
    ("device filter: partitions, passthrough, odd names dropped; whole disks kept",
     run(*[smart(minimal(d)) for d in
           ("/dev/sda1", "/dev/bus/0", "/dev/nvme0n1", "/dev/sdA", "/dev/nvme", "/dev/../dev/sda", "sdd", "/dev/sdb")]),
     [g("disk_smart_up", 1, device="sdb")], []),
    ("label hygiene: model and serial cut to 40 chars of [A-Za-z0-9 ._-]",
     run(smart(HOSTILE_MODEL)),
     [g("disk_smart_up", 1, device="nvme7"),
      g("disk_smart_passed", 1, device="nvme7", model="  EvilModel rm -rf  01234567890123456789", serial="S3R1ALx")],
     []),
    ("garbage is ignored: unprefixed lines, bad JSON, non-numeric values",
     run("hello", "smart\tnot json", "smart\t[1,2]", "mdstat\t", "smartish\t{}",
         smart(minimal("/dev/nvme0", nvme_smart_health_information_log={"percentage_used": "188", "media_errors": None}))),
     [g("disk_smart_up", 1, device="nvme0")], []),
]


def vrl_float(v):
    return "%d.0" % v if v == int(v) else repr(v)


def vrl_tags(tags):
    if not tags:
        return "null"
    return "{" + ", ".join("%s: %s" % (json.dumps(k), json.dumps(v)) for k, v in sorted(tags.items())) + "}"


def vrl(source):
    return {"type": "vrl", "source": source}


ALERTS = """fired = []
for_each(array!(.metrics)) -> |_i, m| {
  v = float(m.gauge.value) ?? -1.0
  who = string(m.tags.device) ?? string(m.tags.array) ?? ""
  if m.name == "disk_smart_critical_warning" && v > 0 { fired = push(fired, "critical critical_warning " + who) }
  if m.name == "disk_smart_passed" && v == 0 { fired = push(fired, "critical passed " + who) }
  if m.name == "md_array_degraded" && v == 1 { fired = push(fired, "critical degraded " + who) }
  if m.name == "disk_smart_percentage_used" && v >= 100 { fired = push(fired, "warning worn_out " + who) }
}
"""


def conditions(expected, alerts):
    out = [vrl("length(array!(.metrics)) == %d" % len(expected))]
    seen = set()
    for name, tags, value in expected:
        key = (name, tuple(sorted(tags.items())))
        assert key not in seen, "duplicate expectation %r" % (key,)
        seen.add(key)
        out.append(vrl(
            "length(filter(array!(.metrics)) -> |_i, m| { m.name == %s && m.tags == %s && m.gauge.value == %s && m.kind == \"absolute\" }) == 1"
            % (json.dumps(name), vrl_tags(tags), vrl_float(value))))
    out.append(vrl(ALERTS + " && ".join(
        ["length(fired) == %d" % len(alerts)] + ["includes(fired, %s)" % json.dumps(a) for a in alerts])))
    return out


def main():
    tests = []
    for name, message, expected, alerts in SCENARIOS:
        test = {
            "name": "disk health: " + name,
            "inputs": [{"insert_at": "disk_health_parse", "type": "log", "log_fields": {"message": message}}],
            "outputs": [{"extract_from": "disk_health_parse", "conditions": conditions(expected, alerts)}],
        }
        if not expected:
            # Nothing to ship must mean nothing reaches the sink.
            test["no_outputs_from"] = ["disk_health_split", "disk_health_metrics"]
        tests.append(test)

    # One pass through the whole chain: the fan-out and log_to_metric turn
    # the array into real gauge events with exactly these names and labels.
    tests.append({
        "name": "disk health: robot1 through log_to_metric -> absolute gauges",
        "inputs": [{"insert_at": "disk_health_parse", "type": "log",
                    "log_fields": {"message": SCENARIOS[0][1]}}],
        "outputs": [{"extract_from": "disk_health_metrics", "conditions": [
            vrl('.name == "disk_smart_percentage_used" && .tags == {"device": "nvme1"} && .kind == "absolute" && .type == "gauge"'),
            vrl('.name == "disk_smart_passed" && .tags == {"device": "nvme0", "model": "KXG60ZNV512G TOSHIBA", "serial": "FIXTURE-R1-N0"} && .type == "gauge"'),
            vrl('.name == "md_array_sync_ratio" && .tags == {"array": "md127"} && .type == "gauge"'),
            vrl('.name == "disk_health_collected_timestamp_seconds" && .type == "gauge"'),
        ]}],
    })
    json.dump({"tests": tests}, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")


main()
