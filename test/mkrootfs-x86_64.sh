#!/usr/bin/env bash
# mkrootfs-x86_64.sh — build the x86_64 QEMU development image (the Phase 2
# official replacement for vm-x86_64.sh's manual image acquisition; btrfs flat
# subvolume layout since 03-03).
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
# Output since 03-03 (UPDATE-01): a GPT-partitioned disk image rootfs.img —
# p1 ESP (512 MiB, vfat), p2 btrfs (LABEL=archmage-root) holding the
# pmbootstrap !2233 flat subvolume layout:
#
#   @            root subvolume, set as the DEFAULT subvolume (subvolid
#                points at @ — fstab mounts the root WITHOUT any subvol=
#                token, the hard prerequisite for snapper rollback semantics,
#                03-RESEARCH Q3 回滚语义陷阱)
#   @root /var-  satellite subvolumes mounted with explicit subvol= tokens:
#   @snapshots     @root -> /root, @var -> /var (chattr +C nodatacow, keeps
#   @srv           COW write amplification off logs/db/containers, PITFALLS 6),
#   @tmp           @snapshots -> /.snapshots (outside @ so snapshots survive
#                  a rollback that replaces @), @srv -> /srv, @tmp -> /tmp
#   toplevel (subvolid 5) stays unmounted.
#
# GRUB goes to the ESP via the removable fallback path
# (--target=x86_64-efi --removable --no-nvram: no NVRAM dependency, OVMF
# falls back to \EFI\BOOT\BOOTX64.EFI), with grub-btrfs/snapper/snap-pac
# preinstalled for the rollback chain (test/rollback-x86_64.sh).
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
  rootfs.img                           GPT disk: p1 ESP + p2 btrfs flat
                                       subvolume layout (virtio target)
  rootfs/                              unpacked rootfs tree (discipline checks)
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
        # Same-path guard: --repo-dir may point at the default staging dir
        # itself (idempotent reuse). rm+cp on the same path would DESTROY the
        # artifact directory, so only copy when the paths differ.
        local src dst
        src=$(cd -- "$REPO_DIR_ARG" && pwd)
        dst=$(cd -- "$STAGING_DIR" 2>/dev/null && pwd) || dst=""
        if [ "$src" != "$dst" ]; then
            rm -rf "$STAGING_DIR"
            mkdir -p "$STAGING_DIR"
            cp -a "$REPO_DIR_ARG"/. "$STAGING_DIR"/
            archmage_info "staging repo copied from $REPO_DIR_ARG"
        else
            archmage_info "staging repo dir is the default staging dir — validating in place"
        fi
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
    # canonical and legacy names. 03-03 two-channel: the shipped
    # /etc/pacman.conf declares [archmage-testing] (the CI staging channel)
    # and pacman requests <section>.db per section name — so the
    # testing-channel DB name is provided alongside the legacy [archmage]
    # name (packages.yml keeps producing cn.db.tar.zst; CI zero-change).
    ln -sfn cn.db.tar.zst "$STAGING_DIR/archmage.db"
    [ -s "$STAGING_DIR/cn.db.tar.zst.sig" ] && ln -sfn cn.db.tar.zst.sig "$STAGING_DIR/archmage.db.sig" || true
    ln -sfn cn.db.tar.zst "$STAGING_DIR/archmage-testing.db"
    [ -s "$STAGING_DIR/cn.db.tar.zst.sig" ] && ln -sfn cn.db.tar.zst.sig "$STAGING_DIR/archmage-testing.db.sig" || true
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
    for out in vmlinuz-linux initramfs-linux.img rootfs.img smoke_key; do
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
    # Build-container toolchain: sfdisk (arch-install-scripts/util-linux),
    # mkfs.btrfs + subvolume tooling (btrfs-progs), mkfs.vfat (dosfstools) —
    # these run against the target disk HERE in the container, they are not
    # merely pacstrap'd into the image.
    pacman -Sy --noconfirm --needed arch-install-scripts archlinux-keyring \
        btrfs-progs dosfstools
    archmage::require_cmd pacstrap pacman-key mkfs.ext4 sfdisk mkfs.btrfs \
        mkfs.vfat losetup btrfs truncate du

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
    #    /etc/pacman.conf (its [archmage-testing] Server points at the copy
    #    embedded into the image, written below).
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
# Package cache lives on the repo mount (host-visible for reuse across
# runs); this line is stripped before the file ships as /etc/pacman.conf.
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

