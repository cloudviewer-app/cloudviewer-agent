# GitHub configuration for this repository

This repository's CI signs and publishes OS packages, a container image,
and a Helm chart. That makes the GitHub configuration itself part of the
supply chain: a misconfigured repo is how a malicious pull request becomes
a signed release. This document is the complete, auditable checklist of
how `cloudviewer-app/cloudviewer-agent` (and the `cloudviewer-app` org)
is configured, and why.

Threat model, in one sentence: a fork pull request ("pwn request") that
modifies workflows or build scripts so CI leaks secrets — above all the
package-signing key — or pushes code/tags/artifacts. Every item below
either removes a path for that or limits the blast radius when a setting
regresses.

Conventions: `[ ]` items are applied once and re-checked after any
GitHub settings change. Items marked **UI** have no API/CLI equivalent
worth scripting; everything else has a `gh` command that both applies and
documents the setting. §8 lists audit commands to verify the live state.

## 1. Repository basics

- [ ] Description, homepage, topics:

```sh
gh repo edit cloudviewer-app/cloudviewer-agent \
  --description "Cloud Viewer monitoring agent — installer, deb/rpm packaging, container image, and Helm chart for the Vector-based agent" \
  --homepage "https://cloudviewer.app" \
  --add-topic vector --add-topic observability --add-topic monitoring \
  --add-topic hetzner --add-topic agent
```

- [ ] Reduce surface — disable what we do not use (each is spam/attack
      surface); keep Issues:

```sh
gh repo edit cloudviewer-app/cloudviewer-agent \
  --enable-wiki=false --enable-projects=false \
  --enable-discussions=false
```

- [ ] Merge hygiene: squash merges only, delete branches on merge:

```sh
gh repo edit cloudviewer-app/cloudviewer-agent \
  --enable-squash-merge --enable-merge-commit=false --enable-rebase-merge=false \
  --delete-branch-on-merge
```

## 2. Actions hardening (the core of PR safety)

Settings → Actions → General.

- [ ] **UI** — "Approval for running fork pull request workflows": set to
      **Require approval for all outside collaborators**. Every fork PR's
      CI waits for a maintainer to read the diff and click approve before
      any of our compute runs it.
- [ ] Default workflow token **read-only**, and Actions may never create
      or approve pull requests:

```sh
gh api -X PUT repos/cloudviewer-app/cloudviewer-agent/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
```

- [ ] **GitHub-hosted runners only.** No self-hosted runner is ever
      registered on this repository or org — on a public repo a fork PR
      executes arbitrary code on the runner. (Public repos get
      GitHub-hosted minutes free; there is no reason to take the risk.)

## 3. Workflow-design rules (no setting enforces these — review does)

These are invariants for every workflow in `.github/workflows/`; a PR
violating them is rejected regardless of what it does:

1. **`pull_request_target` is banned**, as is any `workflow_run` pattern
   that consumes fork-supplied artifacts with secrets in scope. CI runs
   on plain `pull_request`, which on forks gets no secrets and a
   read-only token — that mechanism, not trust, is what makes fork PRs
   safe to run.
2. Every workflow declares an explicit top-level
   `permissions: contents: read`; jobs that need more (e.g.
   `id-token: write` for provenance attestation) request it per-job.
3. **Third-party actions are pinned by commit SHA** (`uses:
   actions/checkout@<40-char sha> # vX`), never by mutable tag. Renovate
   keeps the pins current.
4. Release workflows trigger on tag push only, and reference the
   `release` environment (§4) for secrets; the CI workflow references no
   secrets at all.

## 4. Secrets: one environment, nothing at repo level

- [ ] **No repository-level Actions secrets — ever.** All release
      credentials (the GPG signing subkey; registry tokens if any beyond
      `GITHUB_TOKEN`) live in a single **environment named `release`**.
