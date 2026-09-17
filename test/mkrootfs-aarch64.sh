#!/usr/bin/env bash
# mkrootfs-aarch64.sh — build the minimal bootable aarch64 rootfs for the
# QEMU smoke loop, consuming the linuxphoneOS CI staging-repo artifact.
#
# End to end, one command:
#   (staging artifact: gh run download, HOST side only)
#   -> official ALARM aarch64 rootfs tarball (TUNA preferred,
#      os.archlinuxarm.org fallback, cached + checksum-verified)
#   -> unpack + incremental pacman install (openssh + linuxphoneos-cn
#      umbrella) INSIDE an aarch64 container on any host (binfmt on x86_64)
#   -> enable sshd + one-time ed25519 smoke key
#   -> test/build/aarch64/{Image, initramfs-linux.img, rootfs.ext4, rootfs/}
#
# Usage:
#   test/mkrootfs-aarch64.sh --from-ci          # default; gh run download of
#                                               # the latest successful main
#                                               # run's staging-repo artifact
#   test/mkrootfs-aarch64.sh --repo-dir PATH    # consume an already
#                                               # downloaded artifact dir
# Environment:
#   LPOS_GH_REPO   GitHub <owner>/<repo> for --from-ci
#                  (default: uMaj35ty/linuxphoneOS)
#
# Internal flag (do not pass): --inner — re-executed inside the aarch64
# build container by the host phase.
#
# Signature discipline (PITFALLS 2): the staging repo is consumed with
# SigLevel Required DatabaseOnly; its key (staging-key.asc) is imported
# into the ROOTFS pacman keyring and locally signed BEFORE the install
# transaction, otherwise pacman rejects the signed database outright.

set -euo pipefail

usage() {
    cat <<'EOF'
mkrootfs-aarch64.sh — minimal aarch64 smoke rootfs from the CI staging repo

Usage:
  test/mkrootfs-aarch64.sh [--from-ci | --repo-dir PATH]

Options:
  --from-ci        Download the staging-repo artifact of the latest
                   successful packages.yml run on main via gh (default).
  --repo-dir PATH  Use an already-downloaded staging-repo artifact
                   directory (needs cn.db.tar.zst, staging-key.asc,
                   FINGERPRINT.txt).
  -h, --help       Show this help.

Environment:
  LPOS_GH_REPO     GitHub <owner>/<repo> for --from-ci
                   (default: uMaj35ty/linuxphoneOS)

Outputs (test/build/aarch64/):
  Image, initramfs-linux.img   kernel + initramfs from the rootfs /boot
  rootfs.ext4                  ext4 root filesystem (virtio boot target)
  rootfs/                      unpacked rootfs (kept for 01-03 assertions)
  smoke_key, smoke_key.pub     one-time SSH key (host side, gitignored)
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

MODE=""
REPO_DIR_ARG=""
INNER=no
while [ $# -gt 0 ]; do
    case "$1" in
        --from-ci)
            MODE=ci
            ;;
        --repo-dir)
            [ $# -ge 2 ] || die "--repo-dir needs a PATH argument"
            REPO_DIR_ARG=$2
            MODE=dir
            shift
            ;;
        --inner)
            INNER=yes
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
    shift
done
[ -n "$MODE" ] || MODE=ci

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT=$(lpos::repo_root)
BUILD_DIR=$REPO_ROOT/test/build
AARCH64_DIR=$BUILD_DIR/aarch64
CACHE_DIR=$BUILD_DIR/cache
STAGING_DIR=$BUILD_DIR/staging-repo
ROOTFS_DIR=$AARCH64_DIR/rootfs

LPOS_GH_REPO=${LPOS_GH_REPO:-uMaj35ty/linuxphoneOS}

TARBALL_NAME=ArchLinuxARM-aarch64-latest.tar.gz
CACHE_FILE=$CACHE_DIR/$TARBALL_NAME
# T-01-07: https only, TUNA preferred, official upstream as fallback.
TARBALL_URLS=(
    "https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/$TARBALL_NAME"
    "https://os.archlinuxarm.org/os/$TARBALL_NAME"
)

# Required staging artifact files (01-01 contract).
staging_valid() {
    [ -s "$STAGING_DIR/cn.db.tar.zst" ] &&
        [ -s "$STAGING_DIR/staging-key.asc" ] &&
        [ -s "$STAGING_DIR/FINGERPRINT.txt" ]
}

cache_valid() {
    [ -f "$CACHE_FILE" ] && [ -f "$CACHE_FILE.sha256" ] &&
        (cd "$CACHE_DIR" && sha256sum -c --status "$TARBALL_NAME.sha256")
}

