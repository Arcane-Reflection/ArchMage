#!/usr/bin/env bash
# verify-image.sh — structural gate for ArchMage OS images (02-01 Task 3).
#
# Two image kinds:
#   op6        Android-device image set: --boot-img must carry the Android
#              boot magic ("ANDROID!", first 8 bytes — the aboot artifact
#              bootstrap.sh extracts from the kbs boot partition), and the
#              rootfs image is loop-mounted for the full assertion set.
#   qemu-x86_64  Dev image booted via -kernel directly: no boot magic; only
#              the rootfs assertions apply.
#
# Full-mode assertions on the mounted rootfs (all gating; a failure turns
# the workflow red — the image never reaches the Release):
#   android_boot_magic   (op6 only) first 8 bytes of --boot-img == "ANDROID!"
#   image_sized          images are non-trivially sized (>= floors below)
#   shipping_discipline  tools/checks/assert-shipping-discipline.sh on the
#                        mounted rootfs (QUAL-01 discipline on the REAL
#                        image: TrustAll/SigLevel policy incl. the archmage
#                        Required-no-DatabaseOptional rule, firmware blobs)
#   phosh_present        /usr/bin/phosh exists in the image
#   archmage_cn_in_image pacman local db contains archmage-cn (CN defaults
#                        really made it into the image)
#   archmage_repo_live   an [archmage] repo section with at least one Server
#                        line is present in the image's effective pacman
#                        configuration (existence only — the SigLevel policy
#                        is owned by the discipline detector)
#   apn_presets_present  the three CN carrier APN profiles (archmage-apn-
#                        {cmnet,3gnet,ctnet}.nmconnection, package
#                        archmage-cn-apn) exist under the mounted rootfs's
#                        /usr/lib/NetworkManager/system-connections/
#                        (02-03, CN-03/TELE-01 machine face; both kinds)
#   ime_osk_present      (both kinds) archmage-fcitx5-osk is in the pacman
#                        local db, the phosh OSK0 contract five files are in
#                        place (sm.puri.OSK0.desktop / mobi.phosh.OSK.service
#                        / archmage-osk0-shim / environment.d IME defaults /
#                        fcitx5 profile), and squeekboard is ABSENT from the
#                        local db (03-01 full-replacement evidence)
#   waydroid_present     (both kinds) waydroid AND archmage-waydroid-config
#                        are in the pacman local db and the one-command init
#                        is installed executable (/usr/bin/
#                        archmage-waydroid-init) — the APPS-01 machine face
#                        (03-02; the binder/session runtime face is verified
#                        live by test/waydroid/waydroid-verify.sh, tier
#                        qemu-kvm)
#   btrfs_layout         (qemu-x86_64 only) the rootfs is the 03-03 btrfs
#                        flat subvolume layout: all six subvolumes (@ @root
#                        @var @snapshots @srv @tmp) exist; the fstab root
#                        line is LABEL=archmage-root with NO subvol= token
#                        (default-subvol mount — the snapper rollback hard
#                        prerequisite, 03-RESEARCH Q3); the five satellite
#                        lines carry explicit subvol= tokens; /var carries
#                        the NoCOW flag (chattr +C, PITFALLS 6); the
#                        snap-pac hooks and archmage-rollback are in place.
#                        op6 kind records not-applicable (ext4 rootfs; the
#                        btrfs migration is device-deferred).
#   repo_channels_present (both kinds) the factory pacman.conf declares the
#                        03-03 two-channel model: an ACTIVE [archmage-testing]
#                        section at SigLevel Required, a COMMENTED
#                        [archmage-stable] block (SigLevel Required + the
#                        stable.conf Include — stable is human-signed only,
#                        docs/REPO-CHANNELS.md), and the channel Include
#                        files under /etc/pacman.d/archmage/channels/.
#
# Usage:
#   tools/checks/verify-image.sh --image-kind op6 \
#       --boot-img PATH --rootfs-img PATH [--skip-mount] [--out FILE]
#   tools/checks/verify-image.sh --image-kind qemu-x86_64 \
#       --rootfs-img PATH [--skip-mount] [--out FILE]
#
# --skip-mount: local smoke mode — the Android boot magic check (op6) and
#   argument validation only, no root, no losetup, no mounting, no size
#   floors (--rootfs-img may be omitted for op6; synthetic tiny files are
#   accepted on purpose for two-way magic testing). The full mode (size
#   floors + loop-mount assertion set) runs in CI as root.
#
# Dependencies: full mode needs bash, losetup, findmnt, mount, jq (the
#   discipline detector requires jq); --skip-mount needs only bash+coreutils.
#   Exit status: 0 iff every applicable assertion passed.

