# Security Policy

The agent is deliberately thin: upstream Vector plus a few small POSIX sh
scripts, systemd units, and packaging. Reports about the install path,
the package/repo signing chain, or anything that could make a host run
code it did not opt into are the ones we care most about.

## Reporting a vulnerability

Preferred: **GitHub private vulnerability reporting** on this repository
(Security tab → "Report a vulnerability").

Alternatively: **security@cloudviewer.app** — the same disclosure contact
as the Cloud Viewer product's `security.txt` and the
[monorepo security policy](https://github.com/mitja/cloudviewer/blob/main/SECURITY.md).
If you want to encrypt, ask for a key in a first, contentless mail.

Please include what you found, how to reproduce it, what an attacker
gains, and whether you believe it is already being exploited — that last
point starts a legal clock for us under the EU Cyber Resilience Act, so
say so even if you are unsure. You can expect an acknowledgement within
48 hours and a first assessment within 5 working days.

## Supported versions

Versions follow `<year>.<quarter>.<patch>` (e.g. `2026.3.0`), released as
a quarterly train. **The latest release train is supported**; security
fixes ship as a patch on the current train, the day they are fixed.
Older trains do not receive fixes — upgrade through the package
repository. Note that most Vector CVEs require no release from us at
all: the `vector` binary comes from Vector's own signed repository and
updates through your host's normal update policy.

## Package signing

Packages and the apt/yum repositories are signed with the "Cloud Viewer
Package Signing" GPG key. Its **fingerprint is published at
[cloudviewer.app](https://cloudviewer.app) and in this repository's
README** — cross-check both before trusting the repository. CI holds
only a signing subkey; the master key is offline.

## Supply-chain hardening

The GitHub configuration that protects the release pipeline — fork-PR
approval, read-only workflow tokens, secrets confined to the `release`
environment, the release-tag ruleset — is documented, with audit
commands, in [docs/github-config.md](docs/github-config.md). It is
public on purpose, so you can verify the claims.
