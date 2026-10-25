# Releasing cloudviewer-agent

A release is a tag `<year>.<quarter>.<patch>` (no `v`, e.g. `2026.4.0`) on
`main`. Pushing it runs `.github/workflows/release.yml`: verify → nfpm
deb + rpm → GPG-sign → signed apt/yum trees → GitHub Release (packages,
`.asc` signatures, `repo-dist.tar.gz`, SBOMs, `SHA256SUMS`, provenance) →
image to GHCR → chart to GHCR (OCI). Nothing reaches customers until the
monorepo pins the release for `get.app.vaicoa.com` (step 5).

The operator's side, with the why: `docs/agent-operations.md` in
mitja/cloudviewer. The key ceremony: `docs/key-ceremonies.md` part B there
(tracked in gardener-stack#321).

## 0. Rehearse (anyone, any time, no secrets)

```sh
scripts/release-dry-run.sh            # release.yml's build-packages steps in Docker
```

It builds the deb and rpm with the pinned nfpm, signs everything with a
**throwaway key generated inside the container** (discarded with it), builds
the apt/yum trees and `repo-dist.tar.gz`, writes `SHA256SUMS`, then verifies
the signatures with `gpgv`/`rpm --checksig` the way a host would and checks
the tarball the way the monorepo's `sync-installer` will. Output in
`dist-dryrun/` — never publish anything from there. Green on 2026-10-25
(66 KiB `repo-dist.tar.gz`, budget 600 KiB).

## 1. Once, before the first release (owner)

| # | What | How | Check |
|---|---|---|---|
| 1 | **Key ceremony** | `docs/key-ceremonies.md` B1–B5, B7 in mitja/cloudviewer: offline master (certify only) + signing subkey, escrow, tear down. UID: `Vaicoa Package Signing <security@mitjamartini.com>` (the doc still says "Cloud Viewer Package Signing"; the UID is cosmetic, the fingerprint is what hosts pin). | `gpg --list-keys --with-subkey-fingerprints` shows one `[C]` and one `[S]` |
| 2 | **`release` environment** with the subkey | key-ceremonies.md B6: environment `release`, deployment policy tags `20*`, secrets `GPG_SIGNING_KEY` (the armored export of the **signing subkey only**, `ci-subkey.asc`) and `GPG_PASSPHRASE` (optional). No repository-level secrets. | `gh api repos/cloudviewer-app/cloudviewer-agent/environments --jq '.environments[].name'` prints `release`; `gh secret list -R cloudviewer-app/cloudviewer-agent` prints nothing; `gh secret list --env release -R cloudviewer-app/cloudviewer-agent` prints both |
| 3 | **Publish the fingerprint** | key-ceremonies.md B8: README (`TODO: fingerprint after key ceremony`, in a PR here), https://vaicoa.com/app/security/ (EN + DE), the portal's add-server page. | the three show the same 40 hex digits |
| 4 | **Repo hardening** | `docs/github-config.md` §8 audit block; at least §9's four items. The `20*` tag ruleset (exists) restricts who can push a release tag. | §8 commands |
| 5 | **DNS** | `get.app.vaicoa.com` and `api.app.vaicoa.com` resolve to the cluster and the get Ingress serves that host (monorepo rename, separate PR). The installer's defaults point there since this change. | `curl -fsS https://get.app.vaicoa.com/healthz` → `ok` |

Action SHAs and the nfpm version are pinned in the workflows (2026-10-25);
Renovate (`.github/renovate.json5`) keeps them current once enabled.

**Secrets the workflow uses:** `GPG_SIGNING_KEY`, `GPG_PASSPHRASE` (both in
the `release` environment, read only by `build-packages`), and the
automatic `GITHUB_TOKEN` (Release upload, GHCR push, attestations). The
optional `notify-get` job needs `MONOREPO_DISPATCH_TOKEN` and the variable
`MONOREPO_DISPATCH=true`; leave it off — the monorepo has no receiver.

## 2. Before the tag

1. `main` is green in CI (shellcheck, harness, Vector tests, nfpm dry
   builds, chart lint, image build).
2. The tested Vector version is current (`packaging/nfpm.yaml` `depends:`
   floor, `docker/Dockerfile` `ARG VECTOR_VERSION`) — agent-operations.md §2
   steps 1–3.
3. `scripts/release-dry-run.sh` is green on the commit you will tag.
4. Pick the version: the current quarter's train, `.0` for the first
   release of the quarter (Q4 2026 → `2026.4.0`), `.P+1` for a fix.

## 3. Tag (owner — a tag push is the act that reaches the signing key)

```sh
git switch main && git pull --ff-only
git log -1 --oneline                        # the commit the dry run was green on
git tag -a 2026.4.0 -m "cloudviewer-agent 2026.4.0"
git push origin 2026.4.0
gh run watch -R cloudviewer-app/cloudviewer-agent \
  "$(gh run list -R cloudviewer-app/cloudviewer-agent -w release -L 1 --json databaseId -q '.[0].databaseId')"
```

If `build-packages` fails, nothing was published that matters: delete the
Release if one was created (`gh release delete 2026.4.0 -R
cloudviewer-app/cloudviewer-agent --cleanup-tag`), fix on `main`, tag again.
Never re-push a tag that already has a Release that someone may have pinned;
use the next patch number.

## 4. Verify the release (before pinning it anywhere)

```sh
V=2026.4.0
R=cloudviewer-app/cloudviewer-agent
mkdir -p /tmp/agent-$V && cd /tmp/agent-$V
gh release download "$V" -R "$R"
sha256sum -c SHA256SUMS                         # macOS: shasum -a 256 -c SHA256SUMS

mkdir tree && tar -xzf repo-dist.tar.gz -C tree
gpg --show-keys tree/keys/cloudviewer.asc       # fingerprint == the published one (step 1.3)

gpgv --keyring tree/keys/cloudviewer.gpg tree/apt/dists/stable/InRelease
gpgv --keyring tree/keys/cloudviewer.gpg tree/rpm/repodata/repomd.xml.asc tree/rpm/repodata/repomd.xml
for f in *.deb *.rpm; do gpgv --keyring tree/keys/cloudviewer.gpg "$f.asc" "$f"; done
gh attestation verify "cloudviewer-agent_${V}_all.deb" -R "$R"
gh attestation verify "cloudviewer-agent-${V}-1.noarch.rpm" -R "$R"
```

Every `gpgv` must say `Good signature` from the Vaicoa key — not from any
other key. Then set the two GHCR packages (image `cloudviewer-agent`, chart
`charts/cloudviewer-agent`) to public in the org's package settings (first
release only).

