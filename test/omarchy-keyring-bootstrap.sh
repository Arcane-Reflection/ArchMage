#!/usr/bin/env bash
# omarchy-keyring-bootstrap.sh — deterministic omarchy signing-key bootstrap.
#
# Breaks the chicken-and-egg: [omarchy] packages are signed by the omarchy
# keyring, which therefore cannot come FROM a verified pacman transaction.
# Chain of trust: fetch the repo db over HTTPS (TLS), read the omarchy-keyring
# package's FILENAME + SHA256SUM from the db, fetch the package and verify it
# against the db entry, extract into /usr/share/pacman/keyrings/, then
# `pacman-key --populate omarchy` performs import + lsign + ultimate trust.
#
# Consumers: test/desktop-x86_64.sh (image builder, host + pacstrap keyrings)
# and the packages.yml x86_64 build container (makepkg --syncdeps resolves
# omarchy-settings etc. from the [omarchy] sync db).
#
# Usage: bash test/omarchy-keyring-bootstrap.sh [repo-url-base]
#   repo-url-base defaults to https://pkgs.omarchy.org/stable/x86_64
# Requires root; needs curl, tar, zstd, pacman-key.
set -euo pipefail

BASE="${1:-https://pkgs.omarchy.org/stable/x86_64}"

[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root (pacman-key --populate)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl missing" >&2; exit 1; }

db="$(mktemp /tmp/omarchy.db.XXXXXX.tar.zst)"
pkg="$(mktemp /tmp/omarchy-keyring.XXXXXX.pkg.tar.zst)"
trap 'rm -f "$db" "$pkg"' EXIT

curl -fsSL --retry 3 --retry-delay 5 -o "$db" "$BASE/omarchy.db.tar.zst"
keydir="$(tar --zstd -tf "$db" | awk -F/ '/^omarchy-keyring-[^/]+\/desc$/ {print $1; exit}')"
[ -n "$keydir" ] || { echo "ERROR: omarchy repo db has no omarchy-keyring entry" >&2; exit 1; }
keyfile="$(tar --zstd -xOf "$db" "$keydir/desc" | awk '/^%FILENAME%$/ {getline; print; exit}')"
keysha="$(tar --zstd -xOf "$db" "$keydir/desc" | awk '/^%SHA256SUM%$/ {getline; print; exit}')"
[ -n "$keyfile" ] && [ -n "$keysha" ] \
    || { echo "ERROR: cannot read FILENAME/SHA256SUM from db ($keydir)" >&2; exit 1; }

curl -fsSL --retry 3 --retry-delay 5 -o "$pkg" "$BASE/$keyfile"
echo "$keysha  $pkg" | sha256sum -c - >/dev/null \
    || { echo "ERROR: omarchy-keyring package sha256 mismatch ($keyfile)" >&2; exit 1; }
tar --zstd -xf "$pkg" -C /
pacman-key --populate omarchy
echo "--- omarchy keyring populated ($keyfile) ---"