set -euo pipefail

usage() {
    cat <<'EOF'
verify-image.sh — structural verification gate for ArchMage images

Usage:
  tools/checks/verify-image.sh --image-kind op6 --boot-img PATH
                               [--rootfs-img PATH] [--skip-mount] [--out FILE]
  tools/checks/verify-image.sh --image-kind qemu-x86_64 --rootfs-img PATH
                               [--skip-mount] [--out FILE]

Full-mode mounted-rootfs assertions (both kinds): android_boot_magic (op6
only), image_sized, shipping_discipline, phosh_present,
archmage_cn_in_image, archmage_repo_live, apn_presets_present,
ime_osk_present (03-01), waydroid_present (03-02),
repo_channels_present (03-03); btrfs_layout is qemu-x86_64-only (op6
records not-applicable — device-side btrfs migration deferred).

Options:
  --image-kind KIND   op6 | qemu-x86_64.
  --boot-img PATH     op6 only: Android boot image (must start with
                      the "ANDROID!" boot magic).
  --rootfs-img PATH   Root filesystem image (op6: ext4, bare or partitioned;
                      qemu-x86_64: GPT disk — p1 ESP + p2 btrfs flat
                      subvolume layout, 03-03). Required unless --skip-mount.
  --skip-mount        Magic check + argument validation only — no root, no
                      loop mounts, no size floors (local two-way smoke;
                      CI runs the full mode as root).
  --out FILE          Also write the assertion report here (JSON, schema
                      of discipline.json; default: no file).
  -h, --help          Show this help.

Exit status: 0 iff every applicable assertion passed.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

KIND=""
BOOT_IMG=""
ROOTFS_IMG=""
SKIP_MOUNT=no
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image-kind)
            [ $# -ge 2 ] || die "--image-kind needs op6|qemu-x86_64"
            KIND=$2
            shift
            ;;
        --boot-img)
            [ $# -ge 2 ] || die "--boot-img needs a PATH argument"
            BOOT_IMG=$2
            shift
            ;;
        --rootfs-img)
            [ $# -ge 2 ] || die "--rootfs-img needs a PATH argument"
            ROOTFS_IMG=$2
            shift
            ;;
        --skip-mount)
            SKIP_MOUNT=yes
            ;;
        --out)
            [ $# -ge 2 ] || die "--out needs a FILE argument"
            OUT=$2
            shift
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

case "$KIND" in
    op6|qemu-x86_64) ;;
    *) usage >&2; die "--image-kind is required (op6|qemu-x86_64)" ;;
esac
[ -n "$ROOTFS_IMG" ] || [ "$SKIP_MOUNT" = yes ] || \
    die "--rootfs-img is required (only --skip-mount may omit it)"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DISCIPLINE=$SCRIPT_DIR/assert-shipping-discipline.sh
[ -f "$DISCIPLINE" ] || die "cannot find assert-shipping-discipline.sh next to this script"

# Size floors (MiB): structural sanity only, deliberately conservative.
BOOT_MIN_MB=8
ROOTFS_MIN_MB=256

# --- assertion recording (same JSON style as result.sh) --------------------
command -v jq >/dev/null 2>&1 || die "required tool 'jq' not found in PATH"
ASSERT_FILE=$(mktemp "${TMPDIR:-/tmp}/archmage-verify-image.XXXXXX")
trap 'rm -f "$ASSERT_FILE"' EXIT
FAILS=0

