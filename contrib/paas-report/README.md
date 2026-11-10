# Cloud Viewer on PaaS hosts — Dokku, Kamal, Coolify, Dokploy, Docker Compose

Most people who run Dokku, Kamal, Coolify, Dokploy or a hand-written
`docker-compose.yml` on a Hetzner server care about the **apps** on that
host: is the shop up, is the worker crash-looping, did the deploy break
something, is the certificate about to expire. Cloud Viewer has no "app"
resource yet (roadmap: specs/43 §5, *Container view* and *PaaS app view*),
but everything needed to answer those questions **today** already exists,
without touching the PaaS's API or handing out another credential:

| Question | Building block | Plan |
|---|---|---|
| Is the host healthy (CPU, RAM, disk, load)? Is the server costing what I think? | Hetzner project + the **agent** on the host | Pro / Team for agent metrics |
| Is each app running, healthy, not crash-looping? | **Job reports**, one job per app, sent by [`cloudviewer-paas-report`](cloudviewer-paas-report) | Pro / Team |
| Did the last deploy succeed? | **Job report** wrapping the deploy command (`cloudviewer-report` or `curl`) | Pro / Team |
| Can users reach the app (proxy, DNS, TLS)? | **Uptime checks** on the app's domain | free account, Pro, Team |
| What does the PaaS host cost, compared to the others? | **Hetzner labels** on the server, cost breakdown by label | all |
| Why did it fail? | **Log context** (journald WARN+) — optionally with Docker's journald log driver | Pro / Team |

The rest of this page goes through them in that order, then per platform.

## 1. Install the agent on the host

Dokku, Coolify and Dokploy hosts are ordinary Ubuntu/Debian machines, and so
is a Kamal or Compose target. Use the normal one-liner from the portal
(Monitored servers → Add):

```bash
curl -fsSL https://get.cloudviewer.app/agent | sh -s -- --token <agent_token>
```

The agent sends host metrics and journald warnings only; it opens no port,
so it does not collide with Traefik, Caddy, nginx or kamal-proxy on 80/443.
It writes its token to `/etc/cloudviewer-agent/agent.env`
(`CV_AGENT_TOKEN`, `CV_AGENT_FACADE_URL`), which everything below reuses.

Prefer to keep the host "containers only" (common on Kamal hosts)? The agent
also ships as a container image (specs/30 §8); the token then lives
wherever you put it, and `cloudviewer-paas-report --token-file` reads it.

## 2. Per-app health: `cloudviewer-paas-report`

[`cloudviewer-paas-report`](cloudviewer-paas-report) is a POSIX shell
script (needs `docker`, `curl`, `awk`; no jq). Every run it:

1. reads all containers with one `docker inspect`,
2. groups them into apps using the labels each platform already sets,
3. grades each app, and
4. sends **one** batched `POST /v1/ingest/job` with one job per app.

Each app then appears in the **Jobs** section of the server's detail
screen as `app-<name>`, and the existing **Job failed** and **Job stale**
alerts (push, email, alert targets, mute) cover it with no extra setup.

### How apps are recognised

| Platform | Containers are grouped by | App name | Component |
|---|---|---|---|
| your own label (any platform) | `cloudviewer.app=<name>` | `<name>` | Compose service / Kamal role / process type |
| Dokku | `com.dokku.app-name` | the Dokku app | `com.dokku.process-type` (web, worker, …) |
| Kamal | `service` + `role` (+ `destination`) | `service-destination` | role (web, job, …) |
| Coolify | `coolify.managed=true` + compose project | `coolify.resourceName`, else the project id | Compose service |
| Dokploy / Docker Swarm | `com.docker.stack.namespace` or `com.docker.swarm.service.name` | stack, else service | Swarm service |
| Docker Compose | `com.docker.compose.project` | the project | Compose service |
| anything else | container name | container name | — |

Coolify's compose project names are UUIDs. For a readable job name, add a
custom label `cloudviewer.app=shop` to the app's container labels in
Coolify; the same label works on every platform.
`cloudviewer.ignore=true` leaves a container out.

The PaaS's own containers (Coolify's `coolify*`, Dokploy's `dokploy*`,
`kamal-proxy`) are grouped as apps too, so "the control plane is down"
shows up like any other app. Use `--ignore '^(coolify|dokploy)'` if you
don't want them.

### What the exit codes mean

The report has no message field, so the job's exit code
carries the reason. The worst component wins:

| Exit code | Meaning |
|---|---|
| `0` | Every component has a running container (healthy, or no `HEALTHCHECK`), or the app was stopped on purpose |
| `10` | **Unhealthy** — a running container's `HEALTHCHECK` fails |
| `20` | **Restart loop** — a container is `restarting`, or restarted ≥ `--restart-threshold` (3) times since the previous run |
| `30` | **Down** — a component has no running container and at least one of its containers crashed (non-zero exit, OOM-killed, dead) |
| `40` | **Gone** — the app had its own job and now has no container at all (removed, renamed, `compose down` — or its crashed containers were pruned). It stays `40`, and alerting, until someone retires the job |

