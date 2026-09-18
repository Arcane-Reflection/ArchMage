#!/usr/bin/env bash
# device-tier.sh — validate on-device checklist results and promote the
# image manifest tier (02-03 Task 3; PITFALLS 4: QEMU green != device
# green, so the device-verified label can only ever come from the human
# checklist, machine-checked here).
#
# Usage:
#   tools/checks/device-tier.sh --results <op6-results.json> [--manifest <manifest.json>]
#   tools/checks/device-tier.sh --probe
#
# Validation (--results): schema_version == 1; the six fixed check ids all
# present exactly once (boot-phosh, sms-mo, sms-mt, mobile-data,
# call-status, emergency-lockscreen); every status in pass|fail|na;
# serial / image.name / image.sha256 / performed_by / date non-empty.
#
# Promotion (--manifest, only after validation passed): boot-phosh == pass
# rewrites the manifest tier device-pending -> device-verified in place
# (jq), attaching verified_by (from results.performed_by), verified_at
# (UTC now) and checks_summary (per-id statuses + counts). boot-phosh not
# pass refuses the promotion.
#
# Exit codes:
#   0   results valid (and promotion applied when --manifest was given)
#   1   invalid results (missing ids / bad status / empty fields), bad or
#       non-promotable manifest, or usage error
#   2   promotion refused: boot-phosh is not pass
#   33  --probe found no device: tool binaries missing and no attached
#       device are the same condition, and DEVICE_REQUIRED is the FIRST
#       stderr line (the 02-02 device-deferred convention — a missing
#       fastboot/adb must not leak as 127 or a crash)

set -euo pipefail