record() {
    # record <name> <pass|fail> <details>
    local name="$1" status="$2" details="$3"
    details=${details//$'\n'/ }
    details=${details//$'\t'/ }
    if [ "$status" = fail ]; then FAILS=$((FAILS + 1)); fi
    jq -n --arg name "$name" --arg status "$status" --arg details "$details" \
        '{name: $name, status: $status, details: $details, informational: false}' \
        >> "$ASSERT_FILE"
    printf '  [%s] %s — %s\n' "$status" "$name" "$details" >&2
}

size_mib() {
    local bytes
    bytes=$(stat -c '%s' "$1" 2>/dev/null) || return 1
    echo $((bytes / 1048576))
}

# --- 1) Android boot magic (op6 only) --------------------------------------
if [ "$KIND" = op6 ]; then
    [ -n "$BOOT_IMG" ] || die "--boot-img is required for --image-kind op6"
    [ -s "$BOOT_IMG" ] || die "boot image '$BOOT_IMG' does not exist or is empty"
    magic=$(head -c 8 -- "$BOOT_IMG")
    if [ "$magic" = "ANDROID!" ]; then
        record android_boot_magic pass "first 8 bytes of $(basename "$BOOT_IMG") are the Android boot magic"
    else
        record android_boot_magic fail "boot magic mismatch: expected 'ANDROID!', got '${magic:-<none>}'"
    fi
    # Size floors only in full mode: the --skip-mount local smoke is fed
    # tiny synthetic files on purpose (positive/negative magic cases).
    if [ "$SKIP_MOUNT" = no ]; then
        sz=$(size_mib "$BOOT_IMG") || sz=0
        if [ "$sz" -ge "$BOOT_MIN_MB" ]; then
            record boot_image_sized pass "boot image is ${sz} MiB (floor ${BOOT_MIN_MB} MiB)"
        else
            record boot_image_sized fail "boot image is only ${sz} MiB (< ${BOOT_MIN_MB} MiB floor)"
        fi
    fi
fi

# --- 2) rootfs size (full mode; --skip-mount accepts synthetic stubs) ------
if [ -n "$ROOTFS_IMG" ] && [ "$SKIP_MOUNT" = no ]; then
    [ -s "$ROOTFS_IMG" ] || die "rootfs image '$ROOTFS_IMG' does not exist or is empty"
    sz=$(size_mib "$ROOTFS_IMG") || sz=0
    if [ "$sz" -ge "$ROOTFS_MIN_MB" ]; then
        record image_sized pass "rootfs image is ${sz} MiB (floor ${ROOTFS_MIN_MB} MiB)"
    else
        record image_sized fail "rootfs image is only ${sz} MiB (< ${ROOTFS_MIN_MB} MiB floor)"
    fi
fi

# --- 3) skip-mount short-circuit --------------------------------------------
if [ "$SKIP_MOUNT" = yes ]; then
    printf 'verify-image (--skip-mount): %d gating failure(s)\n' "$FAILS" >&2
    [ "$FAILS" -eq 0 ] || exit 1
    exit 0
fi

# --- full mode: mount the rootfs image --------------------------------------
for c in losetup findmnt mount umount; do
    command -v "$c" >/dev/null 2>&1 || die "required tool '$c' not found in PATH (full mode needs root + util-linux)"
done
# btrfs_layout needs btrfs-progs (subvolume list) + e2fsprogs (lsattr);
# only relevant where the assertion applies.
if [ "$KIND" = qemu-x86_64 ]; then
    for c in btrfs lsattr; do
        command -v "$c" >/dev/null 2>&1 || die "required tool '$c' not found in PATH (btrfs_layout assertion needs btrfs-progs + e2fsprogs)"
    done
fi
[ "$(id -u)" -eq 0 ] || die "full mode must run as root (losetup/mount); use --skip-mount for a local structural smoke"

LOOP=""
MNT=$(mktemp -d "${TMPDIR:-/tmp}/archmage-verify-rootfs.XXXXXX")
MOUNTED=no
cleanup() {
    trap - EXIT INT TERM
    if [ "$MOUNTED" = yes ]; then
        umount "$MNT/var" 2>/dev/null || true
        umount "$MNT" 2>/dev/null || true
    fi
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || true
    fi
    rm -rf "$MNT"
}
trap cleanup EXIT INT TERM

# Attach with retries: losetup -f can pick a free loop INDEX whose /dev
# node is missing entirely (shared host /dev with holes — observed live:
# "device node /dev/loopN (7:N) is lost"), which fails the attach outright.
# Recreate the standard loop nodes + loop-control between attempts.
LOOP=""
for _ in 1 2 3 4 5; do
    if LOOP=$(losetup -Pf --show "$ROOTFS_IMG"); then
        break
    fi
    LOOP=""
    [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237 2>/dev/null || true
    for i in $(seq 0 23); do
        [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
    done
    sleep 1
done
[ -n "$LOOP" ] || die "losetup -Pf failed for '$ROOTFS_IMG'"

# The loop<p>N partition NODES are created by udev asynchronously (shared
# host /dev, e.g. inside a --privileged container) and on some hosts never
# appear at all — the KERNEL registers the partitions either way
# (/proc/partitions). Same race mkrootfs-x86_64.sh's attach_bare works
# around (observed live: the 03-03 GPT rootfs.img exposed only the bare
# loop node, "candidates: /dev/loopN", no mount attempted). Wait briefly,
# then create the missing partition nodes from /proc/partitions data
# (majors/minors are dynamic — major 259 on modern kernels).
if ! [ -e "${LOOP}p1" ] || ! [ -e "${LOOP}p2" ]; then
    for _ in $(seq 1 5); do
        [ -e "${LOOP}p1" ] && [ -e "${LOOP}p2" ] && break
        sleep 1
    done
fi
if [ -r /proc/partitions ]; then
    loop_name=$(basename "$LOOP")
    # /proc/partitions rows: <major> <minor> <blocks> <name>
    while read -r pmaj pmin _ pname; do
        case "$pname" in
            "$loop_name"p[0-9]*) ;;
            *) continue ;;
        esac
        [ -e "/dev/$pname" ] || mknod "/dev/$pname" b "$pmaj" "$pmin" 2>/dev/null || true
    done < /proc/partitions
fi

# Mount the first candidate that IS a rootfs (bare ext4 -> the loop device
# itself; partitioned image -> one of its partitions). /etc/pacman.conf is
# the rootfs detector.
# NOTE: the partition glob must not run as a bare `ls ${LOOP}p*` pipeline:
# on a partitionless image the glob fails, and under this script's `set -e`
# the process-substitution subshell dies before the bare-loop fallback line
# is printed — candidates ends up EMPTY and no mount is ever attempted
# (reproduced on the qemu-x86_64 bare ext4 image). Iterate the glob safely
# instead.
mapfile -t candidates < <(
    for p in "${LOOP}"p*; do
        [ -e "$p" ] && printf '%s\n' "$p"
    done
    printf '%s\n' "$LOOP"
)
for cand in "${candidates[@]}"; do
    [ -b "$cand" ] || continue
    if mount -o ro "$cand" "$MNT" 2>/dev/null && [ -f "$MNT/etc/pacman.conf" ]; then
        MOUNTED=yes
        break
    fi
    if [ "$MOUNTED" = yes ]; then break; fi
    umount "$MNT" 2>/dev/null || true
    MOUNTED=no
done
if [ "$MOUNTED" != yes ]; then
    record rootfs_mountable fail "no mountable rootfs found in '$ROOTFS_IMG' (loop $LOOP, candidates: ${candidates[*]})"
    printf 'verify-image: %d gating failure(s)\n' "$FAILS" >&2
    exit 1
fi
record rootfs_mountable pass "rootfs mounted read-only from $(basename "$ROOTFS_IMG") (${cand})"

# btrfs flat layout: /var is the separate @var subvolume (fstab mounts it at
# boot; the bare default-subvol mount sees @'s EMPTY /var mountpoint dir).
# Mirror the boot layout so the /var-reading assertions (pacman local db for
# archmage_cn_in_image, discipline checks) see the real content. op6 (ext4)
# keeps its single rootfs — nothing to overlay.
if [ "$KIND" = qemu-x86_64 ] && [ "$(findmnt -n -o FSTYPE "$MNT")" = btrfs ]; then
    if ! mount -o subvol=@var,ro "$cand" "$MNT/var" 2>/dev/null; then
        record rootfs_mountable fail "@var subvolume failed to overlay onto the mounted rootfs /var"
        printf 'verify-image: %d gating failure(s)\n' "$FAILS" >&2
        exit 1
    fi
fi

# (a) shipping discipline on the real image (QUAL-01).
# OUT is optional (report JSON off): without it, park the discipline report
# in a temp file — an empty OUT would make DISC_OUT "-discipline.json" and
# the detector's dirname/basename calls explode (observed live).
if [ -n "$OUT" ]; then
    DISC_OUT=${OUT%.json}-discipline.json
else
    DISC_OUT=$(mktemp -u "${TMPDIR:-/tmp}/archmage-verify-disc.XXXXXX.json")
fi
if bash "$DISCIPLINE" --rootfs-dir "$MNT" --out "$DISC_OUT"; then
    record shipping_discipline pass "assert-shipping-discipline green on the mounted rootfs (report: $(basename "$DISC_OUT"))"
else
    record shipping_discipline fail "assert-shipping-discipline FAILED on the mounted rootfs (report: $(basename "$DISC_OUT"))"
fi

# (b) phosh + archmage-cn really made it into the image.
#     phosh >= 0.57 ships the compositor as /usr/lib/phosh/phosh (plus
#     usr/bin/phosh-session); older releases used /usr/bin/phosh — accept
#     both so the gate tracks the current Arch extra package layout.
if [ -e "$MNT/usr/lib/phosh/phosh" ] || [ -e "$MNT/usr/bin/phosh" ]; then
    record phosh_present pass "/usr/lib/phosh/phosh (or legacy /usr/bin/phosh) exists in the image"
else
    record phosh_present fail "neither /usr/lib/phosh/phosh nor /usr/bin/phosh found in the image"
fi
cn_dirs=("$MNT"/var/lib/pacman/local/archmage-cn-*/)
if [ -d "${cn_dirs[0]}" ]; then
    record archmage_cn_in_image pass "pacman local db has $(basename "${cn_dirs[0]}")"
else
    record archmage_cn_in_image fail "pacman local db has no archmage-cn entry (CN defaults never installed?)"
fi

# (c) ArchMage repo channel declared with a live Server in the image's
#     effective pacman config (existence only; SigLevel policy is the
#     detector's job). 03-03 two-channel: matches the `archmage` PREFIX —
#     [archmage-testing] (active staging channel) and [archmage-stable]
#     (human-signed stable channel) are both judged on Server presence.
conf_files=("$MNT/etc/pacman.conf")
while IFS= read -r f; do
    conf_files+=("$f")
done < <(find "$MNT/etc/pacman.d" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort || true)
archmage_servers=$(
    awk '
        function flush() { if (sec ~ /^archmage/ && haveserver) print servercount }
        FNR == 1 { flush(); sec = ""; haveserver = 0; servercount = 0 }
        /^[ \t]*#/ { next }
        match($0, /^[ \t]*\[[^]]+\][ \t]*$/) {
            sec = $0
            gsub(/^[ \t]*\[|\][ \t]*$/, "", sec)
            next
        }
        sec ~ /^archmage/ && tolower($0) ~ /^[ \t]*server[ \t]*=/ {
            haveserver = 1
            servercount++
        }
        END { flush() }
    ' "${conf_files[@]}" || true
)
# Multiple config files could each declare a section; count all Server lines.
archmage_servers=$(printf '%s\n' "$archmage_servers" | awk '{s += $1} END {print s + 0}')
if [ "${archmage_servers:-0}" -ge 1 ]; then
    record archmage_repo_live pass "an [archmage*] channel section declares ${archmage_servers} Server line(s) in the image pacman config"
else
    record archmage_repo_live fail "no [archmage-testing]/[archmage-stable] section with a Server line in the image pacman config"
fi

# (d) CN carrier APN presets really made it into the image (02-03).
NM_CONNS=$MNT/usr/lib/NetworkManager/system-connections
apn_missing=""
for apn in cmnet 3gnet ctnet; do
    [ -f "$NM_CONNS/archmage-apn-$apn.nmconnection" ] || \
        apn_missing="${apn_missing:+$apn_missing; }archmage-apn-$apn.nmconnection"
done
if [ -z "$apn_missing" ]; then
    record apn_presets_present pass "all three CN APN profiles present in /usr/lib/NetworkManager/system-connections/"
else
    record apn_presets_present fail "APN preset file(s) missing from the image rootfs: $apn_missing"
fi

# (e) IME system keyboard made it into the image (03-01, IME-01; both
#     kinds — the OP6 profile carries the package in pkgs_include too):
#     - the pacman local db contains archmage-fcitx5-osk;
#     - the OSK0 contract five files are in place (desktop / user unit /
#       shim / environment.d defaults / fcitx5 profile);
#     - squeekboard is ABSENT from the local db (structural evidence of the
#       full-replacement decision — Conflicts means both can never be
#       installed, so its absence proves the replacement transaction ran).
# 2026-10-04 OSK scheme decision (STRATEGY §5.2): stevia is the keyboard UI
# (the fcitx5-osk shim lost the structural im-v2 slot experiment; the fcitx5
# ENGINE + chinese-addons stay as the P1 custom-keyboard backend). Contract:
#     - stevia in the pacman local db; archmage-fcitx5-osk ABSENT;
#     - stevia's own OSK0 desktop + user unit in place;
#     - greetd + seatd enabled (interactive desktop stack);
#     - squeekboard still absent.
OSK_DB_DIR=$MNT/var/lib/pacman/local
osk_db=no
for d in "$OSK_DB_DIR"/stevia-*/; do
    if [ -d "$d" ]; then osk_db=yes; break; fi
done
osk_old=yes
ls -d "$OSK_DB_DIR"/archmage-fcitx5-osk-* >/dev/null 2>&1 && osk_old=present
osk_missing=""
[ -f "$MNT/usr/share/applications/sm.puri.OSK0.desktop" ] || osk_missing="${osk_missing:+$osk_missing; }sm.puri.OSK0.desktop"
[ -f "$MNT/usr/lib/systemd/user/mobi.phosh.OSK.service" ] || osk_missing="${osk_missing:+$osk_missing; }mobi.phosh.OSK.service"
greetd_enabled=no
[ -e "$MNT/etc/systemd/system/display-manager.service" ] && greetd_enabled=yes
seatd_enabled=no
ls -d "$MNT/etc/systemd/system/multi-user.target.wants/seatd.service" >/dev/null 2>&1 && seatd_enabled=yes
squeekboard_absent=yes
ls -d "$OSK_DB_DIR"/squeekboard-* >/dev/null 2>&1 && squeekboard_absent=no
if [ "$osk_db" = yes ] && [ "$osk_old" = absent ] && [ -z "$osk_missing" ] \
   && [ "$greetd_enabled" = yes ] && [ "$seatd_enabled" = yes ] && [ "$squeekboard_absent" = yes ]; then
    record ime_osk_present pass "stevia OSK in local db (fcitx5-osk removed); greetd auto-login + seatd enabled; squeekboard absent"
else
    record ime_osk_present fail "OSK contract (stevia era) broken: stevia in db=$osk_db, fcitx5-osk still=$osk_old, missing=[$osk_missing], greetd=$greetd_enabled, seatd=$seatd_enabled, squeekboard absent=$squeekboard_absent"
fi

# (f) Waydroid factory layer made it into the image (03-02, APPS-01 machine
#     face; both kinds — the OP6 profile carries both packages in
#     pkgs_include too): waydroid itself AND archmage-waydroid-config in the
#     local db, plus the one-command init in place with its executable bit.
#     This is the structural half only — the runtime face (binder ->
#     waydroid init -> session RUNNING) is verified live under KVM by
#     test/waydroid/waydroid-verify.sh (tier qemu-kvm; QEMU green != device
#     green, PITFALLS 4).
WD_DB_DIR=$MNT/var/lib/pacman/local
wd_db=no
for d in "$WD_DB_DIR"/waydroid-*/; do
    # waydroid's own local-db entry (waydroid-<ver>-<rel>; the glob also
    # matches archmage-waydroid-config-* — exclude by basename prefix).
    base=$(basename "$d")
    case "$base" in
        waydroid-*) wd_db=yes; break ;;
    esac
