#!/usr/bin/env bash
# smoke-aarch64.sh — one-command headless aarch64 QEMU smoke test (SIM-02).
#
#   staging artifact (01-01 CI) -> minimal rootfs -> QEMU boot -> SSH
#   (127.0.0.1:2222) -> assertions -> structured JSON + serial/journal
#
# One command, self-wrapping: when qemu-system-aarch64 is missing on the
# host (e.g. this dev laptop), the QEMU phase re-executes itself inside an
# archlinux container after installing qemu-emulators-full there. The gh
# download stage always runs on the HOST.
#
# Usage:
#   bash test/smoke-aarch64.sh [--from-ci | --repo-dir PATH]
#                              [--accel auto|kvm|tcg] [--timeout SECS]
#                              [--rebuild]
#
# Outputs: test/results/<ts>/{smoke.json, serial.log, journal.log,
# console.log, qemu.pid} and the test/results/latest symlink.
# Exit code 0 iff every GATING assertion passed (tier: qemu — QEMU green
# is never device green, PITFALLS 4).

set -euo pipefail

usage() {
    cat <<'EOF'
smoke-aarch64.sh — headless aarch64 QEMU smoke test (one command)

Usage:
  bash test/smoke-aarch64.sh [options]

Options:
  --from-ci        Pass-through to mkrootfs-aarch64.sh: consume the latest
                   successful main-run staging-repo artifact (default).
  --repo-dir PATH  Pass-through: use a local staging artifact directory.
  --accel MODE     auto (default; kvm on aarch64 hosts with /dev/kvm,
                   else tcg) | kvm | tcg.
  --timeout SECS   SSH-readiness budget, default 600.
  --rebuild        Force a fresh mkrootfs-aarch64.sh run.
  -h, --help       Show this help.

Internal:
  --in-container   Re-execution flag set inside the self-wrapped QEMU
                   container; never pass it manually.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

ACCEL=auto
TIMEOUT=600
MODE=""
REPO_DIR_ARG=""
REBUILD=no
INNER=no
ARGS_OUT=()
while [ $# -gt 0 ]; do
    case "$1" in
        --accel)
            [ $# -ge 2 ] || die "--accel needs auto|kvm|tcg"
            ACCEL=$2
            shift
            ARGS_OUT+=(--accel "$ACCEL")
            ;;
        --timeout)
            [ $# -ge 2 ] || die "--timeout needs a number of seconds"
            TIMEOUT=$2
            shift
            ARGS_OUT+=(--timeout "$TIMEOUT")
            ;;
        --from-ci)
            MODE=ci
            ARGS_OUT+=(--from-ci)
            ;;
        --repo-dir)
            [ $# -ge 2 ] || die "--repo-dir needs a PATH argument"
            REPO_DIR_ARG=$2
            MODE=dir
            shift
            ARGS_OUT+=(--repo-dir "$REPO_DIR_ARG")
            ;;
        --rebuild)
            REBUILD=yes
            ;;
        --in-container)
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
case "$ACCEL" in
    auto|kvm|tcg) ;;
    *) die "--accel must be auto|kvm|tcg, got '$ACCEL'" ;;
esac
case "$TIMEOUT" in
    ''|*[!0-9]*) die "--timeout must be a positive integer, got '$TIMEOUT'" ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT=$(lpos::repo_root)
AARCH64_DIR=$REPO_ROOT/test/build/aarch64
RESULTS_ROOT=$REPO_ROOT/test/results
SMOKE_KEY=$AARCH64_DIR/smoke_key

artifacts_present() {
    [ -s "$AARCH64_DIR/Image" ] &&
        [ -s "$AARCH64_DIR/initramfs-linux.img" ] &&
        [ -s "$AARCH64_DIR/rootfs.ext4" ] &&
        [ -f "$SMOKE_KEY" ]
}