- [ ] **UI** — Settings → Environments → `release`: deployment
      branches/tags policy restricted to release tags (pattern `20*`,
      matching the `<year>.<quarter>.<patch>` scheme).
- [ ] Only `release.yml` declares `environment: release`.

Result: the CI workflow provably has zero secrets in scope, so even an
approved-then-hostile fork run has nothing to exfiltrate, and a
compromised feature branch cannot reach the signing key because the
environment refuses non-release refs.

Key handling (matches the packaging design): the GPG **master key is
offline**; the environment holds only a signing **subkey**, so a leak is
revocable without rotating the published trust root. The public
fingerprint is cross-published (docs site, portal add-server page, this
repo's README) so a swapped key is visible in three places at once.

## 5. Rulesets

Settings → Rules → Rulesets.

- [ ] **Branch ruleset for `main`**: block force pushes and deletion;
      require the CI status check to pass before merge. (Direct pushes by
      admins stay allowed — solo-maintainer pragmatism; the status-check
      requirement is the part that must hold.)
- [ ] **Tag ruleset for `20*`**: restrict creation, update, and deletion
      to repository admins. Easy to overlook and load-bearing here: **a
      tag push triggers the workflow that signs and publishes packages**,
      so tag creation is a privileged operation in this repository.

## 6. Security features

Settings → Advanced Security / Security.

- [ ] **Private vulnerability reporting: enabled** (intake pairs with
      `SECURITY.md`, which points at the same disclosure contact as the
      product's `security.txt`).
- [ ] **Secret scanning + push protection: enabled** (free on public
      repos).
- [ ] Dependabot alerts: enabled. (Code scanning is optional for a
      shell-only repo — shellcheck in CI covers more; revisit if compiled
      components ever land.)
- [ ] Renovate configured (same bot as the main repo) for GitHub Actions
      SHA pins, base-image digests, and the Vector tested-version bump
      PRs.

## 7. Org level (`cloudviewer-app`)

- [ ] **Require two-factor authentication** for all members (Org
      Settings → Authentication security).
- [ ] Org-wide Actions defaults mirror §2 (fork-PR approval, read-only
      workflow token) so future repos inherit a safe baseline rather
      than opting into one.
- [ ] Base member permission: **read**; collaborators are added per-repo.
- [ ] After the first image/chart push: set the GHCR packages
      (`cloudviewer-agent`, `charts/cloudviewer-agent`) to **public** and
      confirm they are linked to this repo (the
      `org.opencontainers.image.source` label links them automatically).

## 8. Auditing the live state

Re-run after any settings change; each should match the sections above.

```sh
# §1 basics + §6 security toggles
gh repo view cloudviewer-app/cloudviewer-agent \
  --json description,homepageUrl,repositoryTopics,hasWikiEnabled,hasProjectsEnabled,hasDiscussionsEnabled,securityPolicyUrl

# §2 workflow token: expect read / false
gh api repos/cloudviewer-app/cloudviewer-agent/actions/permissions/workflow

# §4 no repo-level secrets: expect an empty list
gh secret list -R cloudviewer-app/cloudviewer-agent

# §4 environments: expect exactly "release"
gh api repos/cloudviewer-app/cloudviewer-agent/environments --jq '.environments[].name'

# §5 rulesets: expect the main branch ruleset and the 20* tag ruleset
gh api repos/cloudviewer-app/cloudviewer-agent/rulesets --jq '.[] | {name, target, enforcement}'

# §2/§7 no self-hosted runners: expect total_count 0
gh api repos/cloudviewer-app/cloudviewer-agent/actions/runners --jq .total_count
gh api orgs/cloudviewer-app/actions/runners --jq .total_count
```

## 9. Priority order

If configuring from scratch and short on time, the four items that close
the realistic attack paths, in order: fork-PR approval required (§2),
read-only default token (§2), secrets only in the `release` environment
(§4), tag ruleset (§5). Everything else is defense in depth.
