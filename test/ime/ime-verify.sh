#!/usr/bin/env bash
# ime-verify.sh — real phosh-session IME end-to-end verification (03-01;
# IME-01/02 machine face + the 03-RESEARCH Week-1 spike 1/2 carrier).
#
#   btrfs dev image (mkrootfs-x86_64.sh, fcitx5 + phosh session unit)
#   -> QEMU (KVM, virtio-gpu, -display none) -> SSH
#   -> phosh session (WLR_RENDERER=pixman, root, dbus-run-session)
#   -> session reachable (WAYLAND_DISPLAY socket + phoc + grim screenshot)
#   -> fcitx5 -d (waylandim = the only zwp_input_method_v2 client; the
#      squeekboard activation path is masked for the tracer)
#   -> GTK4 entry app focused -> wtype "nihao" + space
#   -> app ground-truth log contains 「你好」 and NOT the raw pinyin
#   -> WAYLAND_DEBUG probe: fcitx5 classic UI creates
#      zwp_input_popup_surface_v2 (spike decision evidence)
#   -> (Task 3) six-toolkit input matrix via test/ime/run-matrix.sh
#
# Modeled on test/smoke-x86_64.sh: self-wrapping container, --repo-dir /
# --from-ci pass-through, structured JSON + artifacts under
# test/results/<ts>/ (ime.json; ime-matrix.json lands in the same dir),
# cleanup leaves no QEMU/SSH residue. The image is rebuilt whenever
# mkrootfs-x86_64.sh or the consumed staging artifact changed (stamp file) —
# the IME stack lives IN the image, so reusing a stale image would silently
# verify nothing.
#
# KVM-required (Phase 3 exit-code contract): without a writable /dev/kvm the
# script prints `KVM_REQUIRED: ...` as the FIRST stderr line and exits 34.
# The only exemption is ARCHMAGE_QEMU_ALLOW_TCG=1 (caller explicitly accepts
# the long TCG runtime and must raise --timeout itself).
#
# Usage:
#   bash test/ime/ime-verify.sh [--from-ci | --repo-dir PATH]
#                               [--timeout SECS] [--accel kvm|tcg]
#                               [--rebuild]
#
# Outputs: test/results/<ts>/{ime.json, serial.log, journal.log, console.log,
# fcitx5.log, ime-probe.log, app.log, phosh-session-reachable.png,
# ime-candidate-window.png, ime-committed.png, qemu.pid} and the
# test/results/latest symlink. Exit code 0 iff every GATING assertion passed
# (tier: qemu-kvm — a real graphical session; TCG only via the exemption).

set -euo pipefail

usage() {
    cat <<'EOF'
ime-verify.sh — phosh-session IME end-to-end verification (QEMU, KVM-required)

Usage:
  bash test/ime/ime-verify.sh [options]

Options:
  --from-ci        Pass-through to mkrootfs-x86_64.sh: consume the latest
                   successful main-run staging-repo artifact (default).
  --repo-dir PATH  Pass-through: use a local staging artifact directory.
  --timeout SECS   SSH-readiness budget, default 600.
  --accel MODE     kvm (default; KVM-required per the Phase 3 exit-code
                   contract) | tcg (only honoured with
                   ARCHMAGE_QEMU_ALLOW_TCG=1).
  --rebuild        Force a fresh mkrootfs-x86_64.sh run (default: rebuild
                   when the mkrootfs script or staging artifact changed).
  -h, --help       Show this help.

Environment:
  ARCHMAGE_QEMU_ALLOW_TCG=1   Exemption switch for the KVM_REQUIRED guard
                              (exit 34): accept the slow TCG emulation.

Internal:
  --in-container   Re-execution flag set inside the self-wrapped QEMU
                   container; never pass it manually.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

TIMEOUT=600
MODE=""
REPO_DIR_ARG=""
REBUILD=no
INNER=no
ACCEL=""
ARGS_OUT=()
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)
            [ $# -ge 2 ] || die "--timeout needs a number of seconds"
            TIMEOUT=$2
            shift
            ARGS_OUT+=(--timeout "$TIMEOUT")
            ;;
        --accel)
            [ $# -ge 2 ] || die "--accel needs kvm|tcg"
            ACCEL=$2
            shift
            ARGS_OUT+=(--accel "$ACCEL")
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
    ''|kvm|tcg) ;;
    *) die "--accel must be kvm|tcg, got '$ACCEL'" ;;