# --------------------------------------------------------------------------
# Host phase: build rootfs if needed; self-wrap when qemu is missing.
# --------------------------------------------------------------------------
if [ "$INNER" = no ]; then
    if [ "$REBUILD" = yes ] || ! artifacts_present; then
        lpos_info "building the aarch64 smoke rootfs first (mkrootfs-aarch64.sh)"
        MKROOTFS_ARGS=()
        if [ "$MODE" = dir ]; then
            MKROOTFS_ARGS+=(--repo-dir "$REPO_DIR_ARG")
        else
            MKROOTFS_ARGS+=(--from-ci)
        fi
        bash "$SCRIPT_DIR/mkrootfs-aarch64.sh" "${MKROOTFS_ARGS[@]}"
    fi

    if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        lpos_info "qemu-system-aarch64 missing on host — self-wrapping the QEMU phase in an archlinux container (qemu-emulators-full; qemu-desktop only ships x86_64 emulators)"
        lpos::engine_detect
        WRAP_ARGS=(--rm --platform linux/x86_64 -v "$REPO_ROOT":/w -w /w)
        if lpos::kvm_available; then
            WRAP_ARGS+=(--device /dev/kvm)
        fi
        # The container runs as root; RESULT_DIR files must go back to the
        # invoking user (chowned in the inner EXIT trap).
        WRAP_ARGS+=(-e LPOS_HOST_UID="$(id -u)")
        INNER_ARGS=(--in-container)
        if [ ${#ARGS_OUT[@]} -gt 0 ]; then
            INNER_ARGS+=("${ARGS_OUT[@]}")
        fi
        INNER_CMD=""
        if [ ${#INNER_ARGS[@]} -gt 0 ]; then
            INNER_CMD=$(printf '%q ' "${INNER_ARGS[@]}")
        fi
        set +e
        # shellcheck disable=SC2086
        "$LPOS_ENGINE" run "${WRAP_ARGS[@]}" archlinux:base bash -c \
            "pacman -Sy --noconfirm qemu-emulators-full openssh jq e2fsprogs >/dev/null 2>&1 && bash test/smoke-aarch64.sh $INNER_CMD"
        RC=$?
        set -e
        exit "$RC"
    fi
fi

# --------------------------------------------------------------------------
# QEMU phase (native host with qemu, or inside the self-wrapped container).
# --------------------------------------------------------------------------
lpos::require_cmd qemu-system-aarch64 jq ssh

ACCEL_RESOLVED=$ACCEL
case "$ACCEL" in
    auto)
        if lpos::host_is_aarch64 && lpos::kvm_available; then
            ACCEL_RESOLVED=kvm
        else
            ACCEL_RESOLVED=tcg
        fi
        ;;
    kvm)
        lpos::host_is_aarch64 || die "--accel kvm requires an aarch64 host"
        lpos::kvm_available || die "--accel kvm requires a writable /dev/kvm"
        ;;
    tcg)
        ;;
esac
QEMU_CPU=cortex-a57
if [ "$ACCEL_RESOLVED" = kvm ]; then
    QEMU_CPU=host
fi

if [ "$INNER" = yes ] && ! artifacts_present; then
    die "build artifacts missing under $AARCH64_DIR — the host phase should have created them"
fi
artifacts_present || die "build artifacts missing under $AARCH64_DIR (run with --rebuild)"

# 127.0.0.1:2222 must be free (T-01-06: hostfwd is loopback-only).
if (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null; then
    die "127.0.0.1:2222 is already in use — is a stale QEMU instance running? Kill it and re-run."
fi

# shellcheck source=lib/result.sh
source "$SCRIPT_DIR/lib/result.sh"
result_begin alarm-aarch64-rootfs aarch64 "$ACCEL_RESOLVED" "$RESULTS_ROOT"
SERIAL_LOG=$RESULT_DIR/serial.log
JOURNAL_LOG=$RESULT_DIR/journal.log
PID_FILE=$RESULT_DIR/qemu.pid
QEMU_PID=""

# SSH into the guest (user-mode NAT, loopback-only forward).
vm_ssh() {
    local secs=${VMSSH_TIMEOUT:-60}
    timeout "$secs" ssh -p 2222 -i "$SMOKE_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes \
        root@127.0.0.1 "$@"
}

# T-01-09: no QEMU/SSH leftovers — graceful poweroff, then TERM/KILL.
cleanup() {
    trap - EXIT INT TERM
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        VMSSH_TIMEOUT=15 vm_ssh poweroff >/dev/null 2>&1 || true
        local i
        for i in $(seq 1 20); do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 3
        done
        if kill -0 "$QEMU_PID" 2>/dev/null; then
            kill -TERM "$QEMU_PID" 2>/dev/null || true
            sleep 5
            kill -KILL "$QEMU_PID" 2>/dev/null || true
        fi
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
    # Inside the self-wrapped container we run as root: give the run
    # directory back to the invoking host user.
    if [ "$INNER" = yes ] && [ -n "${LPOS_HOST_UID:-}" ] && [ -n "$RESULT_DIR" ]; then
        chown -R "$LPOS_HOST_UID" "$RESULT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

lpos_info "starting QEMU ($ACCEL_RESOLVED, timeout ${TIMEOUT}s) — serial: $SERIAL_LOG"
qemu-system-aarch64 \
    -M virt -cpu "$QEMU_CPU" -m 2048 -smp 2 \
    -kernel "$AARCH64_DIR/Image" \
    -initrd "$AARCH64_DIR/initramfs-linux.img" \
    -append "root=/dev/vda rw console=ttyAMA0" \
    -drive file="$AARCH64_DIR/rootfs.ext4",if=virtio,format=raw \
    -netdev user,id=n0,hostfwd="$(lpos::hostfwd_tcp 2222)" \
    -device virtio-net-pci,netdev=n0 \
    -nographic -monitor none -no-reboot \
    -serial "file:$SERIAL_LOG" \
    -pidfile "$PID_FILE" \
    </dev/null >>"$RESULT_DIR/console.log" 2>&1 &
QEMU_PID=$!

# Wait for SSH readiness within the budget.
SECONDS=0
SSH_READY=no
while :; do
    if vm_ssh true >/dev/null 2>&1; then
        SSH_READY=yes
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        result_assert ssh_ready fail \
            "QEMU exited before SSH became ready — see $(basename "$SERIAL_LOG") and console.log in the result dir"
        result_finish
        die "QEMU died during boot (see $SERIAL_LOG / $RESULT_DIR/console.log)"
    fi
    if [ "$SECONDS" -ge "$TIMEOUT" ]; then
        break
    fi
    sleep 5
done

if [ "$SSH_READY" = yes ]; then
    result_assert ssh_ready pass "SSH ready at 127.0.0.1:2222 after ${SECONDS}s"
    result_set_boot_seconds "$SECONDS"
else
    result_assert ssh_ready fail "SSH not ready within ${TIMEOUT}s (boot timeout)"
    result_finish
    die "boot timeout — serial log: $SERIAL_LOG"
fi

# --- Task 1 (tracer): the single thinnest gating assertion ---------------
MULTI_USER=$(vm_ssh "systemctl is-active multi-user.target" 2>/dev/null || true)
if [ "$MULTI_USER" = active ]; then
    result_assert multi_user pass "systemctl is-active multi-user.target -> active"
else
    result_assert multi_user fail "systemctl is-active multi-user.target -> '${MULTI_USER:-<no output>}'"
fi
# --------------------------------------------------------------------------

# Archive the boot journal before shutdown (triage artifact).
if VMSSH_TIMEOUT=60 vm_ssh "journalctl -b --no-pager" > "$JOURNAL_LOG" 2>/dev/null; then
    lpos_info "journal captured: $JOURNAL_LOG"
else
    lpos_warn "journal capture failed (guest may be degraded) — see serial log"
fi

# Graceful shutdown.
vm_ssh poweroff >/dev/null 2>&1 || true
WAITED=0
while kill -0 "$QEMU_PID" 2>/dev/null && [ "$WAITED" -lt 60 ]; do
    sleep 3
    WAITED=$((WAITED + 3))
done

result_finish

if [ "$RESULT_STATUS" = pass ]; then
    lpos_info "smoke PASS: $RESULT_DIR/smoke.json"
    exit 0
fi
lpos_warn "smoke FAIL: $RESULT_DIR/smoke.json"
exit 1