done
wdc_db=no
ls -d "$WD_DB_DIR"/archmage-waydroid-config-*/ >/dev/null 2>&1 && wdc_db=yes
wd_init=no
[ -x "$MNT/usr/bin/archmage-waydroid-init" ] && wd_init=yes
if [ "$wd_db" = yes ] && [ "$wdc_db" = yes ] && [ "$wd_init" = yes ]; then
    record waydroid_present pass "waydroid + archmage-waydroid-config in local db; /usr/bin/archmage-waydroid-init executable in place (APPS-01 structural face)"
else
    record waydroid_present fail "waydroid factory layer broken: waydroid in db=$wd_db, archmage-waydroid-config in db=$wdc_db, init executable=$wd_init"
fi

# (g) btrfs flat subvolume layout (03-03, UPDATE-01 machine face; qemu-x86_64
#     only — the op6 rootfs is ext4 until the device-side btrfs migration).
if [ "$KIND" != qemu-x86_64 ]; then
    record btrfs_layout pass "not-applicable: op6 rootfs is ext4 (device-side btrfs migration deferred; asserted on the qemu-x86_64 image)"
else
    # The mount above resolved candidates in order and landed on the btrfs
    # p2 with the DEFAULT subvolume (no subvol= mount option) — exactly the
    # rollback-relevant view of the filesystem.
    is_btrfs=$(findmnt -n -o FSTYPE "$MNT" 2>/dev/null || true)
    subvols=$(btrfs subvolume list "$MNT" 2>/dev/null | awk '{print $NF}' | sort || true)
    subvol_ok=yes
    for sv in @ @root @var @snapshots @srv @tmp; do
        printf '%s\n' "$subvols" | grep -qx "$sv" || subvol_ok=no
    done
    # fstab parsing (awk on FIELDS, not grep on raw text — a header comment
    # mentioning subvol= must not self-certify): root line = LABEL=archmage-root
    # with NO subvol= token; the five satellite lines each carry an explicit
    # subvol= matching their mountpoint.
    fstab_report=$(awk '
        $1 ~ /^#/ { next }
        NF >= 4 && $3 == "btrfs" {
            if ($2 == "/") {
                root_dev = $1; root_opts = $4
            } else if ($2 == "/root" || $2 == "/var" || $2 == "/.snapshots" || $2 == "/srv" || $2 == "/tmp") {
                # Mountpoint -> subvolume name: they differ for /.snapshots
                # (@snapshots lives at the dot-dir; pmbootstrap !2233 names).
                mp = $2
                if (mp == "/.snapshots") sv = "@snapshots"
                else { sub("/", "", mp); sv = "@" mp }
                if ($4 !~ ("subvol=" sv "([,]|$)")) sat_missing = sat_missing (sat_missing == "" ? "" : " ") $2
                else sat_seen = sat_seen " " $2
            }
        }
        END {
            printf "root_dev=%s;root_subvol_token=%s;sat_missing=%s;sat_seen=%s",
                root_dev, (root_opts ~ /subvol=/ ? "yes" : "no"), sat_missing, sat_seen
        }
    ' "$MNT/etc/fstab" 2>/dev/null || true)
    root_dev=$(printf '%s' "$fstab_report" | sed -n 's/.*root_dev=\([^;]*\).*/\1/p')
    root_has_subvol=$(printf '%s' "$fstab_report" | sed -n 's/.*root_subvol_token=\([^;]*\).*/\1/p')
    sat_missing=$(printf '%s' "$fstab_report" | sed -n 's/.*sat_missing=\([^;]*\);sat_seen=.*/\1/p')
    # NoCOW flag: it lives on the @var SUBVOLUME ROOT (chattr +C at creation;
    # files created inside inherit it). From the default-subvol mount above,
    # $MNT/var is @'s own empty mountpoint directory — a plain dir WITHOUT
    # the flag (observed live) — so the subvolume is mounted ro at its own
    # path and the flag is read from the subvolume root directory.
    nocow=no
    if VAR_MNT=$(mktemp -d "${TMPDIR:-/tmp}/archmage-verify-var.XXXXXX"); then
        if mount -o subvol=@var,ro "$cand" "$VAR_MNT" 2>/dev/null; then
            lsattr -d "$VAR_MNT" 2>/dev/null | awk '{print $1}' | grep -q 'C' && nocow=yes
            umount "$VAR_MNT" 2>/dev/null || true
        fi
        rmdir "$VAR_MNT" 2>/dev/null || true
    fi
    mach_files=yes
    [ -e "$MNT/usr/bin/archmage-rollback" ] || mach_files=no
    [ -e "$MNT/usr/bin/archmage-bootimg-store" ] || mach_files=no
    [ -e "$MNT/usr/share/libalpm/hooks/90-archmage-bootimg-store.hook" ] || mach_files=no
    # snap-pac names its hooks with numeric prefixes (05-snap-pac-pre.hook /
    # zz-snap-pac-post.hook in snap-pac 3.0.1) — glob so the gate tracks the
    # hook by role, not by the current package's naming whim.
    ls "$MNT"/usr/share/libalpm/hooks/*snap-pac-pre.hook >/dev/null 2>&1 || mach_files=no
    [ -e "$MNT/usr/share/archmage/btrfs-rollback/snapper-root.conf" ] || mach_files=no

    if [ "$is_btrfs" = btrfs ] && [ "$subvol_ok" = yes ] && \
        [ "$root_dev" = "LABEL=archmage-root" ] && [ "$root_has_subvol" = no ] && \
        [ -z "$sat_missing" ] && [ "$nocow" = yes ] && [ "$mach_files" = yes ]; then
        record btrfs_layout pass "btrfs flat layout: 6 subvolumes present; fstab root LABEL=archmage-root without subvol= token (default-subvol mount); satellites carry subvol=; /var is NoCOW; rollback machinery files in place (satellites seen:${sat_seen:-<none>})"
    else
        record btrfs_layout fail "btrfs layout broken: fstype=${is_btrfs:-<none>}, six-subvolume check=$subvol_ok, root_dev=${root_dev:-<none>}, root subvol token=$root_has_subvol, missing satellite mounts=[$sat_missing], /var NoCOW=$nocow, machinery files=$mach_files"
    fi
fi

# (h) two-channel repo client config (03-03, UPDATE-03 machine face; both
#     kinds — every factory image ships the same channel declaration):
#     - /etc/pacman.conf carries an ACTIVE [archmage-testing] section whose
#       SigLevel is Required;
#     - a COMMENTED [archmage-stable] block (stable is human-signed only,
#       never CI — docs/REPO-CHANNELS.md) carrying its own SigLevel Required
#       and the stable.conf Include;
#     - the channel Include files /etc/pacman.d/archmage/channels/{testing,
#       stable}.conf are in place (stable.conf ships with an EMPTY server
#       list by design).
PAC_CONF=$MNT/etc/pacman.conf
CHAN_DIR=$MNT/etc/pacman.d/archmage/channels
chan_report=$(awk '
    /^\[archmage-testing\]/ { in_testing = 1; seen = 1; next }
    /^\[/                   { in_testing = 0; next }
    in_testing && /^[ \t]*SigLevel[ \t]*=/ {
        sig = $0
        sub(/^[ \t]*SigLevel[ \t]*=[ \t]*/, "", sig)
    }
    END { printf "seen=%d;sig=%s", seen, sig }