[archmage-testing]
# ArchMage testing channel (= the packages.yml CI staging artifact; 03-03
# two-channel model), strictest level: package signatures Required; no
# weaker database token, so the signed database is verified as well. Two
# servers, both file://:
#   1. the build-time checkout path (valid inside the build container,
#      where the pacstrap transaction runs with pacman -r semantics)
#   2. the copy embedded into the image at /var/lib/archmage/staging
#      (valid inside the booted VM)
# Server 1 and the CacheDir line are stripped at ship time (step 6), like
# DisableSandbox — the shipped /etc/pacman.conf only carries paths that
# exist inside the VM.
SigLevel = Required
Server = file:///work/test/build/staging-repo
Server = file:///var/lib/archmage/staging
EOF

    # 3) Fresh GPT disk + btrfs flat subvolume layout, then pacstrap into @.
    #    Image size is a fixed sparse allocation (only touched extents consume
    #    space); a post-pacstrap free-space check fails the build loudly if a
    #    future package set outgrows it. The image is built under a .partial
    #    name and atomically renamed at the very end: a crashed build must
    #    never leave a plausible-looking rootfs.img behind (consumers gate on
    #    its existence — smoke/rollback artifacts_present).
    rm -rf "$ROOTFS_DIR"
    rm -f "$X86_64_DIR/rootfs.img" "$X86_64_DIR/rootfs.img.partial" "$X86_64_DIR/esp.img" "$X86_64_DIR/btrfs.img"
    mkdir -p "$ROOTFS_DIR"
    # Defensive: stale mounts from a crashed previous run would silently
    # redirect pacstrap into the old tree.
    umount -l -R "$ROOTFS_DIR" 2>/dev/null || true

    RM_LOOP=""
    # NOTE: esp_loop/btrfs_loop are deliberately NOT function-locals: the
    # EXIT trap (cleanup_disk) runs after the call stack has unwound, where
    # `local` variables from container_main are out of scope and `set -u`
    # would abort the trap itself with "unbound variable" — masking the
    # real build error that triggered the exit (observed live).
    esp_loop=""
    btrfs_loop=""
    IMG_TOTAL_MB=8192
    cleanup_disk() {
        for m in "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev" \
                 "$ROOTFS_DIR/boot/efi" "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/srv" \
                 "$ROOTFS_DIR/.snapshots" "$ROOTFS_DIR/var" "$ROOTFS_DIR/root" \
                 "$ROOTFS_DIR" /tmp/btrfs-top; do
            mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null || true
        done
        for l in "$esp_loop" "$btrfs_loop" "$RM_LOOP"; do
            [ -n "$l" ] && losetup -d "$l" 2>/dev/null || true
        done
        return 0
    }
    trap cleanup_disk EXIT

    archmage_info "creating ${IMG_TOTAL_MB}M sparse GPT disk image rootfs.img (ESP 512M + btrfs)"
    truncate -s "${IMG_TOTAL_MB}M" "$X86_64_DIR/rootfs.img.partial"
    # p1: EFI System Partition (512 MiB = 1048576 sectors); p2: the rest,
    # Linux filesystem (btrfs). Explicit GUID types keep sfdisk output
    # unambiguous for OVMF (fallback loader discovery needs the ESP type).
    sfdisk "$X86_64_DIR/rootfs.img.partial" <<'SFDISK'
