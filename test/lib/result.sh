# result.sh — structured smoke-result contract (SIM-03).
#
# Sourced by test/smoke-aarch64.sh AFTER lib/common.sh. Emits
# test/results/<ts>/smoke.json (assembled with jq) and maintains the
# test/results/latest symlink.
#
# JSON contract (schema_version 1):
# {
#   "schema_version": 1,
#   "target": "alarm-aarch64-rootfs",
#   "arch": "aarch64",
#   "accel": "kvm|tcg",
#   "tier": "qemu",                  # PITFALLS 4: QEMU green != device green;
#                                    # every artifact carries its tier label
#   "started_at": "2026-09-17T04:00:00Z",
#   "boot_seconds": 123,             # QEMU start -> SSH ready (null if never)
#   "assertions": [
#     {"name": "...", "status": "pass|fail", "details": "...",
#      "informational": false}
#   ],
#   "status": "pass|fail",           # fail iff any GATING assertion failed;
#                                    # informational assertions never gate
#   "artifacts": {"serial_log": "test/results/<ts>/serial.log",
#                 "journal": "test/results/<ts>/journal.log"}
# }
#
# Function API:
#   result_begin <target> <arch> <accel> <results-root-dir>
#   result_assert <name> <pass|fail> <details> [informational]
#   result_set_boot_seconds <int-seconds>
#   result_finish            (writes smoke.json, updates latest, sets RESULT_STATUS)

_result_die() {
    printf 'ERROR(result): %s\n' "$*" >&2
    exit 1
}

RESULT_TARGET=""
RESULT_ARCH=""
RESULT_ACCEL=""
RESULT_TIER="qemu"
RESULT_STARTED_AT=""
RESULT_BOOT_SECONDS=""
RESULT_DIR=""
RESULT_ASSERT_FILE=""
RESULT_STATUS=""

# result_begin <target> <arch> <accel> <results-root-dir>
# <results-root-dir> must be "<repo>/test/results"; artifact paths in the
# JSON are recorded relative to the repo root.
result_begin() {
    local target="${1:?target required}" arch="${2:?arch required}" \
          accel="${3:?accel required}" root="${4:?results root dir required}"
    local ts
    RESULT_TARGET=$target
    RESULT_ARCH=$arch
    RESULT_ACCEL=$accel
    RESULT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    RESULT_BOOT_SECONDS=""
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    RESULT_DIR=$root/$ts
    mkdir -p "$RESULT_DIR"
    # Pre-create so the artifacts exist even when QEMU never boots.
    : > "$RESULT_DIR/serial.log"
    : > "$RESULT_DIR/journal.log"
    RESULT_ASSERT_FILE=$(mktemp "${TMPDIR:-/tmp}/archmage-assertions.XXXXXX")
    printf 'smoke result dir: %s\n' "$RESULT_DIR" >&2
}

# result_assert <name> <pass|fail> <details> [informational]
# A non-empty 4th arg marks the assertion INFORMATIONAL: it is recorded in
# the JSON but never flips the overall status (ARCHITECTURE Anti-Pattern 2:
# the graphical stack is not a CI gate). Details of informational
# assertions should say so.
result_assert() {
    local name="${1:?name required}" status="${2:?status required}" \
          details="${3:?details required}" informational="${4:-}"
    local info_json=false
    case "$status" in
        pass|fail) ;;
        *) _result_die "result_assert: status must be pass|fail, got '$status' (name=$name)" ;;
    esac
    [ -n "$RESULT_ASSERT_FILE" ] || _result_die "result_assert called before result_begin"
    if [ -n "$informational" ]; then info_json=true; fi
    # Keep the JSON one-line-per-assertion: flatten newlines/tabs.
    details=${details//$'\n'/ }
    details=${details//$'\t'/ }
    jq -n --arg name "$name" --arg status "$status" --arg details "$details" \
          --argjson informational "$info_json" \
          '{name: $name, status: $status, details: $details, informational: $informational}' \
        >> "$RESULT_ASSERT_FILE"
    local tag=""
    if [ -n "$informational" ]; then tag=" (informational)"; fi
    printf '  [%s] %s%s — %s\n' "$status" "$name" "$tag" "$details" >&2
}

# result_set_boot_seconds <int-seconds>
result_set_boot_seconds() {
    RESULT_BOOT_SECONDS="${1:?seconds required}"
}

# result_finish
# Assemble smoke.json from the recorded assertions, set the overall status
# (fail iff any non-informational assertion failed), write
# <results-root>/<ts>/smoke.json and repoint the <results-root>/latest
# symlink at the new run directory. Sets RESULT_STATUS; returns 0 either
# way — the caller decides the process exit code.
result_finish() {
    local root ts fails status boot_json relroot
    [ -n "$RESULT_ASSERT_FILE" ] || _result_die "result_finish called before result_begin"
    root=${RESULT_DIR%/*}
    ts=${RESULT_DIR##*/}
    # Artifact paths are repo-relative: <repo>/test/results/<ts>/...
    relroot=$(basename "$(dirname "$root")")/$(basename "$root")

    fails=$(jq -s '[.[] | select((.informational | not) and (.status == "fail"))] | length' \
        "$RESULT_ASSERT_FILE")
    status=pass
    if [ "$fails" -gt 0 ]; then status=fail; fi

    if [ -n "$RESULT_BOOT_SECONDS" ]; then
        boot_json=$RESULT_BOOT_SECONDS
    else
        boot_json=null
    fi

    jq -n \
        --arg target "$RESULT_TARGET" \
        --arg arch "$RESULT_ARCH" \
        --arg accel "$RESULT_ACCEL" \
        --arg tier "$RESULT_TIER" \
        --arg started_at "$RESULT_STARTED_AT" \
        --argjson boot_seconds "$boot_json" \
        --slurpfile assertions "$RESULT_ASSERT_FILE" \
        --arg status "$status" \
        --arg serial_log "$relroot/$ts/serial.log" \
        --arg journal "$relroot/$ts/journal.log" \
        '{schema_version: 1,
          target: $target,
          arch: $arch,
          accel: $accel,
          tier: $tier,
          started_at: $started_at,
          boot_seconds: $boot_seconds,
          assertions: $assertions,
          status: $status,
          artifacts: {serial_log: $serial_log, journal: $journal}}' \
        > "$RESULT_DIR/smoke.json"

    ln -sfn "$ts" "$root/latest"
    rm -f "$RESULT_ASSERT_FILE"
    RESULT_ASSERT_FILE=""
    RESULT_STATUS=$status
    printf 'smoke.json: status=%s (%d gating failure(s)) -> %s\n' \
        "$status" "$fails" "$RESULT_DIR/smoke.json" >&2
}
