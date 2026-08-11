# cloudviewer-agent Helm chart

Runs the [Cloud Viewer](https://cloudviewer.app) monitoring agent as a
DaemonSet: one pod per node, `hostNetwork`, read-only mounts of the host's
`/proc`, `/sys`, and `/`, shipping node metrics to the Cloud Viewer facade.

The chart is deliberately minimal — a fixed DaemonSet shape with ~5 knobs,
readable in one sitting. It does not expose Vector's configuration: the
agent's Vector config is rendered by the Cloud Viewer portal and fetched by
the agent itself. If you want a general-purpose Vector deployment, use
[Vector's own chart](https://github.com/vectordotdev/helm-charts) instead.

## Which credential — read this first

The chart understands two credentials, and picking the right one matters:

- **Fleet enrollment token** (Secret key `enroll-token`) — **use this for
  clusters.** Minted in the portal (Add server → Fleet enrollment), one
  token for the whole fleet: each node reads its own Hetzner instance id
  from the metadata service (hence the chart's fixed `hostNetwork`),
  self-registers as its own server, and receives its own per-server
  ingest token. The facade verifies every claimed instance against your
  project's inventory before trusting it; the fleet token itself can
  enroll but never ingest, and it never persists inside the pod. Pod
  restarts and node replacements re-enroll idempotently — a replaced
  node's old server row retires automatically when the old machine
  disappears from your Hetzner project (specs/12 §12.2).
- **Per-server token** (Secret key `token`) — **single-node clusters
  only** (k3s/k0s on one box). A DaemonSet sharing one per-server token
  makes every node report as the same server, overwriting each other's
  metrics. If both keys exist, the per-server token wins.

Non-Hetzner-Cloud nodes cannot use fleet enrollment (no metadata
service); their pods will crash-loop with a message saying exactly that.

## Install

Create the Secret yourself (recommended — no credential ever touches
values files or Helm release state), then install pointing at it:

```sh
kubectl create secret generic cloudviewer-agent \
  --from-literal=enroll-token=<fleet_enrollment_token>

helm install cloudviewer-agent oci://ghcr.io/cloudviewer-app/charts/cloudviewer-agent \
  --set existingSecret=cloudviewer-agent
```

Quick start alternative (discouraged beyond a first try — the credential
ends up in your shell history and in Helm's release Secret):

```sh
helm install cloudviewer-agent oci://ghcr.io/cloudviewer-app/charts/cloudviewer-agent \
  --set enrollToken=<fleet_enrollment_token>
```

For a single-node cluster with a per-server token, use
`--from-literal=token=<agent_token>` / `--set token=…` instead.

## Values

| Key | Default | Meaning |
|---|---|---|
| `image.repository` | `ghcr.io/cloudviewer-app/cloudviewer-agent` | Agent image. |
| `image.tag` | `""` (chart `appVersion`) | Image tag; empty follows the chart's app version. |
| `image.digest` | `""` | `sha256:…` digest pin — preferred over tag when set (immutable). |
| `image.pullPolicy` | `IfNotPresent` | Tags are immutable per release. |
| `existingSecret` | `""` | Name of a Secret with key `enroll-token` (fleet) and/or `token` (per-server). **The documented path.** |
| `token` | `""` | Quick start only: per-server token; chart creates the Secret. Single-node clusters only. |
| `enrollToken` | `""` | Quick start only: fleet enrollment token; chart creates the Secret. |
| `facadeUrl` | `https://api.cloudviewer.app` | Facade base URL. |
| `resources` | small requests, 256Mi limit | Pod resources. |
| `tolerations` | `[]` | E.g. tolerate control-plane taints to cover masters. |
| `nodeSelector` | `{}` | Restrict which nodes run the agent. |
| `podAnnotations` | `{}` | Extra pod annotations. |
| `priorityClassName` | `""` | Keep the agent scheduled under node pressure. |

One of `existingSecret` / `enrollToken` / `token` is required (the
install fails with an explanation otherwise); setting both `token` and
`enrollToken` is refused.

## What the pod does

The container entrypoint (`docker/entrypoint.sh` in this repo) reads the
credential from the mounted Secret — self-registering first when it is a
fleet token — then fetches the facade's parameter manifest, renders the
Vector config locally (the facade sends parameters, never config or
code), starts Vector with `--watch-config`, and re-polls the manifest
every 60 seconds with an ETag-conditional GET — portal-driven changes
roll out without touching the cluster. A bad or revoked token
crash-loops the pod with a clear log message: visibly broken beats
silently unenrolled.

No ServiceAccount or RBAC is created: the agent talks only to the Cloud
Viewer facade, nothing in-cluster.

## Uninstall

```sh
helm uninstall cloudviewer-agent
```

Then revoke or delete the server in the portal (uninstalling the chart
does not deregister it).