usage() {
    cat <<'EOF'
device-tier.sh — validate on-device results, promote manifest tier

Usage:
  tools/checks/device-tier.sh --results <op6-results.json> [--manifest <manifest.json>]
  tools/checks/device-tier.sh --probe

Options:
  --results PATH   Checklist results JSON (schema of
                   test/on-device/op6-results-template.json). Validated;
                   with --manifest, drives the tier promotion.
  --manifest PATH  Image manifest.json (nightly Release asset). When the
                   results are valid and boot-phosh == pass, its tier is
                   rewritten device-pending -> device-verified in place
                   (verified_by / verified_at / checks_summary attached).
  --probe          Check whether a device is visible via fastboot or adb.
  -h, --help       Show this help.

Exit status: 0 valid/promoted; 1 invalid results or manifest; 2 promotion
refused (boot-phosh not pass); 33 no device (--probe, DEVICE_REQUIRED on
stderr).
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

RESULTS=""
MANIFEST=""
PROBE=no
while [ $# -gt 0 ]; do
    case "$1" in
        --results)
            [ $# -ge 2 ] || die "--results needs a PATH argument"
            RESULTS=$2
            shift
            ;;
        --manifest)
            [ $# -ge 2 ] || die "--manifest needs a PATH argument"
            MANIFEST=$2
            shift
            ;;
        --probe)
            PROBE=yes
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

command -v jq >/dev/null 2>&1 || die "required tool 'jq' not found in PATH"

# --- --probe: is a device attached? (33/DEVICE_REQUIRED convention) --------
if [ "$PROBE" = yes ]; then
    [ -n "$RESULTS" ] || [ -z "$MANIFEST" ] || die "--probe takes no other arguments"
    found=""
    if command -v fastboot >/dev/null 2>&1; then
        found=$(fastboot devices 2>/dev/null | grep -m1 '.' || true)
        if [ -n "$found" ]; then
            printf 'fastboot 设备在场:%s\n' "$found"
            exit 0
        fi
    fi
    if command -v adb >/dev/null 2>&1; then
        found=$(adb devices 2>/dev/null | tail -n +2 | grep -m1 '.' || true)
        if [ -n "$found" ]; then
            printf 'adb 设备在场:%s\n' "$found"
            exit 0
        fi
    fi
    # Neither tool installed or nothing answered: identical condition.
    # DEVICE_REQUIRED must stay the FIRST stderr line of this path.
    printf 'DEVICE_REQUIRED: 宿主未发现真机(缺 android-tools 或无设备)——安装 android-tools(Arch: sudo pacman -S android-tools)并把 OP6 置于 fastboot/adb 模式后重跑\n' >&2
    exit 33
fi

[ -n "$RESULTS" ] || { usage >&2; die "--results is required (or use --probe)"; }
[ -f "$RESULTS" ] || die "results file '$RESULTS' does not exist"
jq -e . "$RESULTS" >/dev/null 2>&1 || die "results file '$RESULTS' is not valid JSON"

# --- validate the results JSON ---------------------------------------------
REQUIRED_IDS=(boot-phosh sms-mo sms-mt mobile-data call-status emergency-lockscreen)
ERRORS=()

chk() {
    # chk <jq-test> <error message>
    if jq -e "$1" "$RESULTS" >/dev/null 2>&1; then
        :
    else
        ERRORS+=("$2")
    fi
}

chk '.schema_version == 1' 'schema_version 必须为 1'
chk '(.serial | type == "string") and (.serial | length > 0)' 'serial 为空或缺失'
chk '(.image.name | type == "string") and (.image.name | length > 0)' 'image.name 为空或缺失'
chk '(.image.sha256 | type == "string") and (.image.sha256 | length > 0)' 'image.sha256 为空或缺失'
chk '(.performed_by | type == "string") and (.performed_by | length > 0)' 'performed_by 为空或缺失'
chk '(.date | type == "string") and (.date | length > 0)' 'date 为空或缺失'
chk '(.checks | type == "array")' 'checks 不是数组'

for id in "${REQUIRED_IDS[@]}"; do
    n=$(jq --arg id "$id" '[.checks[]? | select(.id == $id)] | length' "$RESULTS")
    if [ "${n:-0}" -ne 1 ]; then
        ERRORS+=("check id '$id' 出现 ${n:-0} 次(应恰为 1)")
    fi
done

bad_status=$(jq -r '
    [.checks[]?
     | select(((.status // "") == "pass" or (.status // "") == "fail" or (.status // "") == "na") | not)
     | .id] | join(",")' "$RESULTS")
if [ -n "$bad_status" ]; then
    ERRORS+=("非法 status 值(只允许 pass|fail|na):$bad_status")
fi

if [ "${#ERRORS[@]}" -gt 0 ]; then
    printf 'device-tier: 结果 JSON 不合格(%d 项):\n' "${#ERRORS[@]}" >&2
    for e in "${ERRORS[@]}"; do
        printf '  - %s\n' "$e" >&2
    done
    exit 1
fi
printf 'device-tier: results OK (%s)\n' "$RESULTS" >&2

# --- optional: promote the manifest tier ------------------------------------
if [ -z "$MANIFEST" ]; then
    exit 0
fi

[ -f "$MANIFEST" ] || die "manifest file '$MANIFEST' does not exist"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die "manifest file '$MANIFEST' is not valid JSON"

tier=$(jq -r '.tier // ""' "$MANIFEST")
case "$tier" in
    device-pending|device-verified) ;;
    *)
        printf 'ERROR: manifest tier 为 %s%s,不可晋升(仅 device-pending / device-verified)\n' \
            "'${tier}'" "" >&2
        exit 1
        ;;
esac

boot_status=$(jq -r '.checks[] | select(.id == "boot-phosh") | .status' "$RESULTS")
if [ "$boot_status" != "pass" ]; then
    printf 'ERROR: 拒绝晋升——boot-phosh = %s(DEVICE-03 未通过,manifest tier 保持 %s)\n' \
        "$boot_status" "$tier" >&2
    exit 2
fi

verified_by=$(jq -r '.performed_by' "$RESULTS")
verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
summary=$(jq -r '
    [(.checks[] | "\(.id):\(.status)")] | sort | join(";")' "$RESULTS")
counts=$(jq -r '
    [.checks[].status]
    | "pass=\(map(select(. == "pass")) | length) fail=\(map(select(. == "fail")) | length) na=\(map(select(. == "na")) | length)"' \
    "$RESULTS")

tmp_manifest=$MANIFEST.tmp
jq --arg vb "$verified_by" --arg va "$verified_at" --arg cs "$summary ($counts)" \
    '.tier = "device-verified"
     | .verified_by = $vb
     | .verified_at = $va
     | .checks_summary = $cs' \
    "$MANIFEST" > "$tmp_manifest"
mv "$tmp_manifest" "$MANIFEST"

printf 'device-tier: manifest %s → device-verified(verified_by=%s, %s)\n' \
    "$MANIFEST" "$verified_by" "$summary ($counts)" >&2
exit 0
