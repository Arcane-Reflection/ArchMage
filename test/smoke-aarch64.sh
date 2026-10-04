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

REPO_ROOT=$(archmage::repo_root)
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
        archmage_info "building the aarch64 smoke rootfs first (mkrootfs-aarch64.sh)"
        MKROOTFS_ARGS=()
        if [ "$MODE" = dir ]; then
            MKROOTFS_ARGS+=(--repo-dir "$REPO_DIR_ARG")
        else
            MKROOTFS_ARGS+=(--from-ci)
        fi
        bash "$SCRIPT_DIR/mkrootfs-aarch64.sh" "${MKROOTFS_ARGS[@]}"
    fi

    # ARCHMAGE_FORCE_WRAP=1 skips the host qemu even when present — the
    # Ubuntu runner qemu produced a VNC display and ZERO serial bytes
    # (runs 37119945808/37130418440/37169011433), i.e. the guest never ran.
    # The Arch container qemu is the verified-good path.
    if [ "${ARCHMAGE_FORCE_WRAP:-0}" = "1" ] || ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
        archmage_info "self-wrapping the QEMU phase in an Arch container (qemu-system-aarch64 from ALARM repos)"
        archmage::engine_detect
        # Platform: native by default; the wrapper image must match the host
        # arch (menci/archlinuxarm is multi-arch; ghcr archlinux:base is not).
        WRAP_ARGS=(--rm -v "$REPO_ROOT":/w -w /w)
        if [ -n "${ARCHMAGE_WRAP_PLATFORM:-}" ]; then
            WRAP_ARGS+=(--platform "$ARCHMAGE_WRAP_PLATFORM")
        fi
        # --network host: the inner qemu hostfwd binds the HOST loopback
        # directly (T-01-06 holds); no port publishing needed.
        WRAP_ARGS=(--rm --network host -v "$REPO_ROOT":/w -w /w)
        if [ -n "${ARCHMAGE_WRAP_PLATFORM:-}" ]; then
            WRAP_ARGS+=(--platform "$ARCHMAGE_WRAP_PLATFORM")
        fi
        if archmage::kvm_available; then
            WRAP_ARGS+=(--device /dev/kvm)
        fi
        # The container runs as root; RESULT_DIR files must go back to the
        # invoking user (chowned in the inner EXIT trap).
        WRAP_ARGS+=(-e ARCHMAGE_HOST_UID="$(id -u)")
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
        WRAP_IMAGE="${ARCHMAGE_WRAP_IMAGE:-archlinux:base}"
        echo "wrap: engine=$ARCHMAGE_ENGINE image=$WRAP_IMAGE"
        echo "wrap: args=${WRAP_ARGS[*]}"
        "$ARCHMAGE_ENGINE" run "${WRAP_ARGS[@]}" "$WRAP_IMAGE" bash -c \
            "grep -q '^DisableSandbox' /etc/pacman.conf || sed -i 's/^\\[options\\]\\$/[options]\\nDisableSandbox/' /etc/pacman.conf; \
             pacman -Sy --noconfirm qemu-emulators-full openssh jq e2fsprogs && bash test/smoke-aarch64.sh $INNER_CMD"
        RC=$?
        if [ "$RC" -ne 0 ]; then
            echo "wrap failed rc=$RC — engine diagnostics follow" >&2
            "$ARCHMAGE_ENGINE" version 2>&1 | head -4 >&2 || true
        fi
        set -e
        exit "$RC"
    fi
fi

# --------------------------------------------------------------------------
# QEMU phase (native host with qemu, or inside the self-wrapped container).
# --------------------------------------------------------------------------
archmage::require_cmd qemu-system-aarch64 jq ssh

ACCEL_RESOLVED=$ACCEL
case "$ACCEL" in
    auto)
        if archmage::host_is_aarch64 && archmage::kvm_available; then
            ACCEL_RESOLVED=kvm
        else
            ACCEL_RESOLVED=tcg
        fi
        ;;
    kvm)
        archmage::host_is_aarch64 || die "--accel kvm requires an aarch64 host"
        archmage::kvm_available || die "--accel kvm requires a writable /dev/kvm"
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
    if [ "$INNER" = yes ] && [ -n "${ARCHMAGE_HOST_UID:-}" ] && [ -n "$RESULT_DIR" ]; then
        chown -R "$ARCHMAGE_HOST_UID" "$RESULT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

archmage_info "starting QEMU ($ACCEL_RESOLVED, timeout ${TIMEOUT}s) — serial: $SERIAL_LOG"
qemu-system-aarch64 \
    -M virt -cpu "$QEMU_CPU" -m 2048 -smp 2 \
    -kernel "$AARCH64_DIR/Image" \
    -initrd "$AARCH64_DIR/initramfs-linux.img" \
    -append "root=/dev/vda rw console=ttyAMA0" \
    -drive file="$AARCH64_DIR/rootfs.ext4",if=virtio,format=raw \
    -netdev user,id=n0,hostfwd="$(archmage::hostfwd_tcp 2222)" \
    -device virtio-net-pci,netdev=n0,romfile= \

    -display none -monitor none -no-reboot \
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

