# shellcheck shell=bash
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
#                 "journal": "test/results/<ts>/journal.log"},
#   "source": "qemu|device"|null,    # 04-02 additive: measurement source
#                                    # (PERF-01 reserved device face); null
#                                    # when unset — pre-04-02 callers are
#                                    # untouched and read null
#   "metrics": {...}|null            # 04-02 additive: pre-assembled metrics
#                                    # object literal (perf.json); null when
#                                    # unset
# }
#
# Function API:
#   result_begin <target> <arch> <accel> <results-root-dir> [<json-name>]
#                <json-name> defaults to smoke.json (backward compatible with
#                the 01-02/02-01 call sites); Phase 3 cases pass their own
#                name (rollback.json / ime.json / waydroid.json)
#   result_set_tier <tier>        override the tier label (default "qemu";
#                qemu-kvm for the KVM-required Phase 3 cases)
#   result_assert <name> <pass|fail> <details> [informational]
#   result_set_boot_seconds <int-seconds>
#   result_set_source <qemu|device>   04-02 additive: measurement source for
#                the PERF-01 schema (default empty -> JSON null)
#   result_set_metrics <json-object-literal>  04-02 additive: store an
#                already-assembled JSON object literal emitted as the top
#                level "metrics" field (default unset -> JSON null)
#   result_finish            (writes <json-name>, updates latest, sets RESULT_STATUS)

_result_die() {
    printf 'ERROR(result): %s\n' "$*" >&2
    exit 1
}

RESULT_TARGET=""
RESULT_ARCH=""
RESULT_ACCEL=""
RESULT_TIER="qemu"
RESULT_JSON="smoke.json"
RESULT_STARTED_AT=""
RESULT_BOOT_SECONDS=""
RESULT_SOURCE=""
RESULT_METRICS=""
RESULT_DIR=""
RESULT_ASSERT_FILE=""
RESULT_STATUS=""

# result_begin <target> <arch> <accel> <results-root-dir> [<json-name>]
# <results-root-dir> must be "<repo>/test/results"; artifact paths in the
# JSON are recorded relative to the repo root. <json-name> names the result
# file inside the run directory (default smoke.json).
result_begin() {
    local target="${1:?target required}" arch="${2:?arch required}" \
          accel="${3:?accel required}" root="${4:?results root dir required}" \
          json_name="${5:-smoke.json}"
    local ts
    RESULT_TARGET=$target
    RESULT_ARCH=$arch
    RESULT_ACCEL=$accel
    RESULT_JSON=$json_name
    RESULT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    RESULT_BOOT_SECONDS=""
    RESULT_SOURCE=""
    RESULT_METRICS=""
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    RESULT_DIR=$root/$ts
    mkdir -p "$RESULT_DIR"
    # Pre-create so the artifacts exist even when QEMU never boots.
    : > "$RESULT_DIR/serial.log"
    : > "$RESULT_DIR/journal.log"
    RESULT_ASSERT_FILE=$(mktemp "${TMPDIR:-/tmp}/archmage-assertions.XXXXXX")
    printf 'smoke result dir: %s\n' "$RESULT_DIR" >&2
}

# result_set_tier <tier>
# Tier label override (PITFALLS 4: every artifact carries its verification
# tier). Default "qemu"; "qemu-kvm" marks the KVM-required Phase 3 cases.
result_set_tier() {
    RESULT_TIER="${1:?tier required}"
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

# result_set_source <qemu|device>
# 04-02 additive (PERF-01): the measurement source carried as the top-level
# "source" field. Empty (the default) emits JSON null, so every pre-04-02
# call site (smoke/rollback/ime/waydroid) keeps its exact former JSON shape
# plus two additive null fields.
result_set_source() {
    local source="${1:?source required (qemu|device)}"
    case "$source" in
        qemu|device) ;;
        *) _result_die "result_set_source: source must be qemu|device, got '$source'" ;;
    esac
    RESULT_SOURCE=$source
}

# result_set_metrics <json-object-literal>
# 04-02 additive (PERF-01): stores an ALREADY-ASSEMBLED JSON object literal
# (built by the caller with jq -n) emitted verbatim as the top-level
# "metrics" field. Unset (the default) emits JSON null.
result_set_metrics() {
    local metrics="${1:?metrics object literal required}"
    printf '%s' "$metrics" | jq -e 'type == "object"' >/dev/null 2>&1 ||
        _result_die "result_set_metrics: argument is not a JSON object literal: '$metrics'"
    RESULT_METRICS=$metrics
}

# result_finish
# Assemble the result JSON (named by result_begin's json-name argument) from
# the recorded assertions, set the overall status (fail iff any
# non-informational assertion failed), write
# <results-root>/<ts>/<json-name> and repoint the <results-root>/latest
# symlink at the new run directory. Sets RESULT_STATUS; returns 0 either
# way — the caller decides the process exit code.
result_finish() {
    local root ts fails status boot_json relroot source_json metrics_json
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

    # 04-02 additive fields: unset source/metrics emit JSON null (the
    # pre-04-02 contract keeps schema_version 1 and every former key).
    if [ -n "$RESULT_SOURCE" ]; then
        source_json=$(jq -n --arg s "$RESULT_SOURCE" '$s')
    else
        source_json=null
    fi
    if [ -n "$RESULT_METRICS" ]; then
        metrics_json=$RESULT_METRICS
    else
        metrics_json=null
    fi

    jq -n \
        --arg target "$RESULT_TARGET" \
        --arg arch "$RESULT_ARCH" \
        --arg accel "$RESULT_ACCEL" \
        --arg tier "$RESULT_TIER" \
        --arg started_at "$RESULT_STARTED_AT" \
        --argjson boot_seconds "$boot_json" \
        --argjson source "$source_json" \
        --argjson metrics "$metrics_json" \
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
          source: $source,
          metrics: $metrics,
          assertions: $assertions,
          status: $status,
          artifacts: {serial_log: $serial_log, journal: $journal}}' \
        > "$RESULT_DIR/$RESULT_JSON"

    ln -sfn "$ts" "$root/latest"
    rm -f "$RESULT_ASSERT_FILE"
    RESULT_ASSERT_FILE=""
    RESULT_STATUS=$status
    printf '%s: status=%s (%d gating failure(s)) -> %s\n' \
        "$RESULT_JSON" "$status" "$fails" "$RESULT_DIR/$RESULT_JSON" >&2
}