fetch_rootfs_tarball() {
    if cache_valid; then
        lpos_info "reusing cached $TARBALL_NAME (sha256 verified)"
        return 0
    fi
    mkdir -p "$CACHE_DIR"
    local base ok=no
    for base in "${TARBALL_URLS[@]}"; do
        rm -f "$CACHE_FILE" "$CACHE_FILE.md5"
        lpos_info "downloading $base"
        if lpos::download "$base" "$CACHE_FILE" &&
            lpos::download "$base.md5" "$CACHE_FILE.md5" &&
            (cd "$CACHE_DIR" && md5sum -c --status "$TARBALL_NAME.md5"); then
            ok=yes
            break
        fi
        lpos_warn "download/md5 verification failed for $base, trying next mirror"
    done
    if [ "$ok" != yes ]; then
        die "could not download + verify $TARBALL_NAME from any mirror (TUNA, os.archlinuxarm.org)"
    fi
    # T-01-07: the cache key carries the tarball sha256 — reuse is only
    # allowed when the bytes still match what was originally verified.
    (cd "$CACHE_DIR" && sha256sum "$TARBALL_NAME" > "$TARBALL_NAME.sha256")
}

prepare_staging() {
    if [ "$MODE" = dir ]; then
        [ -n "$REPO_DIR_ARG" ] || die "--repo-dir requires a path"
        local f
        for f in cn.db.tar.zst staging-key.asc FINGERPRINT.txt; do
            [ -s "$REPO_DIR_ARG/$f" ] ||
                die "--repo-dir '$REPO_DIR_ARG' is missing required file '$f'"
        done
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"
        cp -a "$REPO_DIR_ARG"/. "$STAGING_DIR"/
        lpos_info "staging repo copied from $REPO_DIR_ARG"
    else
        lpos::require_cmd gh
        if staging_valid; then
            lpos_info "reusing existing staging artifact at $STAGING_DIR"
            return 0
        fi
        local run_id
        run_id=$(gh run list -R "$LPOS_GH_REPO" --workflow packages.yml \
            --branch main --status success --limit 1 \
            --json databaseId --jq '.[0].databaseId')
        [ -n "$run_id" ] || die \
            "no successful packages.yml run on main in $LPOS_GH_REPO yet — push to main, wait for the run, or pass --repo-dir (see README 'CI 行为')"
        lpos_info "downloading staging-repo artifact from run $run_id"
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"
        gh run download -R "$LPOS_GH_REPO" "$run_id" \
            --name staging-repo --dir "$STAGING_DIR"
    fi
    staging_valid || die "staging artifact incomplete in $STAGING_DIR"
    if grep -q '^EPHEMERAL: yes' "$STAGING_DIR/FINGERPRINT.txt" 2>/dev/null; then
        lpos_warn "staging artifact was signed with an EPHEMERAL run key (GPG_PRIVATE_KEY secret not configured). It will still be consumed for this throwaway local smoke VM, but it proves nothing about provenance — configure the persistent staging key for real verification."
    fi
}

host_main() {
    lpos::require_cmd sha256sum md5sum ssh-keygen awk
    lpos::engine_detect
    lpos::ensure_binfmt_arm64

    mkdir -p "$AARCH64_DIR"

    prepare_staging
    fetch_rootfs_tarball

    # One-time ed25519 smoke key: private half stays on the host under
    # test/build (gitignored), public half is injected into the rootfs.
    rm -f "$AARCH64_DIR/smoke_key" "$AARCH64_DIR/smoke_key.pub"
    ssh-keygen -q -t ed25519 -N '' -C lpos-aarch64-smoke -f "$AARCH64_DIR/smoke_key"
    chmod 600 "$AARCH64_DIR/smoke_key"

    lpos_info "building rootfs inside an aarch64 container (menci/archlinuxarm:base; first run pulls the image)..."
    "$LPOS_ENGINE" run --rm --platform linux/arm64 \
        -e LPOS_HOST_UID="$(id -u)" \
        -v "$REPO_ROOT":/work -w /work \
        menci/archlinuxarm:base \
        bash test/mkrootfs-aarch64.sh --inner

    local out
    for out in Image initramfs-linux.img rootfs.ext4 smoke_key; do
        [ -s "$AARCH64_DIR/$out" ] || die "expected output $AARCH64_DIR/$out is missing"
    done
    [ -d "$ROOTFS_DIR" ] || die "expected output directory $ROOTFS_DIR is missing"
    lpos_info "rootfs build complete: $AARCH64_DIR"
    lpos_info "next: bash test/smoke-aarch64.sh"
}