' "$PAC_CONF" 2>/dev/null || true)
testing_seen=$(printf '%s' "$chan_report" | sed -n 's/.*seen=\([01]\).*/\1/p')
testing_sig=$(printf '%s' "$chan_report" | sed -n 's/.*sig=\(.*\)$/\1/p')
# The commented stable block runs from its section marker to EOF (both config
# generators append it last); its SigLevel/Include lines are checked INSIDE
# the block so an unrelated commented SigLevel elsewhere cannot self-certify.
stable_block=$(sed -n '/^#\[archmage-stable\]/,$p' "$PAC_CONF" 2>/dev/null || true)
stable_commented=no
stable_required=no
stable_include=no
printf '%s\n' "$stable_block" | grep -q '^#\[archmage-stable\]' && stable_commented=yes
printf '%s\n' "$stable_block" | grep -Eq '^#SigLevel[ \t]*=[ \t]*Required' && stable_required=yes
printf '%s\n' "$stable_block" | grep -Eq '^#Include[ \t]*=[ \t]*/etc/pacman\.d/archmage/channels/stable\.conf' && stable_include=yes
chan_files=yes
[ -f "$CHAN_DIR/testing.conf" ] || chan_files=no
[ -f "$CHAN_DIR/stable.conf" ] || chan_files=no
case "$testing_sig" in
    Required) testing_required=yes ;;
    *) testing_required=no ;;
