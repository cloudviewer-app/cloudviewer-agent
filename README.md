# cloudviewer-agent

The monitoring agent for [Cloud Viewer](https://cloudviewer.app), packaged
for easy, verifiable installs. The collector is upstream
[Vector](https://vector.dev) — this project deliberately ships **no
binaries of its own**, only the small, readable pieces around it:
enrollment, config polling, job reporting, systemd units, a container
image, and a Helm chart.

## What gets installed

The complete contents of the `cloudviewer-agent` package — this list is the
contract, verifiable any time with `dpkg -L cloudviewer-agent` /
`rpm -ql cloudviewer-agent` and `dpkg --verify` / `rpm -V`:

```
/usr/bin/cloudviewer-agent                        enroll | status | render | enable/disable disk-health | uninstall
/usr/bin/cloudviewer-report                       cron-job report wrapper
/usr/libexec/cloudviewer-agent/fetch-config       per-minute manifest poller (ETag GET)
/usr/libexec/cloudviewer-agent/render-config      manifest → vector.yaml renderer (see Security)
/usr/libexec/cloudviewer-agent/fleet-enroll       fleet self-registration (shared with the container)
/usr/libexec/cloudviewer-agent/disk-health-collect  root SMART collector (opt-in, see Disk health)
/usr/libexec/cloudviewer-agent/disk-health-read   unprivileged reader Vector runs for disk health
/usr/lib/systemd/system/cloudviewer-agent.service
/usr/lib/systemd/system/cloudviewer-agent-config.service
/usr/lib/systemd/system/cloudviewer-agent-config.timer
/usr/lib/systemd/system/cloudviewer-disk-health.service   shipped disabled
/usr/lib/systemd/system/cloudviewer-disk-health.timer     shipped disabled
/usr/lib/tmpfiles.d/cloudviewer-agent.conf        creates /run/cloudviewer-agent
/usr/share/doc/cloudviewer-agent/README.md        this file
```

The package `Recommends: smartmontools` (for disk health; not required).

The Vector binary comes from the `vector` package the above depends on,
installed from [Vector's own signed repositories](https://vector.dev/docs/setup/installation/).
Runtime state lives in `/etc/cloudviewer-agent/` (token, the cached
parameter manifest, and the locally rendered config — owned by the
dedicated `cloudviewer-agent` user the config poller runs as, with the
directory setgid `vector` so the rendered config is group-readable by the
unprivileged `vector` user the service runs as; the token file itself is
0600 and not group-readable) and `/var/lib/cloudviewer-agent/` (Vector's
buffers, owned by `vector` — deliberately not `/var/lib/vector`, so a
Vector instance of your own can run alongside untouched).

## Install

Quick start (configures both signed repos, installs the package, enrolls):

```sh
curl -fsSL https://get.cloudviewer.app/agent | sh -s -- --token <agent_token>
```

Or the same thing by hand on Debian/Ubuntu:

```sh
curl -fsSL https://get.cloudviewer.app/keys/cloudviewer.gpg \
  -o /usr/share/keyrings/cloudviewer.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudviewer.gpg] https://get.cloudviewer.app/apt stable main" \
  > /etc/apt/sources.list.d/cloudviewer.list
# + Vector's repo per https://vector.dev/docs/setup/installation/package-managers/apt/
apt update && apt install cloudviewer-agent
cloudviewer-agent enroll --token <agent_token>
```

RHEL-family: the matching `.repo` files against `https://get.cloudviewer.app/rpm`
and `yum.vector.dev`, then `dnf install cloudviewer-agent`.

The package installs **inert** — nothing starts until `enroll` writes the
identity. The token is shown once in the Cloud Viewer portal when the
server is added.

### Fleet enrollment (Hetzner Cloud)

For many servers, skip per-server tokens entirely: mint a **fleet
enrollment token** in the portal (Add server → Fleet enrollment) and use
the same token everywhere:

```sh
cloudviewer-agent enroll --enroll-token <fleet_token>
```

Each server reads its own identity from the Hetzner Cloud metadata
service, self-registers (the facade verifies the claimed instance against
your project's inventory before trusting it), and receives its own
per-server token — the fleet token enrolls, it never ingests, and it is
never stored on the host. Re-running is a network-free no-op once
enrolled, so the command is safe in every configuration-management
converge. Hetzner Cloud only: dedicated (Robot) servers have no metadata
service and use `--token`.

### Declarative automation

`cloudviewer-agent enroll` with no flags completes enrollment from a
pre-provisioned `/etc/cloudviewer-agent/agent.env` — the one convention
every tool uses the same way:

```yaml
# cloud-init (Terraform user_data)
apt:
  sources: { cloudviewer: {...}, vector: {...} }
packages: [cloudviewer-agent]
write_files:
  - path: /etc/cloudviewer-agent/agent.env
    permissions: "0600"
    content: "CV_AGENT_TOKEN=${token}\n"
runcmd:
  - cloudviewer-agent enroll
```

(The package's postinstall even runs that enroll for you when `agent.env`
already exists at install time.) Ansible: `apt` module + `copy` the env
file + a handler running `cloudviewer-agent enroll`. Re-running enroll is
always safe; running it with a new token rotates the token in place.

### Disk health (SMART and software RAID, dedicated servers)

Off until you switch it on, on the server itself:

```sh
cloudviewer-agent enable disk-health      # or: install.sh ... --with-disk-health
cloudviewer-agent disable disk-health
```

This enables a 5-minute timer for `cloudviewer-disk-health.service`, a
root job (SMART needs `CAP_SYS_ADMIN`/`CAP_SYS_RAWIO`) sandboxed by
systemd: no network at all, read-only filesystem except
`/run/cloudviewer-agent`, only disk devices, read-only. It runs
`smartctl --scan -j`, then `smartctl --json=c -i -H -A -n standby <disk>`
for each whole disk — identify, health and attributes only, never a
self-test, never waking a sleeping disk — and writes the raw output to
`/run/cloudviewer-agent/disk-health.ndjson`. It reads nothing from Cloud
Viewer. Vector (unprivileged) reads that file and `/proc/mdstat` through
`disk-health-read` and turns them into gauges: wear, critical warnings,
media errors, spare, temperature, hours, data written, ATA sector counts,
and per md array the member counts, degraded state and resync progress.
Each drive's model and serial number are shipped once (as labels of
`disk_smart_passed`), because a drive-replacement request needs them.

Shipping additionally needs the facade's `ships_disk_health` parameter
(your plan); without `smartmontools` the collector only reports
`smartctl missing`. The container image and Helm chart do not collect disk
health.

### Version pinning

The package depends on `vector (>= <tested version>)`; each release train
raises the floor after re-verifying. For strict pins, Vector's repos retain
full version history, so classic apt preferences / `dnf versionlock` work:

```
# /etc/apt/preferences.d/vector
Package: vector
Pin: version 0.57.0-1
Pin-Priority: 1001
```

### Container

```sh
docker run -d --name cloudviewer-agent --restart always \
  -e CV_AGENT_TOKEN=<token> \
  -v /proc:/host/proc:ro -v /sys:/host/sys:ro -v /:/host/root:ro \
  -e PROCFS_ROOT=/host/proc -e SYSFS_ROOT=/host/sys \
  ghcr.io/cloudviewer-app/cloudviewer-agent:<version>
```

### Kubernetes

Use a fleet enrollment token — each node self-registers as its own
server, and node replacement re-enrolls automatically:

```sh
kubectl create secret generic cloudviewer-agent \
  --from-literal=enroll-token=<fleet_enrollment_token>
helm install cloudviewer-agent \
  oci://ghcr.io/cloudviewer-app/charts/cloudviewer-agent \
  --set existingSecret=cloudviewer-agent
```

A per-server token (Secret key `token`) also works but only makes sense
on a single-node cluster — one token across a DaemonSet reports every
node as the same server. Details and caveats:
`charts/cloudviewer-agent/README.md`.

### Other platforms

No apt/dnf (Alpine, NixOS, …): use the container image above, or install
the files from `agent/` manually — they are plain POSIX sh plus five
systemd units and a tmpfiles.d entry, and the file list at the top of this page is complete.

## Uninstall

```sh
apt purge cloudviewer-agent    # or: dnf remove cloudviewer-agent
```

Purge deregisters the server (its portal entry retires and disappears
after 72 h) and removes config, token, and buffered data. Plain
`apt remove` keeps them, per distro convention. Without a package manager:
`cloudviewer-agent uninstall`.

## Security

- **The facade sends parameters, the host renders the config.** The agent
  never installs server-supplied configuration. It polls a tiny key=value
  parameter manifest (`tier`, `ships_journald`, `ships_auth_logs`,
  `ships_disk_health`; conditional GET every minute), validates it
  against a strict schema —
  unknown key, unknown version, or anything that is not a manifest is
  rejected and the last config kept — and `render-config` renders
  `vector.yaml` locally, injecting the token and facade URL from
  `agent.env` (they never travel inside a server response). Every
  structural byte of the running config ships in this package and is
  pinned by the golden fixtures in `tests/golden/`; a compromised server
  can at worst flip the documented toggles, never deliver components,
  paths, sinks, or code.
- **Disk health keeps the facade away from root.** Its one root piece,
  the SMART collector, ships disabled, is enabled only by you on the host,
  takes no input, has no network, and runs `smartctl` with fixed read-only
  arguments. The facade's `ships_disk_health` bool only decides whether the
  unprivileged Vector *reads* the result, via a helper at a fixed path that
  the renderer adds only if it is installed — no manifest string reaches
  that config, and the poller and renderer never touch systemd units
  (pinned by `tests/run.sh`).
- **Nothing runs as root after enrollment (except the opt-in disk-health
  collector above) — two unprivileged users, on purpose.** The collector service runs as the `vector` user (journald +
  auth.log access via its groups), with `NoNewPrivileges` and a validated
  config (`vector validate` before every start). The per-minute config
  poller runs as a dedicated `cloudviewer-agent` user that owns
  `/etc/cloudviewer-agent` (setgid `vector`). Two users because the
  privilege separation must cut both ways: the poller is the
  network-facing curl/parse surface, so compromising it yields an
  unprivileged account and not root — while the `vector` user can read
  the configs the poller writes but can never write its own config (or
  read the token). Only the operator-run commands (`enroll`, `render`,
  `uninstall`) touch the system as root.
- Packages come from a GPG-signed repo; the signing key fingerprint is
  published at cloudviewer.app and here: `TODO: fingerprint after key
  ceremony`. Releases carry SBOMs and build provenance attestations; the
  repository's own hardening is documented in
  [docs/github-config.md](docs/github-config.md).
- Vulnerabilities: see [SECURITY.md](SECURITY.md).

## Development

```sh
bash tests/run.sh        # full harness: stub facade, no root/systemd needed
bash tests/vector.sh     # real Vector (docker): validate, VRL unit tests, disk-health e2e
shellcheck agent/bin/* agent/libexec/* packaging/scripts/*.sh install.sh
VERSION=0.0.0+dev nfpm package -f packaging/nfpm.yaml -p deb -t dist/
```

Everything an installed host runs lives under `agent/` — seven small POSIX
sh files, five units and one tmpfiles.d entry. CI (shellcheck, `dash -n`,
the harness, the Vector tests, the disk-health unit's `systemd-analyze
security` gate, package dry-builds, chart lint) runs on every PR.

## License

Apache-2.0. "Cloud Viewer" (the name and logo) is not covered by the
code license.
