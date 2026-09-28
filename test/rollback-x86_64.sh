#!/usr/bin/env bash
# rollback-x86_64.sh — QEMU end-to-end rollback test (03-03; UPDATE-02).
#
#   btrfs dev image (mkrootfs-x86_64.sh, flat subvolume layout)
#   -> OVMF -> GRUB (ESP fallback loader, pure GRUB path — no -kernel
#      direct boot) -> SSH
#   -> snapper root config (NUMBER_LIMIT=5, timeline off; snapshots stay
#      OUTSIDE @ in the @snapshots subvolume mounted at /.snapshots)
#   -> pacman -S sl via snap-pac  -> pre/post snapshots
#   -> pacman -Syu + rm /boot/vmlinuz-linux   (default entry now unbootable)
#   -> grub-mkconfig (grub-btrfs snapshot submenu) -> grub-reboot one-shot
#   -> reboot into the SNAPSHOT: uname -r == the pre-break kernel
#   -> snapper --ambit classic rollback <pre>: RW clone of the booted
#      snapshot becomes the new default, /boot/vmlinuz-linux back in place
#
# This is the QEMU verification tier for UPDATE-02 (PITFALLS 4: QEMU green is
# never device green — the OP6 A/B-slot rollback path is exercised by
# archmage-rollback on real hardware, 33/DEVICE_REQUIRED contract).
#
# KVM-required (Phase 3 convention): without a writable /dev/kvm the script
# prints `KVM_REQUIRED: ...` as the FIRST stderr line and exits 34. The only
# exemption is ARCHMAGE_QEMU_ALLOW_TCG=1 (caller explicitly accepts the long
# TCG runtime and must raise --timeout itself).
#
# One command, self-wrapping: when qemu-system-x86_64 is missing on the host,
# the QEMU phase re-executes itself inside an archlinux container after
# installing qemu-emulators-full + edk2-ovmf there. The rootfs build stage
# runs in its own container via mkrootfs-x86_64.sh.
#
# Usage:
#   bash test/rollback-x86_64.sh [--from-ci | --repo-dir PATH]
#                                [--timeout SECS] [--accel kvm|tcg]
#                                [--rebuild]
#
# Outputs: test/results/<ts>/{rollback.json, serial.log, grub.cfg,
# grub-btrfs.cfg, pacman-sl.log, pacman-syu.log, grub-mkconfig.log,
# snapper-rollback.log, journal.log, OVMF_VARS.fd} and the
# test/results/latest symlink. Exit code 0 iff every GATING assertion passed
# (tier: qemu).

set -euo pipefail