esac
if [ "$testing_seen" = 1 ] && [ "$testing_required" = yes ] && \
    [ "$stable_commented" = yes ] && [ "$stable_required" = yes ] && \
    [ "$stable_include" = yes ] && [ "$chan_files" = yes ]; then
    record repo_channels_present pass "two-channel factory config: [archmage-testing] active at SigLevel Required; [archmage-stable] shipped commented (Required + stable.conf Include); channel Include files in place"
else
    record repo_channels_present fail "two-channel factory config broken: testing section seen=$testing_seen (sig='${testing_sig:-<none>}'), stable commented=$stable_commented, stable SigLevel Required=$stable_required, stable Include=$stable_include, channel files=$chan_files"
fi

# --- verdict ----------------------------------------------------------------
status=pass
[ "$FAILS" -eq 0 ] || status=fail
printf 'verify-image (%s): status=%s (%d gating failure(s))\n' "$KIND" "$status" "$FAILS" >&2

if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    jq -n \
        --arg check "verify-image" \
        --arg kind "$KIND" \
        --arg target "$ROOTFS_IMG" \
        --arg tier "static" \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --slurpfile assertions "$ASSERT_FILE" \
        --arg status "$status" \
        '{schema_version: 1,
          check: $check,
          kind: $kind,
          target: $target,
          tier: $tier,
          generated_at: $generated_at,
          assertions: $assertions,
          status: $status}' \
        > "$OUT"
    printf 'report: %s\n' "$OUT" >&2
fi

[ "$status" = pass ] || exit 1
exit 0
