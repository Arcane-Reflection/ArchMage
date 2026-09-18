#!/usr/bin/env bash
# mkrootfs-x86_64.sh — build the x86_64 QEMU development image rootfs (the
# Phase 2 official replacement for vm-x86_64.sh's manual image acquisition).
#
# Structural sibling of test/mkrootfs-aarch64.sh (01-02) with two deliberate
# differences driven by the platform:
#   - NO rootfs tarball and NO binfmt: the `archlinux:base` container IS the
#     x86_64 rootfs source, and everything runs natively on x86_64 hosts.
#   - pacstrap is used instead of `pacman -r`: pacstrap copies the build
#     container's keyring into the fresh root by default, so the staging key
#     (imported + locally signed into the CONTAINER keyring below) lands in
#     the image keyring and the SigLevel Required staging repo installs in a
#     single verified transaction. Same end state as the aarch64 foreign-root
#     keyring surgery, fewer moving parts.
#
# The staging repo itself is embedded into the image at
# /var/lib/archmage/staging (arch=any meta packages, a few MB) so the in-VM
# `pacman -Syu` gate can exercise the [archmage] repo declaration end to end
# without network hosting.
#
# Usage:
#   test/mkrootfs-x86_64.sh --from-ci        # default; gh run download of
#                                            # the latest successful main
#                                            # run's staging-repo artifact
#   test/mkrootfs-x86_64.sh --repo-dir PATH  # consume an already
#                                            # downloaded artifact dir
# Environment:
#   ARCHMAGE_GH_REPO   GitHub <owner>/<repo> for --from-ci
#                  (default: uMaj35ty/ArchMage)
#
# Internal flag (do not pass): --inner — re-executed inside the x86_64 build
# container by the host phase.
#
# Signature discipline: the staging repo is consumed at SigLevel Required
# (signed database verified); its key is locally signed into the image
# keyring BEFORE the transaction, so the image trusts exactly what built it.

set -euo pipefail