usage() {
    cat <<'EOF'
rollback-x86_64.sh — QEMU end-to-end snapshot rollback test (UPDATE-02)

Usage:
  bash test/rollback-x86_64.sh [options]

Options:
  --from-ci        Pass-through to mkrootfs-x86_64.sh: consume the latest
                   successful main-run staging-repo artifact (default).
  --repo-dir PATH  Pass-through: use a local staging artifact directory.
  --timeout SECS   Per-boot SSH-readiness budget, default 900 (two boots +
                   transactions live inside one run; raise it for TCG).
  --accel MODE     kvm (default; KVM-required per the Phase 3 exit-code
                   contract) | tcg (only honoured with
                   ARCHMAGE_QEMU_ALLOW_TCG=1).
  --rebuild        Force a fresh mkrootfs-x86_64.sh run.
  -h, --help       Show this help.

Environment:
  ARCHMAGE_QEMU_ALLOW_TCG=1   Exemption switch for the KVM_REQUIRED guard
                              (exit 34): accept the slow TCG emulation.
  ARCHMAGE_GH_REPO            GitHub <owner>/<repo> for --from-ci.

Internal:
  --in-container   Re-execution flag set inside the self-wrapped QEMU
                   container; never pass it manually.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

TIMEOUT=900
MODE=""
REPO_DIR_ARG=""
REBUILD=no
ACCEL=""
INNER=no
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
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# --------------------------------------------------------------------------
# KVM guard (Phase 3 exit-code contract) — runs in the HOST phase before the
# rootfs build AND again in the self-wrapped container phase, so the very
# first stderr line is KVM_REQUIRED whenever KVM is genuinely unavailable.
# --------------------------------------------------------------------------
if ! archmage::kvm_available && [ "${ARCHMAGE_QEMU_ALLOW_TCG:-}" != "1" ]; then
    printf 'KVM_REQUIRED: rollback-x86_64.sh needs KVM-accelerated QEMU but /dev/kvm is not accessible (missing, or not passed into the container).\n'
    printf 'KVM_REQUIRED: enable KVM on the host (load the kvm module, ensure your user can write /dev/kvm) and pass --device /dev/kvm when containerized; or re-run with ARCHMAGE_QEMU_ALLOW_TCG=1 and a larger --timeout to accept the slow TCG emulation.\n'
    exit 34
fi

REPO_ROOT=$(archmage::repo_root)
X86_64_DIR=$REPO_ROOT/test/build/x86_64
RESULTS_ROOT=$REPO_ROOT/test/results
SMOKE_KEY=$X86_64_DIR/smoke_key

artifacts_present() {
    [ -s "$X86_64_DIR/rootfs.img" ] &&
        [ -f "$SMOKE_KEY" ]
}

# --------------------------------------------------------------------------
# Host phase: build rootfs if needed; self-wrap when qemu/ovmf are missing.
# --------------------------------------------------------------------------
if [ "$INNER" = no ]; then
    # ALWAYS build a fresh image: reuse is unsound for THIS test by
    # construction. GRUB's embedded prefix is (hd0,gpt2)/@/boot/grub —
    # toplevel-relative and pinned to the @ subvolume — so every boot is
    # driven by @'s /boot/grub/grub.cfg, while a completed rollback replaces
    # the DEFAULT subvolume with a snapshot clone and leaves @ broken
    # (vmlinuz deleted) with a polluted grub.cfg (this run's appended one-shot
    # + set default). A reused image boots the STALE one-shot entry into an
    # old read-only snapshot (observed live: reused run booted snapshot 1 RO,
    # every write EROFS'd, grub-mkconfig failed, case died in the menu-parse
    # step). The smoke test keeps its artifacts-present reuse (it boots the
    # default subvolume via root=/dev/vda2 without touching the boot path);
    # the rollback case does not. (--rebuild is accepted and implied.)
    archmage_info "building the btrfs dev image first (mkrootfs-x86_64.sh)"
    MKROOTFS_ARGS=()
    if [ "$MODE" = dir ]; then
        MKROOTFS_ARGS+=(--repo-dir "$REPO_DIR_ARG")
    else
        MKROOTFS_ARGS+=(--from-ci)
    fi
    bash "$SCRIPT_DIR/mkrootfs-x86_64.sh" "${MKROOTFS_ARGS[@]}"

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1 ||
        [ ! -f /usr/share/edk2/x64/OVMF_CODE.4m.fd ]; then
        archmage_info "qemu/ovmf missing on host — self-wrapping the QEMU phase in an archlinux container (qemu-emulators-full + edk2-ovmf)"
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
            "pacman -Sy --noconfirm qemu-emulators-full edk2-ovmf openssh jq >/dev/null 2>&1 && bash test/rollback-x86_64.sh $INNER_CMD"
        RC=$?
        set -e
        exit "$RC"
    fi
fi

# --------------------------------------------------------------------------
# QEMU phase (native host with qemu+ovmf, or inside the self-wrapped
# container). Pure GRUB path: OVMF pflash (read-only CODE + per-run writable
# VARS copy), disk on virtio; the ESP fallback loader \EFI\BOOT\BOOTX64.EFI
# (grub-install --removable --no-nvram) is what OVMF finds without NVRAM
# entries.
# --------------------------------------------------------------------------
archmage::require_cmd qemu-system-x86_64 jq ssh

OVMF_CODE=""
OVMF_VARS_TPL=""
for pair in \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd; do
    if [ -f "${pair%%:*}" ] && [ -f "${pair##*:}" ]; then
        OVMF_CODE=${pair%%:*}
        OVMF_VARS_TPL=${pair##*:}
        break
    fi
done
[ -n "$OVMF_CODE" ] || die "no OVMF firmware found (install edk2-ovmf)"

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

# 127.0.0.1:2222 must be free (T-01-06: hostfwd is loopback-only).
if (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null; then
    die "127.0.0.1:2222 is already in use — is a stale QEMU instance running? Kill it and re-run."
fi

# shellcheck source=lib/result.sh
source "$SCRIPT_DIR/lib/result.sh"
result_begin archmage-qemu-x86_64-rollback x86_64 "$ACCEL_RESOLVED" "$RESULTS_ROOT" rollback.json
result_set_tier qemu
SERIAL_LOG=$RESULT_DIR/serial.log
JOURNAL_LOG=$RESULT_DIR/journal.log
PID_FILE=$RESULT_DIR/qemu.pid
VARS_FD=$RESULT_DIR/OVMF_VARS.fd
cp "$OVMF_VARS_TPL" "$VARS_FD"
QEMU_PID=""

# SSH into the guest (user-mode NAT, loopback-only forward).
# Rapid sequential connections can trip the guest's sshd MaxStartups
# (observed live: kex_exchange_identification reset right before the
# one-shot reboot) — retry transient failures before giving up.
vm_ssh() {
    local secs=${VMSSH_TIMEOUT:-60}
    local rc=0 attempt
    for attempt in 1 2 3; do
        if timeout "$secs" ssh -p 2222 -i "$SMOKE_KEY" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes \
            root@127.0.0.1 "$@"; then
            return 0
        fi
        rc=$?
        sleep 3
    done
    return "$rc"
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

# Wait for SSH readiness within the budget; records boot_seconds on success.
wait_ssh_ready() {
    SECONDS=0
    while :; do
        if vm_ssh true >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            return 1
        fi
        if [ "$SECONDS" -ge "$TIMEOUT" ]; then
            return 2
        fi
        sleep 5
    done
}

archmage_info "starting QEMU (pure GRUB path: OVMF pflash, $ACCEL_RESOLVED, timeout ${TIMEOUT}s) — serial: $SERIAL_LOG"
qemu-system-x86_64 \
    -M q35 -cpu "$QEMU_CPU" -m 2048 -smp 2 \
    -accel "$ACCEL_RESOLVED" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS_FD" \
    -drive file="$X86_64_DIR/rootfs.img",if=virtio,format=raw \
    -netdev user,id=n0,hostfwd="$(archmage::hostfwd_tcp 2222)" \
    -device virtio-net-pci,netdev=n0 \
    -nographic -monitor none \
    -serial "file:$SERIAL_LOG" \
    -pidfile "$PID_FILE" \
    </dev/null >>"$RESULT_DIR/console.log" 2>&1 &
QEMU_PID=$!

# --- 1) grub_boot_pass: OVMF -> ESP fallback -> GRUB default entry (@) ------
if wait_ssh_ready; then
    result_assert grub_boot_pass pass \
        "GRUB default entry booted the btrfs @ root; SSH ready at 127.0.0.1:2222 after ${SECONDS}s"
    result_set_boot_seconds "$SECONDS"
else
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        result_assert grub_boot_pass fail "SSH not ready within ${TIMEOUT}s after GRUB boot"
    else
        result_assert grub_boot_pass fail "QEMU exited before SSH became ready — see $(basename "$SERIAL_LOG") and console.log in the result dir"
    fi
    result_finish
    die "first boot failed (see $SERIAL_LOG / $RESULT_DIR/console.log)"
fi

K1=$(vm_ssh "uname -r")
DEFAULT_ID_BEFORE=$(vm_ssh "btrfs subvolume get-default /" | awk '{print $2; exit}')
archmage_info "pre-break kernel K1=$K1, default subvolume id=$DEFAULT_ID_BEFORE"

# --- 2) snapper root config on the pre-mounted /.snapshots (@snapshots) -----
# snapper create-config refuses when /.snapshots already exists (it wants to
# create its own subvol INSIDE @ — which would violate the layout invariant
# "snapshots live outside @": a rollback that replaces @ must not take the
# snapshot store with it). The documented dance (snapper list workaround,
# Arch BBS 290007): let snapper create its subvol, delete it, remount OUR
# @snapshots subvolume at the same path — snapper then writes snapshots into
# the mounted store outside @.
SNAP_DANCE_LOG=$RESULT_DIR/snapper-config.log
# Idempotent: a previously interrupted run may already have created the
# config (the failed run's writes live on in the image) — only run the
# create/delete dance when /etc/snapper/configs/root is absent.
if VMSSH_TIMEOUT=120 vm_ssh '
    set -e
    if [ ! -e /etc/snapper/configs/root ]; then
        umount /.snapshots
        rmdir /.snapshots
        snapper -c root create-config /
        btrfs subvolume delete /.snapshots
        mkdir /.snapshots
    fi
    mountpoint -q /.snapshots || mount /.snapshots
    snapper -c root set-config NUMBER_LIMIT=5 NUMBER_LIMIT_IMPORTANT=5 TIMELINE_CREATE=no
    # snapper writes config values QUOTED (NUMBER_LIMIT="5") — accept both
    # the quoted and the bare form (a strict ^NUMBER_LIMIT=5$ never matches,
    # observed live: the dance itself succeeded, the assertion grep failed).
    grep -Eq "^NUMBER_LIMIT=\"?5\"?$" /etc/snapper/configs/root
    grep -Eq "^NUMBER_LIMIT_IMPORTANT=\"?5\"?$" /etc/snapper/configs/root
    grep -Eq "^TIMELINE_CREATE=\"?no\"?$" /etc/snapper/configs/root
' >"$SNAP_DANCE_LOG" 2>&1; then
    archmage_info "snapper root config ready (NUMBER_LIMIT=5, timeline off, snapshots in @snapshots)"
else
    result_assert snapshot_created fail \
        "snapper config dance failed — see $(basename "$SNAP_DANCE_LOG")"
    result_finish
    die "snapper config creation failed (see $SNAP_DANCE_LOG)"
fi

snapper_count() {
    vm_ssh "snapper -c root list" 2>/dev/null |
        sed 's/|/ /g' | grep -c '^[[:space:]]*[0-9]\+' || true
}
COUNT_BEFORE=$(snapper_count)

# --- 3) snapshot_created: pacman transaction -> snap-pac pre/post snapshots -
PACMAN_SL_LOG=$RESULT_DIR/pacman-sl.log
if VMSSH_TIMEOUT=$((TIMEOUT + 60)) vm_ssh "pacman -S --noconfirm sl" \
        >>"$PACMAN_SL_LOG" 2>&1; then
    COUNT_AFTER=$(snapper_count)
    if [ "${COUNT_AFTER:-0}" -gt "${COUNT_BEFORE:-0}" ]; then
        result_assert snapshot_created pass \
            "snap-pac raised snapper snapshots ${COUNT_BEFORE} -> ${COUNT_AFTER} for 'pacman -S sl'; config has NUMBER_LIMIT=5 / NUMBER_LIMIT_IMPORTANT=5 / TIMELINE_CREATE=no"
    else
        result_assert snapshot_created fail \
            "snapshot count did not grow (${COUNT_BEFORE} -> ${COUNT_AFTER}) — snap-pac hooks not firing?"
    fi
else
    result_assert snapshot_created fail \
        "pacman -S sl failed — see $(basename "$PACMAN_SL_LOG")"
fi

# --- 4) break the system: -Syu (+ record the new kernel if it changed), then
#        remove /boot/vmlinuz-linux so the DEFAULT entry cannot boot --------
PACMAN_SYU_LOG=$RESULT_DIR/pacman-syu.log
KERNEL_CHANGED=no
K2=""
if VMSSH_TIMEOUT=$((TIMEOUT + 120)) vm_ssh "pacman -Syu --noconfirm" \
        >>"$PACMAN_SYU_LOG" 2>&1; then
    K2=$(vm_ssh "uname -r" || true)
    if [ -n "$K2" ] && [ "$K2" != "$K1" ]; then
        KERNEL_CHANGED=yes
        archmage_info "kernel changed by -Syu: K1=$K1 -> K2=$K2"
    fi
else
    archmage_warn "pacman -Syu failed (continuing: the rm below still breaks the default entry) — see $(basename "$PACMAN_SYU_LOG")"
fi
vm_ssh "rm -f /boot/vmlinuz-linux"
VMLINUZ_GONE=$(vm_ssh "test ! -e /boot/vmlinuz-linux && echo yes || echo no")
result_assert kernel_broken_informational "$([ "$VMLINUZ_GONE" = yes ] && echo pass || echo fail)" \
    "informational: /boot/vmlinuz-linux removed (default entry unbootable); K1=$K1; K2=${K2:-<no -Syu kernel change>}" \
    informational

# --- 5) regenerate grub.cfg + the grub-btrfs snapshot menu, then one-shot
#        into the target snapshot (the pre-Syu snapshot: kernel K1 intact) ---
# NOTE (observed live): on Arch, grub-mkconfig only writes a CONDITIONAL STUB
# into grub.cfg (`if [ ! -e grub-btrfs.cfg ]; then ... else submenu ...`) —
# the actual snapshot menuentries are generated into the SEPARATE
# /boot/grub/grub-btrfs.cfg by the packaged /etc/grub.d/41_snapshots-btrfs
# script (what grub-btrfsd calls on every snapshot event). Parsing grub.cfg
# alone therefore finds no snapshot entry. Sequence:
#   grub-mkconfig            -> fresh grub.cfg incl. the conditional stub
#   touch grub-btrfs.cfg     -> keeps the standalone 41 script from appending
#                               a DUPLICATE unconditional submenu block (the
#                               stub already provides it)
#   /etc/grub.d/41_snapshots-btrfs -> fills grub-btrfs.cfg with the entries
#
# ONE-SHOT MECHANISM (deviation from the plan's literal "grub-reboot the
# snapshot-submenu entry" step; Rule 3 blocking fix, observed live twice on
# grub 2:2.16-1): grub.cfg hosts the snapshots as `submenu 'Arch Linux
# snapshots' { configfile .../grub-btrfs.cfg }`. A one-shot menu path —
# title-based AND numeric — is resolved against the menu PARSE tree, and a
# configfile-loaded submenu is not part of it: both forms descend exactly one
# level, enter the snapshots submenu and WAIT FOREVER instead of booting the
# entry (serial.log artifact: submenu displayed, no countdown, SSH never
# comes up). The plan's intent — parse the target snapshot entry and
# grub-reboot into it — is preserved by re-hosting the PARSED entry at the
# TOP level: the entry's search/linux/initrd lines are extracted verbatim
# from grub-btrfs.cfg, appended to grub.cfg as a temporary menuentry with a
# stable ID, and `grub-reboot <id>` boots it (single-level, ID-based — the
# one GRUB one-shot form with no configfile boundary to cross). The append
# is self-cleaning: this run's earlier grub-mkconfig regenerates grub.cfg on
# the next run, so no residue accumulates.
#
# GRUBENV CAVEAT (observed live, third failure mode): grub-reboot persists
# next_entry via grub-editenv into /boot/grub/grubenv — a file the image
# build NEVER creates (grub-install on btrfs /boot does not lay down a
# grubenv; the unpacked tree proves it). grub-editenv auto-creates the file
# and exits 0, but the boot-time `if [ -s $prefix/grubenv ]; then load_env`
# then has to find a file CREATED AFTER grub-install — and in the observed
# run the menu still highlighted entry 0 ("UEFI Firmware Settings", which is
# what entry 0 becomes once 10_linux emitted nothing after
# rm /boot/vmlinuz-linux) and dropped into the OVMF firmware menu: SSH never
# came back. The load-bearing selection is therefore the appended
# `set default="<id>"` BELOW: grub.cfg executes top-to-bottom BEFORE the menu
# displays, so the LAST `set default` assignment wins — string ids are
# resolved against the fully parsed menu exactly like next_entry/saved_entry
# are, but with NO grubenv, NO load_env and NO next_entry on the path.
# grub-reboot is kept for plan fidelity (and works whenever the grubenv
# round-trip does); the appended assignment is what guarantees the boot.
GRUB_MKCONFIG_LOG=$RESULT_DIR/grub-mkconfig.log
TARGET=""
ONE_SHOT=""
if VMSSH_TIMEOUT=300 vm_ssh '
    set -e
    grub-mkconfig -o /boot/grub/grub.cfg
    # Same default-subvol contract as the image build (mkrootfs step 6e):
    # vanilla 10_linux pins rootflags=subvol=<subvol> on btrfs; the fstab
    # (and snapper rollback semantics) need the kernel to mount the DEFAULT
    # subvolume. grub-btrfs snapshot entries carry subvol= INSIDE their
    # rootflags=rw,... value — the exact space-prefixed token never hits them.
    sed -i "s/ rootflags=subvol=[^ ]*//g" /boot/grub/grub.cfg
    touch /boot/grub/grub-btrfs.cfg
    /etc/grub.d/41_snapshots-btrfs
    test -s /boot/grub/grub-btrfs.cfg
' >"$GRUB_MKCONFIG_LOG" 2>&1; then
    # Locate the target snapshot: the highest-numbered 'pre' snapshot (the
    # Syu transaction's pre snapshot when -Syu actually transacted, else the
    # sl install's pre) — all of them carry the pre-break kernel K1.
    TARGET=$(vm_ssh "snapper -c root list" 2>/dev/null |
        sed 's/|/ /g' | awk '$1 ~ /^[0-9]+$/ && $2 == "pre" { n = $1 } END { print n + 0 }')
    vm_ssh "cat /boot/grub/grub.cfg" > "$RESULT_DIR/grub.cfg" 2>/dev/null || true
    vm_ssh "cat /boot/grub/grub-btrfs.cfg" > "$RESULT_DIR/grub-btrfs.cfg" 2>/dev/null || true
    SNAP_CFG=$RESULT_DIR/grub-btrfs.cfg
    [ -s "$SNAP_CFG" ] || SNAP_CFG=$RESULT_DIR/grub.cfg
    if [ "${TARGET:-0}" -gt 0 ] && [ -s "$SNAP_CFG" ]; then
        # The target entry's boot lines, verbatim from the grub-btrfs.cfg
        # block for @snapshots/<TARGET>/snapshot: search sets $root to the
        # btrfs filesystem, linux/initrd reference the kernel INSIDE the
        # snapshot subvolume (rootflags=...,subvol="@snapshots/N/snapshot").
        awk -v target="$TARGET" '
            /^[ \t]*submenu[ \t]/ {
                if (in_blk) { next }
                if ($0 ~ ("@snapshots/" target "/snapshot")) { in_blk = 1 }
                next
            }
            in_blk && /^[ \t]*}[ \t]*$/ { in_blk = 0; next }
            in_blk && /^[ \t]*(search|linux|initrd)[ \t]/ {
                if ($1 == "search") search_line = $0
                else if ($1 == "linux") linux_line = $0
                else if ($1 == "initrd") initrd_line = $0
            }
            END {
                if (search_line != "" && linux_line != "" && initrd_line != "")
                    print search_line "\n" linux_line "\n" initrd_line
            }
        ' "$SNAP_CFG" > "$RESULT_DIR/oneshot-lines.txt"
        if [ -s "$RESULT_DIR/oneshot-lines.txt" ]; then
            ONESHOT_ID=archmage-oneshot-snap-$TARGET
            ONESHOT_FILE=$RESULT_DIR/oneshot-entry.cfg
            {
                printf "menuentry 'ArchMage rollback one-shot: boot snapshot %s' \$menuentry_id_option '%s' {\n" \
                    "$TARGET" "$ONESHOT_ID"
                sed 's/^/    /' "$RESULT_DIR/oneshot-lines.txt"
                printf '}\n'
                # The load-bearing selection (see the GRUBENV CAVEAT above):
                # grub.cfg is fully executed before the menu renders, so this
                # trailing assignment overrides whatever default the 00_header
                # block (next_entry / saved_entry) established earlier.
                printf "set default='%s'\n" "$ONESHOT_ID"
            } > "$ONESHOT_FILE"
            # Append the temporary top-level entry (over ssh stdin). The
            # grub.cfg of the ROLLED-BACK default predates this append, and
            # the next run's grub-mkconfig rewrites it anyway — no residue.
            if vm_ssh "cat >> /boot/grub/grub.cfg" < "$ONESHOT_FILE"; then
                ONE_SHOT=$ONESHOT_ID
            else
                archmage_warn "appending the one-shot entry to grub.cfg failed"
            fi
        else
            archmage_warn "could not extract the boot lines of snapshot $TARGET from grub-btrfs.cfg"
        fi
    fi
else
    archmage_warn "grub-mkconfig / 41_snapshots-btrfs failed — snapshot submenu will be missing"
fi

if [ -z "$ONE_SHOT" ]; then
    result_assert rollback_boot_old_kernel fail \
        "could not resolve a grub-btrfs snapshot entry for snapshot ${TARGET:-<?>} in the regenerated snapshot menu (copies: $(basename "$RESULT_DIR")/grub-btrfs.cfg, grub.cfg)"
    result_finish
    die "grub.cfg snapshot entry parsing failed"
fi
archmage_info "one-shot boot target: snapshot $TARGET -> top-level entry '$ONE_SHOT'"
# Plan-literal grub-reboot on top (harmless: the appended set default below
# in grub.cfg is what the boot actually honors — see GRUBENV CAVEAT).
# shellcheck disable=SC2016
vm_ssh "[ -f /boot/grub/grubenv ] || grub-editenv /boot/grub/grubenv create; grub-reboot $(printf '%q' "$ONE_SHOT")"

# --- 6) rollback_boot_old_kernel: reboot into the snapshot ------------------
vm_ssh "reboot" >/dev/null 2>&1 || true
if wait_ssh_ready; then
    # The read-only snapshot root settles SLOWLY: systemd jobs on the RO
    # root (remount-fs, fstab satellite mounts) time out for a while after
    # sshd is already answering — probes in that window hit
    # "Connection timed out during banner exchange" (observed live). Wait
    # for systemd to reach its steady state (running or degraded) before
    # asserting.
    BOOT_STATE=""
    for _ in $(seq 1 60); do
        BOOT_STATE=$(VMSSH_TIMEOUT=60 vm_ssh "systemctl is-system-running 2>/dev/null" | head -1)
        case "$BOOT_STATE" in
            running|degraded) break ;;
        esac
        sleep 5
    done
    K1B=""
    # uname under the settling RO snapshot root can lose sessions to the same
    # banner-exchange stalls the loop above rides out (observed live: an
    # empty capture flipped the assertion while the system was fine) — retry
    # until a non-empty capture or a bounded budget is spent.
    for _ in $(seq 1 6); do
        K1B=$(VMSSH_TIMEOUT=120 vm_ssh "uname -r" 2>/dev/null | head -1)
        [ -n "$K1B" ] && break
        sleep 5
    done
    if [ "$K1B" = "$K1" ] && { [ "$KERNEL_CHANGED" = no ] || [ "$K1B" != "$K2" ]; }; then
        result_assert rollback_boot_old_kernel pass \
            "snapshot boot: uname -r = $K1B == pre-break K1 (snapshot $TARGET, one-shot '$ONE_SHOT'); boot state: ${BOOT_STATE:-<unknown>}; K2=${K2:-<unchanged>} differs as required"
    else
        result_assert rollback_boot_old_kernel fail \
            "snapshot boot kernel mismatch: booted $K1B, pre-break K1=$K1, post-Syu K2=${K2:-<unchanged>} (one-shot '$ONE_SHOT', boot state: ${BOOT_STATE:-<unknown>})"
    fi
else
    result_assert rollback_boot_old_kernel fail \
        "snapshot boot did not reach SSH within ${TIMEOUT}s — see $(basename "$SERIAL_LOG")"
fi

# --- 7) rollback_restores: snapper rollback -> new default has the kernel ---
# ROLLBACK AMBIT (Rule 3 blocking fixes, observed live twice): the running
# system IS the booted read-only snapshot, and the plan's literal
# `snapper -c root rollback <pre-N>` form fails here:
#   1. auto ambit detection dies with "Cannot detect ambit since default
#      subvolume is unknown" — snapper's detector expects the openSUSE
#      layout where .snapshots lives INSIDE the default subvolume; ours is
#      the pmbootstrap sibling layout (@snapshots next to @). snapper's own
#      error message prescribes the --ambit escape hatch.
#   2. snapper 0.13's valid ambit values are auto|classic|transactional
#      (a --ambit snapshot form does not exist — "Invalid ambit 'snapshot'",
#      observed live).
# The documented operation (openSUSE forums/man) while booted from a
# snapshot is the number form in the classic ambit: a read-only snapshot of
# the current (booted) system is preserved, a read-write clone of TARGET is
# created and set as the new default — exactly the plan's "恢复步骤把快照
# 变成新默认" (man: "With a number: a first read-only snapshot of the
# current system is created. A second read-write snapshot is created of
# number. The system is set to boot from the second snapshot.").
ROLLBACK_LOG=$RESULT_DIR/snapper-rollback.log
ROLLBACK_RC=0
VMSSH_TIMEOUT=300 vm_ssh "snapper -c root --ambit classic rollback $TARGET" \
    >"$ROLLBACK_LOG" 2>&1 || ROLLBACK_RC=$?
DEFAULT_ID_AFTER=""
VMLINUZ_RESTORED=no
if [ "$ROLLBACK_RC" -eq 0 ]; then
    # The rollback churns the btrfs tree while the system still runs from
    # the read-only snapshot; probes right after it can hit the same SSH
    # flakiness the settle loop above rides out — retry for a stable read.
    for _ in $(seq 1 12); do
        DEFAULT_ID_AFTER=$(VMSSH_TIMEOUT=120 vm_ssh "btrfs subvolume get-default /" 2>/dev/null | awk '{print $2; exit}')
        [ -n "$DEFAULT_ID_AFTER" ] && break
        sleep 5
    done
    if [ -n "$DEFAULT_ID_AFTER" ] && [ "$DEFAULT_ID_AFTER" != "$DEFAULT_ID_BEFORE" ]; then
        # The restored default's kernel is back: mount the new default
        # subvolume by id and stat the kernel file (the running system is
        # still the read-only snapshot — the strong boot-level proof that the
        # restored default boots the pre-break kernel is exactly what the
        # snapshot boot above demonstrated: same subvolume content).
        # The mountpoint must be tmpfs: mkdir on the RO snapshot root fails
        # (observed live: /mnt2 mkdir EROFS -> "mount-failed"); /dev/shm is
        # systemd-guaranteed tmpfs.
        VMLINUZ_RESTORED=$(vm_ssh "
            mkdir -p /dev/shm/archmage-verify
            if mount -o subvolid=$DEFAULT_ID_AFTER /dev/vda2 /dev/shm/archmage-verify 2>/dev/null; then
                test -e /dev/shm/archmage-verify/boot/vmlinuz-linux && echo yes || echo no
                umount /dev/shm/archmage-verify
            else
                echo mount-failed
            fi
            rmdir /dev/shm/archmage-verify" 2>/dev/null || echo mount-failed)
    fi
fi
if [ "$ROLLBACK_RC" -eq 0 ] && [ -n "$DEFAULT_ID_AFTER" ] && \
    [ "$DEFAULT_ID_AFTER" != "$DEFAULT_ID_BEFORE" ] && [ "$VMLINUZ_RESTORED" = yes ]; then
    result_assert rollback_restores pass \
        "snapper rollback $TARGET ok: default subvolume id $DEFAULT_ID_BEFORE -> $DEFAULT_ID_AFTER, /boot/vmlinuz-linux back in place in the restored default (log: $(basename "$ROLLBACK_LOG"))"
else
    result_assert rollback_restores fail \
        "rollback rc=$ROLLBACK_RC, default id ${DEFAULT_ID_BEFORE}->${DEFAULT_ID_AFTER:-<none>}, vmlinuz check: $VMLINUZ_RESTORED — see $(basename "$ROLLBACK_LOG")"
fi

# Archive the snapshot-boot journal before shutdown (triage artifact).
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
    archmage_info "rollback PASS: $RESULT_DIR/rollback.json"
    exit 0
fi
archmage_warn "rollback FAIL: $RESULT_DIR/rollback.json"
exit 1
