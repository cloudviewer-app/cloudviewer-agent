#!/usr/bin/env bash
# release-dry-run.sh — run release.yml's build-packages job locally, in
# Docker, with a THROWAWAY signing key, and check the result the way the
# monorepo's `gmake -C deploy sync-installer` will.
#
#   scripts/release-dry-run.sh [VERSION]        # default 2026.4.0-dryrun
#
# Output: dist-dryrun/ (gitignored) — the deb/rpm with their .asc, the
# apt/yum trees, repo-dist.tar.gz and SHA256SUMS, exactly the assets a
# tagged release would attach. Nothing is uploaded, nothing is tagged.
#
# The key: generated inside the container, used for this run only, and
# discarded with the container. It is NOT the release key and nothing it
# signs may ever be published. The release key is the owner-held
# "Vaicoa Package Signing" subkey in the `release` environment
# (RELEASING.md); this script never sees it.
#
# Keep in step with .github/workflows/release.yml (build-packages): the
# same nfpm version, the same commands. A change to one is a change to both.
set -euo pipefail

VERSION="${1:-2026.4.0-dryrun}"
NFPM_VERSION="v2.48.0"
GO_IMAGE="golang:1.26-bookworm"

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/dist-dryrun"
rm -rf "$out"
mkdir -p "$out"

docker run --rm -i \
    -e VERSION="$VERSION" -e NFPM_VERSION="$NFPM_VERSION" \
    -e SOURCE_EPOCH="$(git -C "$repo" log -1 --format=%ct)" \
    -v "$repo:/src:ro" -v "$out:/out" \
    "$GO_IMAGE" bash -euo pipefail -s <<'IN_CONTAINER'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends rpm createrepo-c apt-utils gnupg >/dev/null
go install "github.com/goreleaser/nfpm/v2/cmd/nfpm@$NFPM_VERSION" 2>/dev/null
NFPM="$(go env GOPATH)/bin/nfpm"

cp -a /src /work
cd /work
rm -rf dist repo-dist

echo "== build deb + rpm ($VERSION)"
mkdir -p dist
"$NFPM" package -f packaging/nfpm.yaml --packager deb --target dist/
"$NFPM" package -f packaging/nfpm.yaml --packager rpm --target dist/

echo "== throwaway signing key (DRY RUN ONLY)"
export GNUPGHOME="$(mktemp -d)"
: > "$GNUPGHOME/passphrase"
gpg --batch --quiet --passphrase '' --quick-gen-key \
    "DRY RUN throwaway - never publish <dry-run@invalid>" ed25519 sign 1d
GPG_KEY_ID="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "sec" { print $5; exit }')"
test -n "$GPG_KEY_ID"
PASS=(--pinentry-mode loopback --passphrase-file "$GNUPGHOME/passphrase")

echo "== sign the rpm"
cat > "$HOME/.rpmmacros" <<EOF
%_signature gpg
%__gpg $(command -v gpg)
%_gpg_name ${GPG_KEY_ID}
%__gpg_sign_cmd %{__gpg} gpg --batch --pinentry-mode loopback --passphrase-file ${GNUPGHOME}/passphrase --no-armor --digest-algo sha256 -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
EOF
rpmsign --addsign dist/*.rpm
gpg --export --armor "$GPG_KEY_ID" > /tmp/signing-key.asc
rpm --import /tmp/signing-key.asc
rpm --checksig dist/*.rpm

echo "== detached signatures"
for f in dist/*.deb dist/*.rpm; do
    gpg --batch "${PASS[@]}" -u "$GPG_KEY_ID" --armor --detach-sign "$f"
done

echo "== apt tree"
mkdir -p repo-dist/apt/pool/main \
         repo-dist/apt/dists/stable/main/binary-amd64 \
         repo-dist/apt/dists/stable/main/binary-arm64
cp dist/*.deb repo-dist/apt/pool/main/
(
    cd repo-dist/apt
    apt-ftparchive packages pool > dists/stable/main/binary-amd64/Packages
    cp dists/stable/main/binary-amd64/Packages dists/stable/main/binary-arm64/Packages
    gzip -9 -k dists/stable/main/binary-amd64/Packages
    gzip -9 -k dists/stable/main/binary-arm64/Packages
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin="Vaicoa" \
        -o APT::FTPArchive::Release::Label="Vaicoa" \
        -o APT::FTPArchive::Release::Suite=stable \
        -o APT::FTPArchive::Release::Codename=stable \
        -o APT::FTPArchive::Release::Components=main \
        -o "APT::FTPArchive::Release::Architectures=amd64 arm64" \
        release dists/stable > dists/stable/Release
    gpg --batch "${PASS[@]}" -u "$GPG_KEY_ID" --clearsign -o dists/stable/InRelease dists/stable/Release
    gpg --batch "${PASS[@]}" -u "$GPG_KEY_ID" --armor --detach-sign -o dists/stable/Release.gpg dists/stable/Release
)

echo "== yum tree + public key"
mkdir -p repo-dist/rpm/packages repo-dist/keys
cp dist/*.rpm repo-dist/rpm/packages/
createrepo_c -q repo-dist/rpm
gpg --batch "${PASS[@]}" -u "$GPG_KEY_ID" --armor --detach-sign repo-dist/rpm/repodata/repomd.xml
gpg --export "$GPG_KEY_ID" > repo-dist/keys/cloudviewer.gpg
gpg --export --armor "$GPG_KEY_ID" > repo-dist/keys/cloudviewer.asc

echo "== repo-dist.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_EPOCH" \
    -C repo-dist -cf - apt rpm keys | gzip -9n > dist/repo-dist.tar.gz
tar -tzf dist/repo-dist.tar.gz | grep -qx 'keys/cloudviewer.gpg'
size=$(wc -c < dist/repo-dist.tar.gz)
echo "repo-dist.tar.gz: $size bytes"
test "$size" -le $((600 * 1024))

echo "== SHA256SUMS"
(cd dist && sha256sum -- * > SHA256SUMS)
cat dist/SHA256SUMS

echo "== verify, as a host would"
# apt: InRelease and Release.gpg against the served key.
gpgv --keyring repo-dist/keys/cloudviewer.gpg repo-dist/apt/dists/stable/InRelease
gpgv --keyring repo-dist/keys/cloudviewer.gpg repo-dist/apt/dists/stable/Release.gpg repo-dist/apt/dists/stable/Release
# yum: repomd.xml's detached signature; the rpm's embedded one was checked above.
gpgv --keyring repo-dist/keys/cloudviewer.gpg repo-dist/rpm/repodata/repomd.xml.asc repo-dist/rpm/repodata/repomd.xml
# the release assets' detached signatures
for f in dist/*.deb dist/*.rpm; do gpgv --keyring repo-dist/keys/cloudviewer.gpg "$f.asc" "$f"; done
# what sync-installer checks: the asset is in SHA256SUMS and matches it
(cd dist && grep ' repo-dist.tar.gz$' SHA256SUMS | sha256sum -c -)

cp -a dist/. /out/
cp -a repo-dist /out/repo-dist
echo "DRY RUN OK — throwaway-signed; never publish anything in dist-dryrun/"
IN_CONTAINER

echo "artefacts: $out"