esac
case "$TIMEOUT" in
    ''|*[!0-9]*) die "--timeout must be a positive integer, got '$TIMEOUT'" ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# --------------------------------------------------------------------------
# KVM guard (Phase 3 exit-code contract) — runs in the HOST phase before the
# rootfs build AND again in the self-wrapped container phase, so the very
# first stderr line is KVM_REQUIRED whenever KVM is genuinely unavailable.
# --------------------------------------------------------------------------
if ! archmage::kvm_available && [ "${ARCHMAGE_QEMU_ALLOW_TCG:-}" != "1" ]; then
    printf 'KVM_REQUIRED: ime-verify.sh drives a real phosh graphical session and needs KVM-accelerated QEMU, but /dev/kvm is not accessible (missing, or not passed into the container).\n'
    printf 'KVM_REQUIRED: enable KVM on the host (load the kvm module, ensure your user can write /dev/kvm) and pass --device /dev/kvm when containerized; or re-run with ARCHMAGE_QEMU_ALLOW_TCG=1 and a larger --timeout to accept the slow TCG emulation.\n'
    exit 34
fi

REPO_ROOT=$(archmage::repo_root)
X86_64_DIR=$REPO_ROOT/test/build/x86_64
RESULTS_ROOT=$REPO_ROOT/test/results
SMOKE_KEY=$X86_64_DIR/smoke_key
IMG_STAMP=$X86_64_DIR/ime-image.stamp