usage() {
    cat <<'EOF'
mkrootfs-x86_64.sh — x86_64 QEMU dev image rootfs from the CI staging repo

Usage:
  test/mkrootfs-x86_64.sh [--from-ci | --repo-dir PATH]

Options:
  --from-ci        Download the staging-repo artifact of the latest
                   successful packages.yml run on main via gh (default).
  --repo-dir PATH  Use an already-downloaded staging-repo artifact
                   directory (needs cn.db.tar.zst, staging-key.asc,
                   FINGERPRINT.txt).
  -h, --help       Show this help.

Environment:
  ARCHMAGE_GH_REPO     GitHub <owner>/<repo> for --from-ci
                   (default: uMaj35ty/ArchMage)

Outputs (test/build/x86_64/):
  vmlinuz-linux, initramfs-linux.img   kernel + initramfs for -kernel boot
  rootfs.ext4                          ext4 root filesystem (virtio target)
  rootfs/                              unpacked rootfs (discipline checks)
  smoke_key, smoke_key.pub             one-time SSH key (host side, gitignored)
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

REPO_ROOT=$(archmage::repo_root)
BUILD_DIR=$REPO_ROOT/test/build
X86_64_DIR=$BUILD_DIR/x86_64
STAGING_DIR=$BUILD_DIR/staging-repo
ROOTFS_DIR=$X86_64_DIR/rootfs

ARCHMAGE_GH_REPO=${ARCHMAGE_GH_REPO:-uMaj35ty/ArchMage}

# x86_64 phosh stack from official Arch extra (research STACK.md: phosh is
# in extra). Minimal set on purpose — the graphical session is informational
# in the smoke, never a gate.
PHOSH_PKGS=(phoc phosh squeekboard gnome-console)

# Required staging artifact files (01-01 contract).
staging_valid() {
    [ -s "$STAGING_DIR/cn.db.tar.zst" ] &&
        [ -s "$STAGING_DIR/staging-key.asc" ] &&
        [ -s "$STAGING_DIR/FINGERPRINT.txt" ]
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
        archmage_info "staging repo copied from $REPO_DIR_ARG"
    else
        archmage::require_cmd gh
        if staging_valid; then
            archmage_info "reusing existing staging artifact at $STAGING_DIR"
            return 0
        fi
        local run_id
        run_id=$(gh run list -R "$ARCHMAGE_GH_REPO" --workflow packages.yml \
            --branch main --status success --limit 1 \
            --json databaseId --jq '.[0].databaseId')
        [ -n "$run_id" ] || die \
            "no successful packages.yml run on main in $ARCHMAGE_GH_REPO yet — push to main, wait for the run, or pass --repo-dir (see README 'CI 行为')"
        archmage_info "downloading staging-repo artifact from run $run_id"
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"
        gh run download -R "$ARCHMAGE_GH_REPO" "$run_id" \
            --name staging-repo --dir "$STAGING_DIR"
    fi
    staging_valid || die "staging artifact incomplete in $STAGING_DIR"
    # pacman>=6 requests the extensionless <repo>.db first; provide both the
    # canonical and legacy names for the [archmage] repo (flat layout).
    ln -sfn cn.db.tar.zst "$STAGING_DIR/archmage.db"
    [ -s "$STAGING_DIR/cn.db.tar.zst.sig" ] && ln -sfn cn.db.tar.zst.sig "$STAGING_DIR/archmage.db.sig" || true
    if grep -q '^EPHEMERAL: yes' "$STAGING_DIR/FINGERPRINT.txt" 2>/dev/null; then
        archmage_warn "staging artifact was signed with an EPHEMERAL run key (GPG_PRIVATE_KEY secret not configured). It will still be consumed for this throwaway local dev VM, but it proves nothing about provenance — configure the persistent staging key for real verification."
    fi
}

host_main() {
    archmage::require_cmd sha256sum ssh-keygen awk
    archmage::engine_detect
    # Native x86_64 build inside an x86_64 container — no binfmt, no cross.

    mkdir -p "$X86_64_DIR"

    prepare_staging

    # One-time ed25519 smoke key: private half stays on the host under
    # test/build (gitignored), public half is injected into the rootfs.
    rm -f "$X86_64_DIR/smoke_key" "$X86_64_DIR/smoke_key.pub"
    ssh-keygen -q -t ed25519 -N '' -C archmage-x86_64-smoke -f "$X86_64_DIR/smoke_key"
    chmod 600 "$X86_64_DIR/smoke_key"

    archmage_info "building rootfs inside an x86_64 container (archlinux:base; first run pulls the image)..."
    # --privileged: pacstrap mounts the API filesystems (proc/sys/dev) inside
    # the install root (same privilege posture as bootstrap/bootstrap.sh).
    "$ARCHMAGE_ENGINE" run --rm --privileged --platform linux/x86_64 \
        -e ARCHMAGE_HOST_UID="$(id -u)" \
        -v "$REPO_ROOT":/work -w /work \
        archlinux:base \
        bash test/mkrootfs-x86_64.sh --inner

    local out
    for out in vmlinuz-linux initramfs-linux.img rootfs.ext4 smoke_key; do
        [ -s "$X86_64_DIR/$out" ] || die "expected output $X86_64_DIR/$out is missing"
    done
    [ -d "$ROOTFS_DIR" ] || die "expected output directory $ROOTFS_DIR is missing"
    archmage_info "rootfs build complete: $X86_64_DIR"
    archmage_info "next: bash test/smoke-x86_64.sh"
}

container_main() {
    # Runs INSIDE the x86_64 build container (repo mounted at /work).
    archmage::require_cmd pacman

    [ "$(uname -m)" = x86_64 ] || die "container phase requires x86_64 (native build; cross is intentionally unsupported)"

    # Speed the container's own transactions through TUNA as well. pacman 7's
    # landlock/seccomp sandbox is unavailable on some container hosts
    # (observed live: "Landlock is not supported by the kernel"); this
    # container is a throwaway root, so its OWN /etc/pacman.conf disables the
    # sandbox — same scope rule as 01-02: throwaway roots only, never
    # shipped configs.
    printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch\n' \
        > /etc/pacman.d/mirrorlist
    if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
        sed -i 's/^\[options\]$/[options]\nDisableSandbox/' /etc/pacman.conf
    fi
    pacman -Sy --noconfirm --needed arch-install-scripts archlinux-keyring
    archmage::require_cmd pacstrap pacman-key mkfs.ext4 truncate du

    # 1) Trust the staging key in the CONTAINER keyring: pacstrap copies the
    #    build host's keyring into the fresh root by default, so this both
    #    unblocks the Required transaction AND ships the right trust into
    #    the image. (--init first: the base image ships keyring data but no
    #    local secret key, which lsign-key needs.)
    archmage_info "importing + locally signing the staging key into the container keyring (pacstrap copies it into the image)"
    pacman-key --init
    pacman-key --add "$STAGING_DIR/staging-key.asc"
    FPR=$(awk '/^FINGERPRINT:/ {print $2}' "$STAGING_DIR/FINGERPRINT.txt")
    [ -n "$FPR" ] || die "cannot parse signing fingerprint from $STAGING_DIR/FINGERPRINT.txt"
    pacman-key --lsign-key "$FPR"

    # 2) Transaction config: Arch x86_64 core/extra via TUNA + the staging
    #    repo at the strictest level. This file ALSO becomes the shipped
    #    /etc/pacman.conf (its [archmage] Server points at the copy embedded
    #    into the image, written below).
    cat > "$X86_64_DIR/pacman-install.conf" <<'EOF'
# pacman.conf for the x86_64 dev image: used by pacstrap for the install
# transaction AND shipped as the image's /etc/pacman.conf (mkrootfs rewrites
# nothing; the [archmage] Server points at the staging copy embedded in the
# image at /var/lib/archmage/staging).
[options]
Architecture = x86_64
# Arch mirrors: signed packages; database verification stays optional here
# per the repo-section policy used across ArchMage (Required + DB policy
# explicit per section below).
SigLevel = Required DatabaseOptional
NoProgressBar
# Package cache on the repo mount (host-visible for reuse across runs).
CacheDir = /work/test/build/x86_64/pacman-cache
# The pacstrap transaction targets a throwaway build root; pacman 7's
# sandbox is not reliably satisfiable under containerization (01-02
# decision). The line below is removed again before this file ships as
# the image's /etc/pacman.conf — shipped configs never carry it.
 DisableSandbox

[core]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch

[extra]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch

[archmage]
# ArchMage staging repo (packages.yml CI artifact), strictest level:
# package signatures Required; no weaker database token, so the signed
# database is verified as well. Two servers, both file://:
#   1. the build-time checkout path (valid inside the build container,
#      where the pacstrap transaction runs with pacman -r semantics)
#   2. the copy embedded into the image at /var/lib/archmage/staging
#      (valid inside the booted VM; pacman falls through server 1, whose
#      path does not exist there)
SigLevel = Required
Server = file:///work/test/build/staging-repo
Server = file:///var/lib/archmage/staging
EOF

    # 3) Fresh rootfs via pacstrap (copies the container keyring, including
    #    the locally-signed staging key, into the target).
    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"
    archmage_info "pacstrapping base + linux + phosh stack + archmage-cn into $ROOTFS_DIR"
    mkdir -p "$X86_64_DIR/pacman-cache"
    # archmage-phosh-safety + archmage-cn-apn: the same stage-2 set as
    # bootstrap/bootstrap.sh (02-03). verify-image.sh asserts
    # safety_config_present (phosh ⇒ safety layer) and apn_presets_present on
    # this image kind — without these two the structural gate legitimately
    # fails, so the dev image carries the full factory overlay set.
    # arch-install-scripts only parses short options; without -i pacstrap
    # passes --noconfirm to pacman itself.
    pacstrap -C "$X86_64_DIR/pacman-install.conf" \
        "$ROOTFS_DIR" \
        base linux linux-firmware openssh "${PHOSH_PKGS[@]}" \
        archmage-cn archmage-phosh-safety archmage-cn-apn

    # 4) Units: sshd (gate) + QEMU networking (hostfwd SSH needs the NIC up).
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
    #    password login possible, pubkey auth unaffected — 01-02 decision).
    mkdir -p "$ROOTFS_DIR/root/.ssh"
    chmod 700 "$ROOTFS_DIR/root/.ssh"
    cat "$X86_64_DIR/smoke_key.pub" >> "$ROOTFS_DIR/root/.ssh/authorized_keys"
    chmod 600 "$ROOTFS_DIR/root/.ssh/authorized_keys"
    sed -i 's/^root:[^:]*:/root:*:/' "$ROOTFS_DIR/etc/shadow"

    # 6) Ship the transaction config as /etc/pacman.conf WITHOUT the
    #    throwaway-root sandbox exemption, and embed the staging repo so the
    #    [archmage] Server is live inside the VM.
    sed '/^[[:space:]]*DisableSandbox[[:space:]]*$/d' "$X86_64_DIR/pacman-install.conf" \
        > "$ROOTFS_DIR/etc/pacman.conf"
    mkdir -p "$ROOTFS_DIR/var/lib/archmage"
    cp -a "$STAGING_DIR" "$ROOTFS_DIR/var/lib/archmage/staging"

    # 7) Kernel artifacts from the rootfs /boot.
    cp "$ROOTFS_DIR/boot/vmlinuz-linux" "$X86_64_DIR/vmlinuz-linux"
    cp "$ROOTFS_DIR/boot/initramfs-linux.img" "$X86_64_DIR/initramfs-linux.img"

    # 8) ext4 rootfs image, with headroom for the in-VM pacman -Syu gate.
    local usage_mb size_mb
    usage_mb=$(du -sm "$ROOTFS_DIR" | awk '{print $1}')
    size_mb=$((usage_mb + 3072))
    archmage_info "packing rootfs.ext4 (${size_mb}M: ${usage_mb}M used + 3G headroom)"
    rm -f "$X86_64_DIR/rootfs.ext4"
    truncate -s "${size_mb}M" "$X86_64_DIR/rootfs.ext4"
    mkfs.ext4 -q -F -d "$ROOTFS_DIR" "$X86_64_DIR/rootfs.ext4"

    # Hand the produced files back to the invoking host user.
    if [ -n "${ARCHMAGE_HOST_UID:-}" ]; then
        chown -R "$ARCHMAGE_HOST_UID" "$X86_64_DIR"
    fi
    archmage_info "container-side rootfs build finished"
}

if [ "$INNER" = yes ]; then
    container_main
else
    host_main
fi