# --- Assertion set (SIM-02; gates marked, phosh stays informational) -----
# 1. multi-user target active (gate — hard gate = boot + SSH + no failed
#    units; ARCHITECTURE Anti-Pattern 2).
MULTI_USER=$(vm_ssh "systemctl is-active multi-user.target" 2>/dev/null || true)
if [ "$MULTI_USER" = active ]; then
    result_assert multi_user pass "systemctl is-active multi-user.target -> active"
else
    result_assert multi_user fail "systemctl is-active multi-user.target -> '${MULTI_USER:-<no output>}'"
fi

# 2. No failed units (gate).
FAILED_UNITS=$(vm_ssh "systemctl --failed --no-legend" 2>/dev/null || true)
if [ -z "$FAILED_UNITS" ]; then
    result_assert no_failed_units pass "systemctl --failed --no-legend -> empty"
else
    result_assert no_failed_units fail "failed units: ${FAILED_UNITS//$'\n'/; }"
fi

# 3. CN mirror factory-applied into /etc/pacman.d/mirrorlist (gate).
CN_MIRROR_MATCH=$(vm_ssh "grep -cE 'mirrors\.tuna\.tsinghua\.edu\.cn|mirrors\.ustc\.edu\.cn' /etc/pacman.d/mirrorlist" 2>/dev/null || true)
if [ "${CN_MIRROR_MATCH:-0}" -gt 0 ] 2>/dev/null; then
    result_assert cn_mirror_config pass "/etc/pacman.d/mirrorlist contains ${CN_MIRROR_MATCH} TUNA/USTC server line(s)"
else
    result_assert cn_mirror_config fail "/etc/pacman.d/mirrorlist has no TUNA/USTC server (got '${CN_MIRROR_MATCH:-<no output>}')"
fi

# 4. pacman -Syu through the CN mirror (gate; CN-01 loop proof).
PACMAN_LOG=$RESULT_DIR/pacman-syu.log
# CI face is sync-only: a full -Syu upgrade under TCG on shared runners
# takes 40+ min (kernel + mkinitcpio under emulation) and blew every job
# budget; mirror reachability is what the CN-01 gate proves here. The full
# -Syu upgrade face runs in the local battery (verified 2026-09-19, and on
# every KVM dev loop).
if VMSSH_TIMEOUT=300 vm_ssh "timeout 240 pacman -Sy --noconfirm" \
        >>"$PACMAN_LOG" 2>&1; then
    result_assert pacman_sync_via_cn_mirror pass \
        "pacman -Sy --noconfirm exit 0 (sync-only CI face; full log: $(basename "$PACMAN_LOG"))"
else
    result_assert pacman_sync_via_cn_mirror fail \
        "pacman -Sy --noconfirm failed — see $(basename "$PACMAN_LOG") and the serial/journal artifacts"
fi

# 5. CN defaults installed (gate; ROADMAP criterion 4 made explicit — also
#    the in-loop proof of CN-02).
if vm_ssh "pacman -Q archmage-cn noto-fonts-cjk" >/dev/null 2>&1 &&
    vm_ssh "grep -q 'zh_CN.UTF-8' /etc/locale.conf" >/dev/null 2>&1; then
    result_assert cn_defaults_installed pass \
        "pacman -Q archmage-cn noto-fonts-cjk ok; /etc/locale.conf has zh_CN.UTF-8"
else
    CN_PKGS=$(vm_ssh "pacman -Q archmage-cn noto-fonts-cjk" 2>&1 || true)
    CN_LOCALE=$(vm_ssh "grep -c 'zh_CN.UTF-8' /etc/locale.conf" 2>/dev/null || true)
    result_assert cn_defaults_installed fail \
        "pkgs: ${CN_PKGS//$'\n'/; }; locale.conf zh_CN.UTF-8 count: '${CN_LOCALE:-<none>}'"
fi

# 6. phosh — informational ONLY (never gates; details must say so).
PHOSH_STATE=$(vm_ssh "systemctl is-active phosh" 2>/dev/null || true)
PHOSH_STATUS=fail
if [ "$PHOSH_STATE" = active ]; then
    PHOSH_STATUS=pass
fi
result_assert phosh_informational "$PHOSH_STATUS" \
    "informational: systemctl is-active phosh -> '${PHOSH_STATE:-<no output>}' (expected inactive on the minimal headless rootfs; the graphical stack is not a CI gate — ARCHITECTURE Anti-Pattern 2)" \
    informational
# --------------------------------------------------------------------------

# Archive the boot journal before shutdown (triage artifact).
if VMSSH_TIMEOUT=60 vm_ssh "journalctl -b --no-pager" > "$JOURNAL_LOG" 2>/dev/null; then
    archmage_info "journal captured: $JOURNAL_LOG"
else
    archmage_warn "journal capture failed (guest may be degraded) — see serial log"
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
    archmage_info "smoke PASS: $RESULT_DIR/smoke.json"
    exit 0
fi
archmage_warn "smoke FAIL: $RESULT_DIR/smoke.json"
exit 1