# The rebuild stamp: the image must match what THIS mkrootfs-x86_64.sh would
# produce from THIS staging artifact. Any change to either forces a rebuild.
stamp_key() {
    local repo_part=ci
    if [ "$MODE" = dir ]; then
        local abs
        abs=$(cd -- "$REPO_DIR_ARG" 2>/dev/null && pwd) || abs="$REPO_DIR_ARG"
        # Normalize to a repo-root-RELATIVE path. The self-wrapped container
        # mounts THIS repo at /w, so an absolute key can never match across
        # the host/container boundary (/home/.../test/build/staging-repo vs
        # /w/test/build/staging-repo — observed live 03-01: every --repo-dir
        # run died at the inner stamp check after a successful build).
        case "$abs" in
            "$REPO_ROOT") repo_part="." ;;
            "$REPO_ROOT"/*) repo_part="${abs#"$REPO_ROOT"/}" ;;
            *) repo_part="$abs" ;;
        esac
    fi
    printf '%s|%s\n' \
        "$(sha256sum "$SCRIPT_DIR/../mkrootfs-x86_64.sh" | cut -d' ' -f1)" \
        "$MODE:$repo_part"
}

artifacts_present() {
    [ -s "$X86_64_DIR/vmlinuz-linux" ] &&
        [ -s "$X86_64_DIR/initramfs-linux.img" ] &&
        [ -s "$X86_64_DIR/rootfs.img" ] &&
        [ -f "$SMOKE_KEY" ]
}

# --------------------------------------------------------------------------
# Host phase: build rootfs if the stamp demands it; self-wrap when qemu is
# missing.
# --------------------------------------------------------------------------
if [ "$INNER" = no ]; then
    NEED_BUILD=no
    if ! artifacts_present; then
        NEED_BUILD=yes
    elif [ "$REBUILD" = yes ]; then
        NEED_BUILD=yes
    elif [ "$(cat "$IMG_STAMP" 2>/dev/null || true)" != "$(stamp_key)" ]; then
        archmage_info "image stamp mismatch (mkrootfs or staging artifact changed) — rebuilding"
        NEED_BUILD=yes
    fi
    if [ "$NEED_BUILD" = yes ]; then
        archmage_info "building the x86_64 IME dev image first (mkrootfs-x86_64.sh)"
        MKROOTFS_ARGS=()
        if [ "$MODE" = dir ]; then
            MKROOTFS_ARGS+=(--repo-dir "$REPO_DIR_ARG")
        else
            MKROOTFS_ARGS+=(--from-ci)
        fi
        bash "$SCRIPT_DIR/../mkrootfs-x86_64.sh" "${MKROOTFS_ARGS[@]}"
        stamp_key > "$IMG_STAMP"
    fi

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        archmage_info "qemu-system-x86_64 missing on host — self-wrapping the QEMU phase in an archlinux container (qemu-emulators-full)"
        archmage::engine_detect
        WRAP_ARGS=(--rm --platform linux/x86_64 -v "$REPO_ROOT":/w -w /w)
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
        "$ARCHMAGE_ENGINE" run "${WRAP_ARGS[@]}" archlinux:base bash -c \
            "pacman -Sy --noconfirm qemu-emulators-full qemu-hw-display-virtio-gpu qemu-hw-display-virtio-vga openssh jq >/dev/null 2>&1 && bash test/ime/ime-verify.sh $INNER_CMD"
        RC=$?
        set -e
        exit "$RC"
    fi
fi

# --------------------------------------------------------------------------
# QEMU phase (native host with qemu, or inside the self-wrapped container).
# --------------------------------------------------------------------------
archmage::require_cmd qemu-system-x86_64 jq ssh

ACCEL_RESOLVED=$ACCEL
if [ -z "$ACCEL_RESOLVED" ]; then
    if archmage::kvm_available; then
        ACCEL_RESOLVED=kvm
    else
        # Only reachable with ARCHMAGE_QEMU_ALLOW_TCG=1 (the guard above).
        ACCEL_RESOLVED=tcg
    fi
fi
case "$ACCEL_RESOLVED" in
    kvm) archmage::kvm_available || die "--accel kvm requires a writable /dev/kvm" ;;
    tcg) ;;
esac
QEMU_CPU=max
if [ "$ACCEL_RESOLVED" = kvm ]; then
    QEMU_CPU=host
fi

if [ "$INNER" = yes ] && ! artifacts_present; then
    die "build artifacts missing under $X86_64_DIR — the host phase should have created them"
fi
artifacts_present || die "build artifacts missing under $X86_64_DIR (run with --rebuild)"
# Container phase: the image must match the current mkrootfs + staging
# artifact. A silent reuse of a stale image would verify nothing (observed
# live: manual --in-container invocation after editing mkrootfs booted the
# old session unit) — fail loudly instead; the host phase owns rebuilds.
if [ "$INNER" = yes ]; then
    STAMP_FILE=$(cat "$IMG_STAMP" 2>/dev/null || true)
    STAMP_KEY=$(stamp_key)
    if [ "$STAMP_FILE" != "$STAMP_KEY" ]; then
        die "image stamp mismatch under $X86_64_DIR — re-run the host phase (drop --in-container) so mkrootfs-x86_64.sh rebuilds the image first [file: $STAMP_FILE | computed: $STAMP_KEY]"
    fi
fi

# 127.0.0.1:2222 must be free (T-01-06: hostfwd is loopback-only).
if (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null; then
    die "127.0.0.1:2222 is already in use — is a stale QEMU instance running? Kill it and re-run."
fi

# shellcheck source=../lib/result.sh
source "$SCRIPT_DIR/../lib/result.sh"
result_begin archmage-qemu-x86_64-ime x86_64 "$ACCEL_RESOLVED" "$RESULTS_ROOT" ime.json
result_set_tier qemu-kvm
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

vm_scp_to() {  # vm_scp_to <guest-path> <local-path...>
    local dest=$1
    shift
    timeout 120 scp -P 2222 -i "$SMOKE_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes \
        "$@" "root@127.0.0.1:$dest"
}

vm_scp_from() {  # vm_scp_from <guest-path> <local-path>
    timeout 120 scp -P 2222 -i "$SMOKE_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes \
        "root@127.0.0.1:$1" "$2"
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

archmage_info "starting QEMU ($ACCEL_RESOLVED, virtio GPU, timeout ${TIMEOUT}s) — serial: $SERIAL_LOG"
# -vga virtio: a virtual GPU the guest DRM stack drives (wlroots DRM backend
# + pixman renderer render into it; grim reads it) — no host window
# (-display none via -nographic). QEMU 11 packaging: the PCI model is
# virtio-vga (the Arch hw module package qemu-hw-display-virtio-gpu provides
# it; the self-wrap install above includes it). 4 GiB / 4 vcpus: the phosh
# session plus (Task 3) chromium and both Qt stacks need more than the
# smoke's 2 GiB.
qemu-system-x86_64 \
    -M q35 -cpu "$QEMU_CPU" -m 4096 -smp 4 \
    -accel "$ACCEL_RESOLVED" \
    -kernel "$X86_64_DIR/vmlinuz-linux" \
    -initrd "$X86_64_DIR/initramfs-linux.img" \
    -append "root=/dev/vda2 rw console=ttyS0" \
    -drive file="$X86_64_DIR/rootfs.img",if=virtio,format=raw \
    -netdev user,id=n0,hostfwd="$(archmage::hostfwd_tcp 2222)" \
    -device virtio-net-pci,netdev=n0 \
    -vga virtio \
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

# --- Session bring-up + assertion set ---------------------------------------
# The phosh session unit is deliberately NOT enabled at boot: the first SSH
# login empties /run/user/0 (user-runtime-dir tmpfiles D rule), which would
# orphan a boot-time session's env file AND Wayland socket (observed live
# 03-01). The harness starts it here, post-login, per the plan's flow
# (SSH ready → `systemctl start phosh`). loginctl enable-linger root (in the
# image) keeps /run/user/0 alive across this harness's short-lived SSH
# connections — without it the runtime dir is torn down whenever the last
# SSH session closes, killing the socket mid-run (also observed live).
# Before the start: drop a stale failed unit state and any stray fcitx5 from
# an earlier session on the same boot, and mask the squeekboard/OSK0
# activation path so fcitx5 is the only possible input-method client
# (tracer-phase contract; the root user manager exists thanks to linger).
SESSION_BUDGET=180
vm_ssh "systemctl --user mask mobi.phosh.OSK.service 2>&1 || true; \
        pgrep -a squeekboard || echo squeekboard-not-running; \
        systemctl reset-failed phosh 2>/dev/null || true; \
        pkill -x fcitx5 2>/dev/null || true; \
        systemctl start phosh" \
    > "$RESULT_DIR/osk-mask.log" 2>&1 || true
if ! VMSSH_TIMEOUT=$((TIMEOUT + 60)) vm_ssh "systemctl is-active phosh" \
        > "$RESULT_DIR/phosh-start.log" 2>&1 || \
        ! grep -qx active "$RESULT_DIR/phosh-start.log"; then
    result_assert phosh_session_reachable fail \
        "systemctl start phosh failed — see $(basename "$RESULT_DIR/phosh-start.log")/serial/journal"
    result_finish
    die "phosh session failed to start"
fi

# In-VM working dirs (fixed paths — the remote drivers are heredocs).
R=/root/ime-artifacts
SRC=/root/ime
vm_ssh "mkdir -p '$R' '$SRC/apps'"

# Wait for the session: WAYLAND_DISPLAY socket in /run/user/0.
WAYLAND_DISPLAY=""
i=0
while [ "$i" -lt "$SESSION_BUDGET" ]; do
    WAYLAND_DISPLAY=$(vm_ssh "ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort | tail -1" 2>/dev/null || true)
    [ -n "$WAYLAND_DISPLAY" ] && break
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 5
    i=$((i + 5))
done

SESSION_ENV_FILE=$RESULT_DIR/phosh-session-env.txt
vm_ssh "systemctl is-active phosh; cat /run/user/0/phosh-session.env 2>/dev/null; ls -la /run/user/0 2>/dev/null" \
    > "$SESSION_ENV_FILE" 2>&1 || true

if [ -n "$WAYLAND_DISPLAY" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    result_assert phosh_session_reachable pass \
        "phosh session up: WAYLAND_DISPLAY=$WAYLAND_DISPLAY in /run/user/0 (env: $(basename "$SESSION_ENV_FILE"))"
else
    result_assert phosh_session_reachable fail \
        "phosh session did not become reachable within ${SESSION_BUDGET}s (WAYLAND_DISPLAY socket missing) — see $(basename "$SESSION_ENV_FILE")/serial/journal"
    result_finish
    die "phosh session not reachable"
fi

# Session health: phoc process alive + grim screenshot (the first artifact).
PHOC_PID=$(vm_ssh "pgrep -x phoc | head -1" 2>/dev/null || true)
GRIM_SHOT=$R/phosh-session-reachable.png
if [ -n "$PHOC_PID" ] && vm_ssh "set -a; . /run/user/0/phosh-session.env 2>/dev/null; set +a; export XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY='$WAYLAND_DISPLAY'; grim '$GRIM_SHOT'" >/dev/null 2>&1; then
    vm_scp_from "$GRIM_SHOT" "$RESULT_DIR/phosh-session-reachable.png" >/dev/null 2>&1 || true
    if [ -s "$RESULT_DIR/phosh-session-reachable.png" ]; then
        result_assert phoc_process_and_grim pass \
            "phoc pid $PHOC_PID alive; grim captured the first session screenshot"
    else
        result_assert phoc_process_and_grim fail "phoc pid $PHOC_PID alive but grim screenshot missing (no output?)"
    fi
else
    result_assert phoc_process_and_grim fail \
        "phoc process: '${PHOC_PID:-<none>}' or grim failed — session not usable"
fi

# 1. Clean systemd state (gate) — checked AFTER the session came up so a
#    crashing phosh unit is caught here too.
FAILED_UNITS=$(vm_ssh "systemctl --failed --no-legend" 2>/dev/null || true)
if [ -z "$FAILED_UNITS" ]; then
    result_assert no_failed_units pass "systemctl --failed --no-legend -> empty"
else
    result_assert no_failed_units fail "failed units: ${FAILED_UNITS//$'\n'/; }"
fi

# --- fcitx5 as the ONLY input-method client ----------------------------------
# (the mask + squeekboard check ran pre-session-start; assert on its log)
if grep -q 'squeekboard-not-running' "$RESULT_DIR/osk-mask.log" && \
   ! grep -q 'squeekboard' <(vm_ssh "pgrep -x squeekboard || true" 2>/dev/null || true); then
    result_assert ime_unique_im_client pass \
        "squeekboard not running (mask logged; no process) — fcitx5 is the only input-method client candidate"
else
    result_assert ime_unique_im_client fail \
        "a squeekboard process is running alongside fcitx5 — unique input-method-client violated (see osk-mask.log)"
fi

# Deploy the capture app + write the fcitx5 profile (pinyin group), then
# start fcitx5 in the session.
vm_scp_to "$SRC/apps/gtk-entry-app.py" "$SCRIPT_DIR/apps/gtk-entry-app.py" >/dev/null
vm_ssh "chmod +x '$SRC/apps/gtk-entry-app.py'" >/dev/null 2>&1 || true
vm_ssh 'bash -s' <<'REMOTE' > "$RESULT_DIR/fcitx5-profile.log" 2>&1
mkdir -p /root/.config/fcitx5/conf
cat > /root/.config/fcitx5/profile <<'PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin

[GroupOrder]
0=Default
PROFILE
# Candidate window visibly rendered by the classic UI (spike evidence: the
# popup surface must be visible on screen, not just created on the protocol).
cat > /root/.config/fcitx5/conf/classicui.conf <<'CLASSICUI'
PreeditInApplication=False
Vertical Candidate List=False
CLASSICUI
echo "profile-written"
REMOTE

if ! grep -q 'profile-written' "$RESULT_DIR/fcitx5-profile.log"; then
    result_assert fcitx5_waylandim_healthy fail "could not write the fcitx5 profile in the VM"
    result_finish
    die "fcitx5 profile setup failed"
fi

# Session env file for in-VM processes joining the phosh session.
vm_ssh 'bash -s' <<REMOTE
set -e
WD='$WAYLAND_DISPLAY'
{
    printf 'XDG_RUNTIME_DIR=/run/user/0\n'
    printf 'WAYLAND_DISPLAY=%s\n' "\$WD"
    grep -h 'DBUS_SESSION_BUS_ADDRESS=' /run/user/0/phosh-session.env 2>/dev/null || true
} > /run/user/0/ime-env.sh
chmod 644 /run/user/0/ime-env.sh
echo ime-env-written
REMOTE

# ONE fcitx5 instance for the whole run, started with WAYLAND_DEBUG=1: its
# log doubles as the spike's popup-surface probe (zwp_input_popup_surface_v2
# + the input-method keyboard grab). fcitx5 is NEVER restarted/killed while
# the session lives — phoc 0.57 segfaults when a bound input method is torn
# down (observed live twice), which would take the whole session down.
vm_ssh 'bash -s' <<'REMOTE' > "$RESULT_DIR/fcitx5.log" 2>&1
set -a; . /run/user/0/ime-env.sh; set +a
setsid nohup env WAYLAND_DEBUG=1 fcitx5 -D \
    > /root/ime-artifacts/ime-probe.log 2>&1 < /dev/null &
echo "fcitx5-launch-issued pid=\$!"
REMOTE

# fcitx5 health: process answers fcitx5-remote on the session bus.
FCITX5_UP=no
i=0
while [ "$i" -lt 60 ]; do
    if vm_ssh "set -a; . /run/user/0/ime-env.sh; set +a; fcitx5-remote" >/dev/null 2>&1; then
        FCITX5_UP=yes
        break
    fi
    sleep 3
    i=$((i + 3))
done
FCITX5_PID=$(vm_ssh "pgrep -x fcitx5 | head -1" 2>/dev/null || true)
FCITX5_LOG_TAIL=$(vm_ssh "tail -20 '$R/ime-probe.log' 2>/dev/null" 2>/dev/null || true)
printf '%s\n' "$FCITX5_LOG_TAIL" >> "$RESULT_DIR/fcitx5.log"
GRAB_FAILS=$(printf '%s' "$FCITX5_LOG_TAIL" | grep -ci 'grab.*fail\|failed.*grab' || true)
if [ "$FCITX5_UP" = yes ] && [ -n "$FCITX5_PID" ] && [ "${GRAB_FAILS:-0}" -eq 0 ]; then
    result_assert fcitx5_waylandim_healthy pass \
        "fcitx5 running (pid $FCITX5_PID), answers fcitx5-remote on the session bus, no keyboard-grab failures in its log"
else
    result_assert fcitx5_waylandim_healthy fail \
        "fcitx5 up=$FCITX5_UP pid='${FCITX5_PID:-<none>}' grab-failures=$GRAB_FAILS — see fcitx5.log"
fi

# --- GTK4 app + real pinyin input flow --------------------------------------
APP_LOG_VM=$R/app.log
vm_ssh 'bash -s' <<REMOTE > "$RESULT_DIR/gtk-app-start.log" 2>&1
set -a; . /run/user/0/ime-env.sh; set +a
unset GTK_IM_MODULE
export ARCHMAGE_IME_APP_LOG='$APP_LOG_VM'
export GDK_BACKEND=wayland
cd '$SRC/apps'
setsid nohup python3 ./gtk-entry-app.py --gtk 4 > '$R/gtk-app.out' 2>&1 < /dev/null &
echo "app-launch-issued pid=\$!"
REMOTE

FOCUS=no
i=0
while [ "$i" -lt 45 ]; do
    if vm_ssh "grep -q entry-focus-in '$APP_LOG_VM' 2>/dev/null" 2>/dev/null; then
        FOCUS=yes
        break
    fi
    sleep 3
    i=$((i + 3))
done
vm_scp_from "$APP_LOG_VM" "$RESULT_DIR/app.log" >/dev/null 2>&1 || true
if [ "$FOCUS" = yes ]; then
    result_assert gtk_app_focused pass "GTK4 entry app mapped and the entry holds keyboard focus (app.log: entry-focus-in)"
else
    result_assert gtk_app_focused fail \
        "entry never gained keyboard focus within 45s — see app.log / gtk-app-start.log / screenshots"
fi

# The real input flow: switch fcitx5 to pinyin (VERIFIED — the switch may
# silently not stick if issued before the engine finished loading), then
# type nihao + space.
vm_ssh 'bash -s' <<'REMOTE' > "$RESULT_DIR/wtype-session.log" 2>&1
set -a; . /run/user/0/ime-env.sh; set +a
export GDK_BACKEND=wayland
ok=no
for _ in $(seq 1 15); do
    fcitx5-remote -s pinyin 2>/dev/null || true
    [ "$(fcitx5-remote -n 2>/dev/null)" = pinyin ] && ok=yes && break
    sleep 1
done
echo "im-switch=$ok"
[ "$ok" = yes ] || exit 1
# Candidate window visible during preedit: capture BETWEEN the letters and
# the space selection.
wtype nihao
sleep 2
grim /root/ime-artifacts/ime-candidate-window.png
wtype -k space
sleep 1
grim /root/ime-artifacts/ime-committed.png
echo "typed-nihao-and-space"
REMOTE

if ! grep -q 'im-switch=yes' "$RESULT_DIR/wtype-session.log"; then
    result_assert ime_e2e_chinese_commit fail \
        "fcitx5-remote -s pinyin never took effect — pinyin engine not available (profile/groups broken?)"
    result_finish
    die "pinyin switch failed"
fi

if vm_scp_from "$R/ime-candidate-window.png" "$RESULT_DIR/ime-candidate-window.png" >/dev/null 2>&1 && \
   vm_scp_from "$R/ime-committed.png" "$RESULT_DIR/ime-committed.png" >/dev/null 2>&1; then
    archmage_info "typing-round screenshots captured"
fi

E2E=no
i=0
while [ "$i" -lt 30 ]; do
    if vm_ssh "grep -q '你好' '$APP_LOG_VM' 2>/dev/null" 2>/dev/null; then
        E2E=yes
        break
    fi
    sleep 2
    i=$((i + 2))
done
vm_scp_from "$APP_LOG_VM" "$RESULT_DIR/app.log" >/dev/null 2>&1 || true
# Ground truth from the BUFFER events only (text-changed / activate) — never
# the raw pinyin.
BUFFER_TEXTS=$(jq -r 'select(.event == "text-changed" or .event == "activate") | .text' \
    "$RESULT_DIR/app.log" 2>/dev/null || true)
if [ "$E2E" = yes ] && printf '%s' "$BUFFER_TEXTS" | grep -q '你好' && \
   ! printf '%s' "$BUFFER_TEXTS" | grep -q 'nihao'; then
    LAST=$(printf '%s' "$BUFFER_TEXTS" | tail -1)
    result_assert ime_e2e_chinese_commit pass \
        "wtype nihao+space: fcitx5 committed 「$LAST」 into the GTK4 buffer; raw pinyin never landed in it"
elif [ "$E2E" != yes ]; then
    result_assert ime_e2e_chinese_commit fail \
        "no 「你好」 committed within 30s of typing — pinyin bypassed or IM not intercepting (see app.log/fcitx5.log/screenshots)"
else
    result_assert ime_e2e_chinese_commit fail \
        "「你好」 present but the raw pinyin string leaked into the buffer (IME bypassed): buffer=$(printf '%s' "$BUFFER_TEXTS" | tr '\n' ';' | head -c 200)"
fi

# --- WAYLAND_DEBUG probe: classic UI popup surface (spike evidence) ---------
# fcitx5 runs with WAYLAND_DEBUG=1 for the WHOLE session (see its launch);
# the same log is the spike's popup evidence — no separate fcitx5 restart
# (restarting an input method that phoc has bound segfaults phoc 0.57,
# taking the session down — observed live twice during the tracer).
vm_scp_from "$R/ime-probe.log" "$RESULT_DIR/ime-probe.log" >/dev/null 2>&1 || true
PROBE_HITS=$(grep -c 'zwp_input_popup_surface_v2' "$RESULT_DIR/ime-probe.log" 2>/dev/null || true)
GRAB_HITS=$(grep -c 'zwp_input_method_keyboard_grab_v2\|zwp_input_method_v2' "$RESULT_DIR/ime-probe.log" 2>/dev/null || true)
if [ "${PROBE_HITS:-0}" -gt 0 ] && [ "${GRAB_HITS:-0}" -gt 0 ]; then
    result_assert waylandim_popup_probe pass \
        "WAYLAND_DEBUG log: fcitx5 bound input-method-v2 ($GRAB_HITS protocol lines) and created zwp_input_popup_surface_v2 ($PROBE_HITS lines) under phoc — classic UI popup path"
else
    result_assert waylandim_popup_probe fail \
        "fcitx5 log lacks popup/grab evidence (popup=$PROBE_HITS grab/im=$GRAB_HITS) — classic UI may have degraded (see ime-probe.log)"
fi

# --- Task 3 hook: six-toolkit input matrix (run-matrix.sh) ------------------
# Present from Task 3 onward; each row asserts its own commit ground truth
# and ime-matrix.json lands next to ime.json (smoke artifact convention).
if [ -f "$SCRIPT_DIR/run-matrix.sh" ]; then
    archmage_info "deploying + running the six-way toolkit input matrix"
    vm_scp_to "$SRC/run-matrix.sh" "$SCRIPT_DIR/run-matrix.sh" >/dev/null
    for appfile in "$SCRIPT_DIR"/apps/*.py; do
        vm_scp_to "$SRC/apps/$(basename "$appfile")" "$appfile" >/dev/null
    done
    vm_ssh "chmod +x '$SRC/run-matrix.sh' $SRC/apps/*.py" >/dev/null 2>&1 || true
    if VMSSH_TIMEOUT=$((TIMEOUT + 300)) vm_ssh "bash '$SRC/run-matrix.sh' '$R'" \
            > "$RESULT_DIR/matrix-driver.log" 2>&1; then
        MATRIX_RC=0
    else
        MATRIX_RC=1
    fi
    vm_scp_from "$R/ime-matrix.json" "$RESULT_DIR/ime-matrix.json" >/dev/null 2>&1 || true
    # Pull the per-case logs/screenshots into the artifact dir (best effort).
    # ime-matrix.json already sits next to ime.json (smoke artifact convention).
    vm_ssh "cd '$R' && tar czf matrix-artifacts.tgz matrix-* 2>/dev/null || true" >/dev/null 2>&1 || true
    vm_scp_from "$R/matrix-artifacts.tgz" "$RESULT_DIR/matrix-artifacts.tgz" >/dev/null 2>&1 || true
    if [ -s "$RESULT_DIR/matrix-artifacts.tgz" ]; then
        tar xzf "$RESULT_DIR/matrix-artifacts.tgz" -C "$RESULT_DIR" 2>/dev/null || true
        rm -f "$RESULT_DIR/matrix-artifacts.tgz"
    fi
    MATRIX_ALL=no
    if [ -s "$RESULT_DIR/ime-matrix.json" ]; then
        MATRIX_ALL=$(jq -r 'if (.cases | length) == 6 and ([.cases[].status] | all(. == "pass")) then "yes" else "no" end' \
            "$RESULT_DIR/ime-matrix.json" 2>/dev/null || echo no)
    fi
    if [ "$MATRIX_RC" -eq 0 ] && [ "$MATRIX_ALL" = yes ]; then
        result_assert matrix_all_pass pass "six-way toolkit input matrix all pass (ime-matrix.json)"
    else
        result_assert matrix_all_pass fail \
            "matrix rc=$MATRIX_RC all-pass=$MATRIX_ALL — see ime-matrix.json + matrix-* artifacts"
    fi
fi

# --- Archive the journal, shut down -----------------------------------------
if VMSSH_TIMEOUT=60 vm_ssh "journalctl -b --no-pager" > "$JOURNAL_LOG" 2>/dev/null; then
    archmage_info "journal captured: $JOURNAL_LOG"
else
    archmage_warn "journal capture failed (guest may be degraded) — see serial log"
fi

vm_ssh poweroff >/dev/null 2>&1 || true
WAITED=0
while kill -0 "$QEMU_PID" 2>/dev/null && [ "$WAITED" -lt 60 ]; do
    sleep 3
    WAITED=$((WAITED + 3))
done

result_finish

if [ "$RESULT_STATUS" = pass ]; then
    archmage_info "ime-verify PASS: $RESULT_DIR/ime.json"
    exit 0
fi
archmage_warn "ime-verify FAIL: $RESULT_DIR/ime.json"
exit 1