container_main() {
    # Runs INSIDE the aarch64 build container (repo mounted at /work).
    # Nested container engines are NOT available here — the host phase did
    # engine/binfmt/gh work already.
    lpos::require_cmd bsdtar pacman pacman-key mkfs.ext4 truncate du

    # Speed the container's own package installs through TUNA as well.
    printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo\n' \
        > /etc/pacman.d/mirrorlist
    pacman -Sy --noconfirm --needed e2fsprogs archlinuxarm-keyring

    # 1) Fresh unpack of the verified tarball.
    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"
    lpos_info "unpacking $CACHE_FILE into $ROOTFS_DIR"
    bsdtar -xpf "$CACHE_FILE" -C "$ROOTFS_DIR"

    # 2) Target-root pacman keyring: init + ALARM keyring, then import and
    #    locally sign the staging key — mandatory before a
    #    SigLevel Required DatabaseOnly transaction against cn.db.tar.zst.
    GPGDIR=$ROOTFS_DIR/etc/pacman.d/gnupg
    mkdir -p "$GPGDIR"
    lpos_info "initialising target keyring ($GPGDIR)"
    pacman-key --gpgdir "$GPGDIR" --init
    pacman-key --gpgdir "$GPGDIR" --populate archlinuxarm
    pacman-key --gpgdir "$GPGDIR" --add "$STAGING_DIR/staging-key.asc"
    FPR=$(awk '/^FINGERPRINT:/ {print $2}' "$STAGING_DIR/FINGERPRINT.txt")
    [ -n "$FPR" ] || die "cannot parse signing fingerprint from $STAGING_DIR/FINGERPRINT.txt"
    pacman-key --gpgdir "$GPGDIR" --lsign-key "$FPR"

    # 3) Incremental install via pacman -r against a dedicated config:
    #    ALARM upstream repos (TUNA) + the staging file:// repo.
    cat > "$AARCH64_DIR/pacman-install.conf" <<'EOF'
# pacman.conf used INSIDE the aarch64 build container to install into the
# smoke rootfs. The install root is passed via `pacman -r` on the command
# line; paths below are container paths (repo mounted at /work).
[options]
Architecture = aarch64
# ALARM upstream: signed packages, unsigned databases (PITFALLS 2).
SigLevel = Required DatabaseOptional
NoProgressBar
# pacman 7's landlock/seccomp sandbox cannot be satisfied reliably under
# qemu-user emulation; this transaction targets a throwaway root, so the
# sandbox is disabled here (and ONLY here — never in shipped configs).
DisableSandbox
GPGDir = /work/test/build/aarch64/rootfs/etc/pacman.d/gnupg

[core]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo

[extra]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo

[community]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo

[alarm]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo

[aur]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo

[staging]
# linuxphoneOS CI staging repo (01-01 artifact contract).
SigLevel = Required DatabaseOnly
Server = file:///work/test/build/staging-repo
EOF
    lpos_info "installing openssh + linuxphoneos-cn into the rootfs (pacman -r, this also runs the CN factory scriptlets)"
    mkdir -p "$AARCH64_DIR/pacman-cache"
    pacman -r "$ROOTFS_DIR" --config "$AARCH64_DIR/pacman-install.conf" \
        --cachedir "$AARCH64_DIR/pacman-cache" \
        --noconfirm --needed -Syu openssh linuxphoneos-cn

    # 4) Units: enable sshd (gate) + basic QEMU networking (SSH over the
    #    user-mode NAT needs the NIC up). Plan calls for plain symlinks.
    WANTS=$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants
    mkdir -p "$WANTS" "$ROOTFS_DIR/etc/systemd/network"
    ln -sfn /usr/lib/systemd/system/sshd.service "$WANTS/sshd.service"
    ln -sfn /usr/lib/systemd/system/systemd-networkd.service "$WANTS/systemd-networkd.service"
    ln -sfn /usr/lib/systemd/system/systemd-resolved.service "$WANTS/systemd-resolved.service"
    cat > "$ROOTFS_DIR/etc/systemd/network/80-qemu-dhcp.network" <<'EOF'
[Match]
Name=en* eth0

[Network]
DHCP=yes
EOF
    ln -sfn /run/systemd/resolve/stub-resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    # 5) One-time smoke key injection. Root gets password field '*' (no
    #    password login possible, pubkey auth unaffected).
    mkdir -p "$ROOTFS_DIR/root/.ssh"
    chmod 700 "$ROOTFS_DIR/root/.ssh"
    cat "$AARCH64_DIR/smoke_key.pub" >> "$ROOTFS_DIR/root/.ssh/authorized_keys"
    chmod 600 "$ROOTFS_DIR/root/.ssh/authorized_keys"
    sed -i 's/^root:[^:]*:/root:*:/' "$ROOTFS_DIR/etc/shadow"

    # 6) Kernel artifacts from the rootfs /boot.
    cp "$ROOTFS_DIR/boot/Image" "$AARCH64_DIR/Image"
    cp "$ROOTFS_DIR/boot/initramfs-linux.img" "$AARCH64_DIR/initramfs-linux.img"

    # 7) ext4 rootfs image, with headroom for the in-VM pacman -Syu gate.
    local usage_mb size_mb
    usage_mb=$(du -sm "$ROOTFS_DIR" | awk '{print $1}')
    size_mb=$((usage_mb + 3072))
    lpos_info "packing rootfs.ext4 (${size_mb}M: ${usage_mb}M used + 3G headroom)"
    rm -f "$AARCH64_DIR/rootfs.ext4"
    truncate -s "${size_mb}M" "$AARCH64_DIR/rootfs.ext4"
    mkfs.ext4 -q -F -d "$ROOTFS_DIR" "$AARCH64_DIR/rootfs.ext4"

    # Hand the produced files back to the invoking host user.
    if [ -n "${LPOS_HOST_UID:-}" ]; then
        chown -R "$LPOS_HOST_UID" "$AARCH64_DIR"
    fi
    lpos_info "container-side rootfs build finished"
}

if [ "$INNER" = yes ]; then
    container_main
else
    host_main
fi
