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
archmage_cn_in_image, archmage_repo_live, apn_presets_present.

Options:
  --image-kind KIND   op6 | qemu-x86_64.
  --boot-img PATH     op6 only: Android boot image (must start with
                      the "ANDROID!" boot magic).
  --rootfs-img PATH   Root filesystem image (ext4; bare or partitioned).
                      Required unless --skip-mount.
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
[ "$(id -u)" -eq 0 ] || die "full mode must run as root (losetup/mount); use --skip-mount for a local structural smoke"

LOOP=""
MNT=$(mktemp -d "${TMPDIR:-/tmp}/archmage-verify-rootfs.XXXXXX")
MOUNTED=no
cleanup() {
    trap - EXIT INT TERM
    if [ "$MOUNTED" = yes ]; then
        umount "$MNT" 2>/dev/null || true
    fi
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || true
    fi
    rm -rf "$MNT"
}
trap cleanup EXIT INT TERM

LOOP=$(losetup -Pf --show "$ROOTFS_IMG") || die "losetup -Pf failed for '$ROOTFS_IMG'"

# Mount the first candidate that IS a rootfs (bare ext4 -> the loop device
# itself; partitioned image -> one of its partitions). /etc/pacman.conf is
# the rootfs detector.
mapfile -t candidates < <(
    ls -1 "${LOOP}"p* 2>/dev/null | sort -V
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

# (a) shipping discipline on the real image (QUAL-01).
DISC_OUT=${OUT%.json}-discipline.json
if bash "$DISCIPLINE" --rootfs-dir "$MNT" --out "$DISC_OUT"; then
    record shipping_discipline pass "assert-shipping-discipline green on the mounted rootfs (report: $(basename "$DISC_OUT"))"
else
    record shipping_discipline fail "assert-shipping-discipline FAILED on the mounted rootfs (report: $(basename "$DISC_OUT"))"
fi

# (b) phosh + archmage-cn really made it into the image.
if [ -e "$MNT/usr/bin/phosh" ]; then
    record phosh_present pass "/usr/bin/phosh exists in the image"
else
    record phosh_present fail "/usr/bin/phosh missing from the image"
fi
cn_dirs=("$MNT"/var/lib/pacman/local/archmage-cn-*/)
if [ -d "${cn_dirs[0]}" ]; then
    record archmage_cn_in_image pass "pacman local db has $(basename "${cn_dirs[0]}")"
else
    record archmage_cn_in_image fail "pacman local db has no archmage-cn entry (CN defaults never installed?)"
fi

# (c) [archmage] repo declared with a live Server in the image's effective
#     pacman config (existence only; SigLevel policy is the detector's job).
conf_files=("$MNT/etc/pacman.conf")
while IFS= read -r f; do
    conf_files+=("$f")
done < <(find "$MNT/etc/pacman.d" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort || true)
archmage_servers=$(
    awk '
        function flush() { if (sec == "archmage" && haveserver) print servercount }
        FNR == 1 { flush(); sec = ""; haveserver = 0; servercount = 0 }
        /^[ \t]*#/ { next }
        match($0, /^[ \t]*\[[^]]+\][ \t]*$/) {
            sec = $0
            gsub(/^[ \t]*\[|\][ \t]*$/, "", sec)
            next
        }
        sec == "archmage" && tolower($0) ~ /^[ \t]*server[ \t]*=/ {
            haveserver = 1
            servercount++
        }
        END { flush() }
    ' "${conf_files[@]}" || true
)
# Multiple config files could each declare a section; count all Server lines.
archmage_servers=$(printf '%s\n' "$archmage_servers" | awk '{s += $1} END {print s + 0}')
if [ "${archmage_servers:-0}" -ge 1 ]; then
    record archmage_repo_live pass "[archmage] section declares ${archmage_servers} Server line(s) in the image pacman config"
else
    record archmage_repo_live fail "no [archmage] section with a Server line in the image pacman config"
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