label: gpt
name="esp", size=1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
name="root", type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
SFDISK

    # Loop-device strategy: this build formats the ESP and the btrfs data
    # area on SEPARATE sparse files via BARE loop mounts (loop device itself,
    # no partition scan), then dd-assembles the final GPT image. Rationale:
    # losetup -P works, but the matching loopNpN /dev nodes materialize
    # asynchronously (udev on the shared host /dev) and on some hosts never
    # appear at all — formatting through partition nodes is therefore a race
    # we cannot win portably. The RESULT is identical: GPT with p1 ESP
    # (vfat) + p2 btrfs, sector layout exactly as the sfdisk table below.
    archmage_info "creating ${IMG_TOTAL_MB}M GPT disk image rootfs.img (ESP 512M + btrfs) via dd assembly"
    local esp_img=$X86_64_DIR/esp.img
    local btrfs_img=$X86_64_DIR/btrfs.img
    rm -f "$esp_img" "$btrfs_img"
    ESP_START_MB=1      # GPT: p1 begins at sector 2048 (1 MiB)
    ROOT_START_MB=513   # p2 begins after the 512 MiB ESP
    # Byte-exact p2 sizing. Two constraints beyond "fit the GPT":
    #   1. stop short of the image end so the dd assembly below can never
    #      clobber the backup GPT header (33 sectors);
    #   2. the btrfs DEVICE AREA must be 1 MiB-aligned and smaller than the
    #      kernel's view of p2: the kernel rounds the partition size DOWN to
    #      a 1 MiB multiple and REFUSES to mount a btrfs whose superblock
    #      total_bytes exceeds that (observed live: "BTRFS error (device
    #      vda2): device total_bytes should be at most 8050966528 but found
    #      8051994624" -> "open_ctree failed: -22"). mkfs.btrfs records the
    #      exact file size it was given, so the fs image gets (IMG_TOTAL_MB
    #      - 515) MiB: p2's aligned size is (IMG_TOTAL_MB - 513) MiB, minus
    #      one more MiB of slack (all 1 MiB-aligned, mkfs never has to round).
    ROOT_SECTORS=$(( (IMG_TOTAL_MB - 515) * 2048 ))
    truncate -s 512M "$esp_img"
    truncate -s $((ROOT_SECTORS * 512)) "$btrfs_img"

    attach_bare() {  # attach_bare <img>  -> RM_LOOP (bare loop, no partscan)
        local attempt i free minor
        RM_LOOP=""
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            # Preferred path: ask the kernel (loop-control) for a free loop
            # device, create its node if missing, attach to THAT node. Bare
            # `losetup -f --show` fails outright when the node for the device
            # it picked does not exist — the shared-host /dev race below can
            # swallow freshly mknod'd nodes, and the node set is not limited
            # to loop0-7 (observed live: loop9/loop65 in use on this host).
            free=$(losetup -f 2>/dev/null) || free=""
            if [ -n "$free" ]; then
                minor=${free#/dev/loop}
                case "$minor" in
                    ''|*[!0-9]*) minor="" ;;
                esac
                [ -e "$free" ] || [ -z "$minor" ] || \
                    mknod "$free" b 7 "$minor" 2>/dev/null || true
                # NOTE: explicit-device losetup is silent on success (unlike
                # -f --show) — set RM_LOOP from $free, not from stdout.
                if losetup "$free" "$1" 2>/dev/null; then
                    RM_LOOP=$free
                    return 0
                fi
            fi
            # Fallback: the plain -f --show form, then recreate the standard
            # nodes and retry after a pause.
            if RM_LOOP=$(losetup -f --show "$1" 2>/dev/null); then
                return 0
            fi
            RM_LOOP=""
            [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237 2>/dev/null || true
            for i in $(seq 0 15); do
                [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
            done
            sleep 2
        done
        return 1
    }

    # ESP filesystem: attach once and KEEP the loop for the whole build
    # (mkfs here, /boot/efi mount below) — every attach cycle is a chance
    # for the shared-host loop-node race to eat it (observed live: the
    # 4th attach failed 3 retries while the first three succeeded).
    attach_bare "$esp_img" || die "losetup failed for $esp_img"
    mkfs.vfat -F 32 -n ESP "$RM_LOOP"
    esp_loop=$RM_LOOP
    RM_LOOP=""

    # btrfs data area: attach once for the whole build (mkfs here, subvolume
    # creation + target mounts below).
    attach_bare "$btrfs_img" || die "losetup failed for $btrfs_img"
    mkfs.btrfs -f -L archmage-root "$RM_LOOP"
    btrfs_loop=$RM_LOOP

    # Flat subvolume layout (pmbootstrap !2233, 03-RESEARCH Q3): created on a
    # temporary toplevel mount (subvolid 5 stays unmounted in the image).
    mkdir -p /tmp/btrfs-top
    mount "$btrfs_loop" /tmp/btrfs-top
    local sv
    for sv in @ @root @var @snapshots @srv @tmp; do
        btrfs subvolume create "/tmp/btrfs-top/$sv" >/dev/null
    done
    # @var: nodatacow via chattr +C on the empty subvolume root — every file
    # created inside inherits NoCOW (PITFALLS 6: logs/db/containers must not
    # pay the COW write-amplification tax on flash storage).
    chattr +C /tmp/btrfs-top/@var
    # Root subvolume becomes the FS default: fstab's root line mounts
    # WITHOUT a subvol= token, and `snapper rollback` needs exactly that.
    btrfs subvolume set-default /tmp/btrfs-top/@
    umount /tmp/btrfs-top

    # Mount the target tree. The root mount carries NO subvol= token — it
    # resolves to whatever the default subvolume is (@). The five satellites
    # keep explicit subvol= tokens.
    mount -o compress=zstd:1,noatime,ssd "$btrfs_loop" "$ROOTFS_DIR"
    local root_subvol
    root_subvol=$(btrfs subvolume show "$ROOTFS_DIR" | awk '/^[[:space:]]*Name:/ {print $2}')
    [ "$root_subvol" = "@" ] || die "root mount did not land on the @ subvolume (default subvolume mis-set; got '$root_subvol')"
    mkdir -p "$ROOTFS_DIR"/{root,var,.snapshots,srv,tmp,boot/efi}
    mount -o subvol=@root,compress=zstd:1,noatime,ssd "$btrfs_loop" "$ROOTFS_DIR/root"
    mount -o subvol=@var,compress=zstd:1,noatime,ssd "$btrfs_loop" "$ROOTFS_DIR/var"
    mount -o subvol=@snapshots,compress=zstd:1,noatime,ssd "$btrfs_loop" "$ROOTFS_DIR/.snapshots"
    mount -o subvol=@srv,compress=zstd:1,noatime,ssd "$btrfs_loop" "$ROOTFS_DIR/srv"
    mount -o subvol=@tmp,compress=zstd:1,noatime,ssd "$btrfs_loop" "$ROOTFS_DIR/tmp"
    # ESP: mount the already-attached loop into the tree (grub-install
    # writes the fallback loader here through this mount).
    mount "$esp_loop" "$ROOTFS_DIR/boot/efi"

    archmage_info "pacstrapping base + linux + phosh stack + grub/snapper chain + archmage-cn into the @ subvolume"
    # Fresh throwaway cache: a cache carried over from a previous run holds
    # packages signed by a PREVIOUS staging key; after key rotation
    # (ephemeral local keys) the transaction fails signature verification.
    rm -rf "$X86_64_DIR/pacman-cache"
    mkdir -p "$X86_64_DIR/pacman-cache"
    # archmage-phosh-safety + archmage-cn-apn: the same stage-2 set as
    # bootstrap/bootstrap.sh (02-03). verify-image.sh asserts
    # safety_config_present (phosh ⇒ safety layer) and apn_presets_present on
    # this image kind — without these two the structural gate legitimately
    # fails, so the dev image carries the full factory overlay set.
    # arch-install-scripts only parses short options; without -i pacstrap
    # passes --noconfirm to pacman itself.
    # grub/grub-btrfs/snapper/snap-pac/btrfs-progs/dosfstools: the 03-03
    # rollback chain (UPDATE-01/02). grub lands in the ESP via the removable
    # fallback path below; grub-btrfs + snap-pac are dormant until a snapper
    # config exists (created by test/rollback-x86_64.sh in-VM or by the
    # archmage-btrfs-rollback install scriptlet on btrfs roots).
    # archmage-btrfs-rollback (03-03 Task 2): snapper limits template +
    # OP6 bootimg store/rollback machinery; rides the staging repo (its
    # install scriptlet weak-binds — no-ops on non-btrfs roots).
    pacstrap -C "$X86_64_DIR/pacman-install.conf" \
        "$ROOTFS_DIR" \
        base linux linux-firmware openssh "${PHOSH_PKGS[@]}" \
        grub grub-btrfs snapper snap-pac btrfs-progs dosfstools \
        archmage-cn archmage-phosh-safety archmage-cn-apn \
        archmage-btrfs-rollback

    # Space guard: the sparse image allocation must still leave >= 1 GiB free
    # on the btrfs data subvolume for in-VM pacman transactions (the smoke's
    # -Syu gate and the rollback test's sl install + -Syu).
    local avail_mb
    avail_mb=$(df -BM --output=avail "$ROOTFS_DIR" | tail -1 | tr -dc '0-9')
    [ "${avail_mb:-0}" -ge 1024 ] || \
        die "btrfs data subvolume has only ${avail_mb}M free (< 1024M) — raise IMG_TOTAL_MB in this script"

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
    #    throwaway-root sandbox exemption, the build-time CacheDir, or the
    #    build-time staging server; embed the repo copy so the
    #    [archmage-testing] Server is live inside the VM. 03-03 two-channel:
    #    the stable channel ships COMMENTED (human-signed only,
    #    docs/REPO-CHANNELS.md) and the channel Include files are pre-created
    #    — same factory layout as bootstrap.sh stage 3 on the op6 line.
    sed -e '/^[[:space:]]*DisableSandbox[[:space:]]*$/d' \
        -e '/^CacheDir[[:space:]]*=/d' \
        -e '\|^Server = file:///work/|d' \
        "$X86_64_DIR/pacman-install.conf" \
        > "$ROOTFS_DIR/etc/pacman.conf"
    cat >> "$ROOTFS_DIR/etc/pacman.conf" <<'EOF'

# ArchMage stable channel (human-signed; docs/REPO-CHANNELS.md): ships
# COMMENTED — stable is produced only by the maintainer-host signing
# ceremony, never by CI. Enable it after filling
# /etc/pacman.d/archmage/channels/stable.conf with the hosted Server.
#[archmage-stable]
#SigLevel = Required
#Include = /etc/pacman.d/archmage/channels/stable.conf
EOF
    # Channel Include files (03-03): testing.conf documents the active
    # channel; stable.conf ships with an EMPTY server list by design — the
    # admin fills it at switch time (docs/REPO-CHANNELS.md §5).
    CHAN_DIR=$ROOTFS_DIR/etc/pacman.d/archmage/channels
    mkdir -p "$CHAN_DIR"
    cat > "$CHAN_DIR/testing.conf" <<'EOF'
# [archmage-testing] channel servers(active by default)。
# 出厂镜像经 /etc/pacman.conf 的 Server 行消费内嵌 staging 副本;
# testing 通道托管化后,在此追加托管镜像的 Server 行。
EOF
    cat > "$CHAN_DIR/stable.conf" <<'EOF'
# [archmage-stable] channel servers(切换时由管理员填写)。
# 出厂态刻意为空:stable 通道只在人工签名仪式(docs/REPO-CHANNELS.md)
# 之后才存在。启用方法:在此填 Server 行,再到 /etc/pacman.conf 取消
# [archmage-stable] 段的注释。SigLevel Required 纪律两个通道都不放松。
# Server = https://<stable-mirror>/<path>
EOF
    mkdir -p "$ROOTFS_DIR/var/lib/archmage"
    cp -a "$STAGING_DIR" "$ROOTFS_DIR/var/lib/archmage/staging"

    # 6b) GRUB defaults (03-03): GRUB_DEFAULT=saved is the prerequisite for
    #     grub-reboot one-shot boots (the rollback test's snapshot entry);
    #     serial terminal keeps GRUB itself visible in the serial.log
    #     artifact; root=LABEL matches the btrfs filesystem label.
    cat > "$ROOTFS_DIR/etc/default/grub" <<'EOF'
GRUB_DEFAULT=saved
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
GRUB_CMDLINE_LINUX="root=LABEL=archmage-root rw console=ttyS0"
EOF

    # 6c) mkinitcpio: btrfs explicitly in MODULES. Autodetect must never be
    #     the sole provider of the module — BOTH boot paths (-kernel direct
    #     and GRUB) mount the btrfs default subvolume from the initramfs;
    #     missing module = kernel panic "no root".
    sed -i 's/^MODULES=.*/MODULES=(btrfs)/' "$ROOTFS_DIR/etc/mkinitcpio.conf"
    grep -q '^MODULES=(btrfs)' "$ROOTFS_DIR/etc/mkinitcpio.conf" || \
        die "failed to set MODULES=(btrfs) in $ROOTFS_DIR/etc/mkinitcpio.conf"

    # 6d) fstab: the root line carries NO subvol= token (mounts whatever the
    #     default subvolume is — snapper rollback swaps the default's content
    #     in place; a named-subvol root mount silently breaks rollback,
    #     03-RESEARCH Q3 回滚语义陷阱). The five satellite subvolumes keep
    #     explicit subvol= tokens. @var's nodatacow comes from the chattr +C
    #     flag set on the subvolume at creation (files inherit it).
    cat > "$ROOTFS_DIR/etc/fstab" <<'EOF'
# ArchMage x86_64 dev image — btrfs flat subvolume layout (pmbootstrap !2233).
# Root mounts the DEFAULT subvolume: no subvol= token, by design.
LABEL=archmage-root  /           btrfs  rw,compress=zstd:1,noatime,ssd                    0 0
LABEL=archmage-root  /root       btrfs  rw,compress=zstd:1,noatime,ssd,subvol=@root       0 0
LABEL=archmage-root  /var        btrfs  rw,compress=zstd:1,noatime,ssd,subvol=@var        0 0
LABEL=archmage-root  /.snapshots btrfs  rw,compress=zstd:1,noatime,ssd,subvol=@snapshots  0 0
LABEL=archmage-root  /srv        btrfs  rw,compress=zstd:1,noatime,ssd,subvol=@srv        0 0
LABEL=archmage-root  /tmp        btrfs  rw,compress=zstd:1,noatime,ssd,subvol=@tmp        0 0
LABEL=ESP            /boot/efi   vfat   rw                                                0 2
EOF

    # 6e) chroot: regenerate the initramfs (picks up MODULES=(btrfs)), install
    #     GRUB to the ESP fallback path (--removable --no-nvram: no NVRAM
    #     dependency, OVMF boots \EFI\BOOT\BOOTX64.EFI directly), generate
    #     grub.cfg (10_linux finds the kernels; grub-btrfs's snapshot submenu
    #     populates once snapshots exist).
    archmage_info "regenerating initramfs + installing GRUB (ESP fallback path) + grub-mkconfig"
    mount --bind /dev  "$ROOTFS_DIR/dev"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys  "$ROOTFS_DIR/sys"
    chroot "$ROOTFS_DIR" /usr/bin/mkinitcpio -P
    # --modules: grub-install probes the partmap of /boot to decide which
    # partition modules go into the core image. /boot here is a BARE loop
    # (the btrfs area is formatted on a standalone sparse file — see the
    # loop-device strategy above), so the probe sees NO partition table and
    # the core ships without part_gpt: at boot on the real GPT disk GRUB
    # cannot enumerate (hd0,gpt2), search.fs_uuid fails and GRUB drops to
    # rescue mode (observed live). part_gpt/part_msdos are therefore pinned
    # explicitly; btrfs/zstd are already probed (listed for clarity).
    chroot "$ROOTFS_DIR" /usr/bin/grub-install \
        --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot \
        --removable --no-nvram \
        --modules="part_gpt part_msdos btrfs zstd search_fs_uuid search_label"
    # grub-btrfs's 41_snapshots-btrfs grub.d script scans for snapshots by
    # mounting the root device via /dev/disk/by-uuid/<fs-uuid>; inside the
    # pacstrap chroot there is no udev, so that device node does not exist
    # and the mount fails — killing grub-mkconfig under set -e (observed
    # live). No snapshot can exist at build time anyway, so the script is
    # disabled for THIS grub-mkconfig run and restored afterwards; the
    # in-VM regeneration (test/rollback-x86_64.sh, snap-pac) runs with real
    # udev and re-adds the snapshot submenu itself.
    # NOTE the snippet must LEAVE /etc/grub.d entirely: grub-mkconfig runs
    # every executable file in that directory regardless of its name, so a
    # renamed copy inside it still executes (also observed live).
    GRUB_BTRFS_SNIPPET=$ROOTFS_DIR/etc/grub.d/41_snapshots-btrfs
    GRUB_BTRFS_HOLD=$X86_64_DIR/41_snapshots-btrfs.hold
    if [ -f "$GRUB_BTRFS_SNIPPET" ]; then
        mv "$GRUB_BTRFS_SNIPPET" "$GRUB_BTRFS_HOLD"
    fi
    chroot "$ROOTFS_DIR" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
    if [ -f "$GRUB_BTRFS_HOLD" ]; then
        mv "$GRUB_BTRFS_HOLD" "$GRUB_BTRFS_SNIPPET"
    fi
    # Strip 10_linux's `rootflags=subvol=<subvol>` pin from the generated
    # entries (vanilla grub emits it unconditionally on btrfs — observed in
    # the factory grub.cfg as `... rw rootflags=subvol=@ root=LABEL=...`).
    # The fstab mounts the root as the DEFAULT subvolume (no subvol= token —
    # the snapper-rollback hard prerequisite), and the kernel/initramfs must
    # honor the same contract: a pinned subvol=@ would silently boot the OLD
    # @ after every rollback that replaced the default (03-RESEARCH Q3 回滚
    # 语义陷阱, boot-layer edition). The token is space-prefixed and exact,
    # so grub-btrfs's snapshot entries (`rootflags=rw,...,subvol="@snapshots/
    # ..."`) are untouched. The kernel FILE path (/@/boot/vmlinuz-linux,
    # toplevel-relative) stays as grub generated it — GRUB's embedded prefix
    # is (hd0,gpt2)/@/boot/grub either way.
    sed -i 's/ rootflags=subvol=[^ ]*//g' "$ROOTFS_DIR/boot/grub/grub.cfg"
    if grep -q 'rootflags=subvol=' "$ROOTFS_DIR/boot/grub/grub.cfg"; then
        die "grub.cfg still pins rootflags=subvol= — default-subvol boot contract broken"
    fi
    umount "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev" 2>/dev/null || true

    # 7) Kernel artifacts from the rootfs /boot (regenerated initramfs).
    cp "$ROOTFS_DIR/boot/vmlinuz-linux" "$X86_64_DIR/vmlinuz-linux"
    cp "$ROOTFS_DIR/boot/initramfs-linux.img" "$X86_64_DIR/initramfs-linux.img"

    # 8) Tear down the mount tree and detach the loop devices, then assemble
    #    the final GPT image: partition table (sfdisk), p1 = ESP content,
    #    p2 = btrfs content, at the sector offsets the table declares
    #    (conv=sparse keeps the untouched sparse regions cheap). The finished
    #    image is published under a temp name and atomically renamed — a
    #    crashed build never leaves a plausible-looking rootfs.img behind
    #    (smoke/rollback artifacts_present gate on its existence).
    cleanup_disk
    trap - EXIT
    truncate -s "${IMG_TOTAL_MB}M" "$X86_64_DIR/rootfs.img.partial"
    sfdisk "$X86_64_DIR/rootfs.img.partial" <<'SFDISK'
label: gpt
name="esp", size=1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
name="root", type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
SFDISK
    dd if="$esp_img" of="$X86_64_DIR/rootfs.img.partial" \
        bs=1M seek=$ESP_START_MB conv=notrunc,sparse status=none
    dd if="$btrfs_img" of="$X86_64_DIR/rootfs.img.partial" \
        bs=1M seek=$ROOT_START_MB conv=notrunc,sparse status=none
    rm -f "$esp_img" "$btrfs_img"
    mv -f "$X86_64_DIR/rootfs.img.partial" "$X86_64_DIR/rootfs.img"
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