## 5. Publish on get.app.vaicoa.com (in mitja/cloudviewer)

```sh
cd ~/Developer/cloudviewer && git switch main && git pull --ff-only
git switch -c chore/agent-$V
gmake -C deploy sync-installer AGENT_REF=$V   # fetches install.sh @ tag + repo-dist.tar.gz, checks SHA256SUMS
gmake -C deploy check-sync                    # re-verifies against GitHub
gmake -C deploy validate
git add deploy/apps/get && git commit -m "get: serve cloudviewer-agent $V (first signed release)"
git push -u origin chore/agent-$V
gh pr create -R mitja/cloudviewer --fill
```

The diff is `deploy/apps/get/installer.lock` (ref, both SHA-256) and the two
vendored files. Merging deploys: Flux reconciles `deploy/` from main and the
`get-content` ConfigMap's new hash rolls the get pod.

## 6. After

1. Smoke from a clean VM (agent-operations.md §2 step 8):
   `curl -fsSL https://get.app.vaicoa.com/keys/cloudviewer.asc | gpg --show-keys`
   shows the published fingerprint; the one-liner from the README installs,
   enrolls, and the server turns Connected in the portal; `--uninstall`
   deregisters.
2. Re-pin the Garden Linux element in gardener-stack
   (agent-operations.md §2 step 6).
3. Sign-off record `releases/<version>.md` in mitja/cloudviewer
   (agent-operations.md §2 step 7).