The script avoids the false alarms these platforms would otherwise produce:

- **Old containers kept for rollback** (Kamal keeps the last few stopped
  versions; Dokku retires old containers after a deploy; Swarm keeps task
  history) don't count while a running container of the same component
  exists.
- **One-shot containers** that exited `0` (Compose `migrate`/`init`
  services, `kamal app exec`) are fine.
- **`docker stop` / `docker compose stop`** ends with exit code 0, 137 or
  143 and counts as stopped on purpose, not as a crash — unless the kernel
  OOM-killed the container.

A run looks like this (`status` prints the table and sends nothing):

```text
# cloudviewer-paas-report status
JOB                          PLATFORM  CODE   COMPS  DETAIL
app-api-production           kamal     0      1/1    ok
app-blog                     dokku     30     1/2    worker: down
app-loopy                    docker    20     0/1    loopy: restart loop
app-shop                     compose   10     2/3    db: unhealthy
```

### Install

> The URLs below are where the script is meant to be published: the public
> agent repository (`cloudviewer-app/cloudviewer-agent`, same path). This
> repository is private, so until it is copied there, take the files from
> this directory.

```bash
curl -fsSLo /usr/local/bin/cloudviewer-paas-report https://raw.githubusercontent.com/cloudviewer-app/cloudviewer-agent/main/contrib/paas-report/cloudviewer-paas-report
```

```bash
chmod 755 /usr/local/bin/cloudviewer-paas-report
```

```bash
cloudviewer-paas-report status
```

```bash
cloudviewer-paas-report --dry-run
```

Then run it every 5 minutes with the systemd timer from this directory:

```bash
cd /etc/systemd/system && curl -fsSLO https://raw.githubusercontent.com/cloudviewer-app/cloudviewer-agent/main/contrib/paas-report/cloudviewer-paas-report.service && curl -fsSLO https://raw.githubusercontent.com/cloudviewer-app/cloudviewer-agent/main/contrib/paas-report/cloudviewer-paas-report.timer
```

```bash
systemctl daemon-reload && systemctl enable --now cloudviewer-paas-report.timer
```

(or a cron line: `*/5 * * * * root /usr/local/bin/cloudviewer-paas-report`).
Read the script before you install it; it is short.

### Options and limits

| Option | Default | |
|---|---|---|
| `--max-jobs N` | 12 | Job slots the script may use. A server has **16 jobs in total**, shared with your backups and other reports — leave room. |
| `--max-age DUR` | `15m` | Freshness budget. If the script (or the host, or Docker) stops reporting, every app job turns **stale** after this and alerts. Keep it ≥ 3× the timer interval. |
| `--restart-threshold N` | 3 | Restarts between two runs that count as a loop. |
| `--prefix STR` | `app-` | Job-name prefix. |
| `--ignore REGEX` | — | Skip apps whose name matches. |
| `--token-file`, `--facade-url`, `--env-file` | agent.env | For hosts without the agent package. |

One request per run fits easily in the 2 requests/minute budget per
server token.

### How the 16-job limit is handled

The facade counts only **new** job names against a server's 16 jobs;
reports for jobs it already holds always pass. But when the new names of a
request don't fit, it rejects the **whole** request. The script is built
around that:

- **Slots are sticky.** An app that got its own job keeps it (state in
  `/var/lib/cloudviewer-paas-report/assigned`). New apps get a slot while
  fewer than `--max-jobs - 1` are taken; after that they are folded into
  `app-other` (worst code wins). Adding an app never renames another app's
  job, so no job is left behind to go stale.
- **When the limit is hit** (`422 job_limit_reached`, because backups and
  other reporters already use the slots), the script resends only the jobs
  the facade already holds, so they stay fresh, exits non-zero and names
  the apps it could not report. Lower `--max-jobs` or free slots.
