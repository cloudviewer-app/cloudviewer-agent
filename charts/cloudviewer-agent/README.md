# cloudviewer-agent Helm chart

Runs the [Cloud Viewer](https://cloudviewer.app) monitoring agent as a
DaemonSet: one pod per node, `hostNetwork`, read-only mounts of the host's
`/proc`, `/sys`, and `/`, shipping node metrics to the Cloud Viewer facade.

The chart is deliberately minimal — a fixed DaemonSet shape with ~5 knobs,
readable in one sitting. It does not expose Vector's configuration: the
agent's Vector config is rendered by the Cloud Viewer portal and fetched by
the agent itself. If you want a general-purpose Vector deployment, use
[Vector's own chart](https://github.com/vectordotdev/helm-charts) instead.

## Beta status — read this first

**This chart is beta until Cloud Viewer fleet enrollment ships.** Agent
tokens today identify one *server*. A DaemonSet shares a single token
across every node, so **all nodes report as the same server** in the
portal, overwriting each other's metrics. In practice:

- **Single-node cluster** (k3s/k0s on one box): works fine — the one node
  is the one server.
- **Multi-node cluster**: wrong tool for now — you would see one server
  flapping between the identities of its nodes. Install the agent on each
  node with the OS package or installer instead.

GA arrives with fleet enrollment: the already-reserved `enrollToken` value
will hand each node an enrollment token with which it registers itself as
its own server (and re-registers under the same identity after node
replacement). Setting `enrollToken` today fails the install with a message
to that effect.

## Install

Create the token Secret yourself (recommended — the token never touches
values files or Helm release state), then install pointing at it:

```sh
kubectl create secret generic cloudviewer-agent --from-literal=token=<agent_token>

helm install cloudviewer-agent oci://ghcr.io/cloudviewer-app/charts/cloudviewer-agent \
  --set existingSecret=cloudviewer-agent
```

The Secret must hold the token under the key `token`. The agent token is
shown once in the portal when the server is added.

Quick start alternative (discouraged beyond a first try — the token ends
up in your shell history and in Helm's release Secret):

```sh
helm install cloudviewer-agent oci://ghcr.io/cloudviewer-app/charts/cloudviewer-agent \
  --set token=<agent_token>
```

## Values

| Key | Default | Meaning |
|---|---|---|
| `image.repository` | `ghcr.io/cloudviewer-app/cloudviewer-agent` | Agent image. |
| `image.tag` | `""` (chart `appVersion`) | Image tag; empty follows the chart's app version. |
| `image.digest` | `""` | `sha256:…` digest pin — preferred over tag when set (immutable). |
| `image.pullPolicy` | `IfNotPresent` | Tags are immutable per release. |
| `existingSecret` | `""` | Name of a Secret with the agent token under key `token`. **The documented path.** |
| `token` | `""` | Quick start only: chart creates the Secret from this value. |
| `enrollToken` | `""` | Reserved for fleet enrollment — not yet functional; setting it fails the install. |
| `facadeUrl` | `https://api.cloudviewer.app` | Facade base URL. |
| `resources` | small requests, 256Mi limit | Pod resources. |
| `tolerations` | `[]` | E.g. tolerate control-plane taints to cover masters. |
| `nodeSelector` | `{}` | Restrict which nodes run the agent. |
| `podAnnotations` | `{}` | Extra pod annotations. |
| `priorityClassName` | `""` | Keep the agent scheduled under node pressure. |

Exactly one of `existingSecret` / `token` is required; the install fails
with an explanation when neither is set.

## What the pod does

The container entrypoint (`docker/entrypoint.sh` in this repo) reads the
token from the mounted Secret, fetches the portal-rendered Vector config
from the facade, starts Vector with `--watch-config`, and re-polls the
config every 60 seconds with an ETag-conditional GET — portal-driven config
changes roll out without touching the cluster. A bad or revoked token
crash-loops the pod with a clear log message: visibly broken beats silently
unenrolled.

No ServiceAccount or RBAC is created: the agent talks only to the Cloud
Viewer facade, nothing in-cluster.

## Uninstall

```sh
helm uninstall cloudviewer-agent
```

Then revoke or delete the server in the portal (uninstalling the chart
does not deregister it).