- **Removed or renamed apps are retired by a person, never on a timer.**
  An app with its own job but no container is reported as `40` (gone) and
  keeps alerting: a vanished app may be an outage, and deleting its job
  automatically would silence exactly that alert with nobody deciding
 . When you know the app is gone, retire it:

  ```bash
  cloudviewer-paas-report retire blog
  ```

  This deletes the job (`DELETE /v1/ingest/job/app-blog`) and frees its
  slot for the next new app. Team admins can do the same in the portal
  (Monitored Servers → the server's **N jobs** link → remove), but on a
  host that runs the script use the command: the script cannot read the
  server's job list, so a gone app's job removed only in the portal is
  reported again (as `40`) on the next run.

  Where the platform tells you an app was deleted, call it from there, so
  the decision and the cleanup are the same act: a Dokku `post-delete`
  plugin trigger (it gets the app name), the step after `kamal remove` in
  your CI, or the script that runs `docker compose down` for good.

Job deletion is new in the facade; against a facade
without it, `retire` reports the HTTP error and changes nothing.

## 3. Deploy outcomes

A deploy is a job: wrap the deploy command and its exit code becomes the
report. Where the deploy runs decides how.

**On the host** (Dokku git push builds, a cron-driven `docker compose pull && up`):

```bash
cloudviewer-report --job deploy-shop -- docker compose -f /srv/shop/compose.yml up -d --pull always --wait
```

`--wait` makes Compose return non-zero when a service does not become
healthy, so a deploy that starts but never gets healthy is reported as
failed. No `--max-age`: deploys are not periodic, so only failures alert.

**From CI or a laptop** (Kamal, Dokku via `git push`, Coolify/Dokploy
deploy webhooks triggered from CI): report with the **token of the server
the deploy targets**, stored as a CI secret. The job then
appears on that server's screen:

```bash
kamal deploy; ec=$?
curl -sS -X POST https://api.cloudviewer.app/v1/ingest/job \
  -H "X-Agent-Token: $CV_AGENT_TOKEN" -H "Content-Type: application/json" \
  -d "{\"reports\":[{\"job_name\":\"deploy-api\",\"exit_code\":$ec}]}"
exit $ec
```

Coolify's and Dokploy's own deploy notifications (Discord, Slack, webhook)
send their own payload and cannot post a job report directly. A deploy that
leaves the app broken still shows up through `cloudviewer-paas-report`
within one interval.

## 4. Uptime checks on the app domains

The agent and the reporter see the host from the inside. An **uptime
check** sees what users see: the proxy (Traefik, Caddy, nginx,
kamal-proxy), DNS and the certificate. Add one HTTP check per app domain,
ideally on a health path with a substring (`/up` with `OK` for Rails/Kamal,
`/healthz`).

To find the domains on a host:

```bash
cloudviewer-paas-report domains
```

It reads Traefik `Host(...)` rules and Caddy labels (Coolify, Dokploy,
Compose with Traefik), `dokku domains:report`, and `kamal-proxy list`.
Add the checks in the app (Resources → *Add check*) or in the portal, which
can also anchor a check to the server, so its results sit on the same
detail screen as the app jobs. A TLS check on 443 warns 14 days before a
certificate expires — the usual way a Let's Encrypt renewal problem behind
Traefik shows up.

## 5. Labels on the Hetzner server

Cloud Viewer is read-only, so set labels with the Hetzner Console or
`hcloud`:

```bash
hcloud server add-label web-1 paas=coolify
```

```bash
hcloud server add-label web-1 cost-center=shop
```

The cost view breaks down by label, so "what do my Coolify hosts cost"
becomes one tap, and the label is visible on the server detail screen and
in shared incident briefs.

## 6. Container logs in the log context (optional)

Log context shows journald lines at WARN and above. Docker's default
`json-file` driver bypasses journald, so container errors don't appear
there. Switching the daemon to the `journald` driver sends container
stderr to journald with priority 3 (error), so it shows up next to the
app jobs:

```json
{ "log-driver": "journald" }
```

in `/etc/docker/daemon.json`, then restart Docker (applies to containers
created afterwards). `docker logs` keeps working, so the Coolify and
Dokploy log viewers do too. Two caveats: every stderr line counts as an
error, and a chatty app runs into the per-server rate limit — and Kamal
and some Coolify setups set their own log driver per container. Try it on
one host first.

## 7. Per platform, in short

**Dokku** — agent + `cloudviewer-paas-report` (apps by `com.dokku.app-name`,
per process type) + uptime checks from `dokku domains:report`. Deploys
from `git push`: wrap the push in CI, or rely on the reporter.

**Kamal** — the app host has the agent (package or container) and the
reporter (apps by `service`/`role`/`destination`; old versions kept for
rollback are ignored). Deploy outcome from the CI job that runs
`kamal deploy`. Uptime check on the `proxy.host` with path `/up`.

**Coolify** — agent + reporter (apps by compose project; add
`cloudviewer.app` labels for readable names; the `coolify*` control-plane
containers are reported as the `coolify` app). Uptime checks from the
Traefik/Caddy labels. Label the server `paas=coolify`.

**Dokploy** — Dokploy runs apps as Docker Swarm services and Compose
deployments as Compose projects; the reporter handles both, plus the
`dokploy*` control plane. Uptime checks from the Traefik labels.

**Docker Compose** — one app per Compose project, one component per
service; add a `HEALTHCHECK` (or `healthcheck:` in the file) to get the
"unhealthy" grade. Deploy with `up -d --wait` wrapped in
`cloudviewer-report`.

## What this does not do (yet)

- **No per-app CPU/RAM.** Container metrics are the roadmap's *Container
  view* (specs/43 §5); this reports state, not resource use.
- **No app resources** in the inventory, cost per app, or app-level
  screens — that is the *PaaS app view*, after the container view
  (specs/26 §2.3 path 2).
- **No PaaS API calls.** Everything is derived from container labels on
  the host, which is also why no Coolify/Dokploy API token is needed.
