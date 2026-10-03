#!/usr/bin/env bash
# waydroid-verify.sh — waydroid container smoke in the KVM dev image (03-02;
# APPS-01 machine face: binder -> init -> session RUNNING end to end).
#
#   btrfs dev image (mkrootfs-x86_64.sh, waydroid stack + phosh session unit)
#   -> QEMU (KVM, virtio-gpu, -display none) -> SSH
#   -> binder face: /proc/config.gz binder config + binderfs mount (the
#      03-RESEARCH "Arch kernel rust_binder makes the QEMU smoke viable"
#      conclusion, re-proven on the running kernel)
#   -> Android image cache (host-side, one-time OTA fetch into
#      test/build/waydroid-cache/; ARCHMAGE_WAYDROID_MIRROR overrides the
#      OTA base; ARCHMAGE_WAYDROID_IMAGE_DIR points at a manual offline
#      dir; cache hit skips every download) -> seeded into the VM at
#      /etc/waydroid-extra/images (waydroid's own preinstalled-images
#      path: init short-circuits the OTA and disables the updater —
#      source-verified against waydroid 1.5.4 tools/actions/initializer.py)
#   -> waydroid init (data under /var/lib/waydroid = the @var nodatacow
#      subvolume, wave 1 layout, PITFALLS 6)
#   -> phosh session (03-01's dev-image unit) -> waydroid session start in
#      that session env -> poll waydroid status to Session: RUNNING
#
# Modeled on test/ime/ime-verify.sh: self-wrapping container, --repo-dir /
# --from-ci pass-through, structured JSON (waydroid.json, tier=qemu-kvm) +
# artifacts under test/results/<ts>/, cleanup leaves no QEMU/SSH residue.
# The image is rebuilt whenever mkrootfs-x86_64.sh or the consumed staging
# artifact changed (stamp file) — the waydroid stack lives IN the image.
#
# KVM-required (Phase 3 exit-code contract): without a writable /dev/kvm the
# script prints `KVM_REQUIRED: ...` as the FIRST stderr line and exits 34.
# The only exemption is ARCHMAGE_QEMU_ALLOW_TCG=1 (caller explicitly accepts
# the long TCG runtime and must raise --timeout itself).
#
# Rendering adaptation (plan-authorized): the session unit renders with
# pixman (03-01's proven form). If waydroid's Android-side hwcomposer needs
# a GL-capable compositor surface, the harness retries the session once with
# a software-GL compositor (WLR_RENDERER=gles2 + WLR_RENDERER_ALLOW_SOFTWARE=1
# + LIBGL_ALWAYS_SOFTWARE=1 via /etc/default/phosh-dev-session — the unit's
# EnvironmentFile hook; wlroots refuses a software GLES2 renderer without
# the ALLOW_SOFTWARE opt-in, observed live 03-02). The renderer choice is
# recorded in the result details; Session: RUNNING is the
# hard assertion either way (show-full-ui visual checks are out of scope).
#
# Usage:
#   bash test/waydroid/waydroid-verify.sh [--from-ci | --repo-dir PATH]
#                                        [--timeout SECS] [--accel kvm|tcg]
#                                        [--rebuild]
#
# Outputs: test/results/<ts>/{waydroid.json, serial.log, journal.log,
# console.log, waydroid-init.log, waydroid-session.log, waydroid-status.log,
# binderfs-listing.log, image-source.json, qemu.pid} and the
# test/results/latest symlink. Exit code 0 iff every GATING assertion passed
# (tier: qemu-kvm; TCG only via the exemption).

set -euo pipefail

usage() {
    cat <<'EOF'
waydroid-verify.sh — waydroid container smoke (QEMU, KVM-required)

Usage:
  bash test/waydroid/waydroid-verify.sh [options]

Options:
  --from-ci        Pass-through to mkrootfs-x86_64.sh: consume the latest
                   successful main-run staging-repo artifact (default).
  --repo-dir PATH  Pass-through: use a local staging artifact directory.
  --timeout SECS   SSH-readiness budget, default 2400 (OTA image download
                   on first run happens BEFORE boot; this budget covers
                   the VM boot only).
  --accel MODE     kvm (default; KVM-required per the Phase 3 exit-code
                   contract) | tcg (only honoured with
                   ARCHMAGE_QEMU_ALLOW_TCG=1).
  --rebuild        Force a fresh mkrootfs-x86_64.sh run (default: rebuild
                   when the mkrootfs script or staging artifact changed).
  -h, --help       Show this help.

Environment:
  ARCHMAGE_QEMU_ALLOW_TCG=1     Exemption switch for the KVM_REQUIRED
                                guard (exit 34): accept slow TCG emulation.
  ARCHMAGE_WAYDROID_MIRROR      Base URL of an OTA-compatible mirror
                                (replaces https://ota.waydro.id). The
                                mirror must serve the same JSON layout:
                                <mirror>/system/lineage/waydroid_<arch>/
                                VANILLA.json and <mirror>/vendor/
                                waydroid_<arch>/MAINLINE.json (research A5
                                offline-mirror plan).
  ARCHMAGE_WAYDROID_IMAGE_DIR   Directory holding a MANUAL pre-fetched
                                offline image set (system.img + vendor.img,
                                as extracted from the OTA zips). Takes
                                precedence over the cache and OTA; README
                                documents the manual acquisition path.

Internal:
  --in-container   Re-execution flag set inside the self-wrapped QEMU
                   container; never pass it manually.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

TIMEOUT=2400
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
    printf 'KVM_REQUIRED: waydroid-verify.sh boots Android in an lxc container inside the dev VM and needs KVM-accelerated QEMU, but /dev/kvm is not accessible (missing, or not passed into the container).\n'
    printf 'KVM_REQUIRED: enable KVM on the host (load the kvm module, ensure your user can write /dev/kvm) and pass --device /dev/kvm when containerized; or re-run with ARCHMAGE_QEMU_ALLOW_TCG=1 and a larger --timeout to accept the slow TCG emulation.\n'
    exit 34
fi

REPO_ROOT=$(archmage::repo_root)
X86_64_DIR=$REPO_ROOT/test/build/x86_64
RESULTS_ROOT=$REPO_ROOT/test/results
SMOKE_KEY=$X86_64_DIR/smoke_key
IMG_STAMP=$X86_64_DIR/waydroid-image.stamp
CACHE_DIR=${ARCHMAGE_WAYDROID_CACHE_DIR:-$REPO_ROOT/test/build/waydroid-cache}

# OTA layout constants — mirror of waydroid 1.5.4's channels defaults
# (tools/config/__init__.py, source-verified) and initializer URL shapes.
OTA_BASE=${ARCHMAGE_WAYDROID_MIRROR:-https://ota.waydro.id}
ROM_TYPE=lineage
SYSTEM_TYPE=VANILLA
VENDOR_TYPE=MAINLINE
VM_ARCH=x86_64
IMG_DIR_VM=/etc/waydroid-extra/images

# The rebuild stamp: the image must match what THIS mkrootfs-x86_64.sh would
# produce from THIS staging artifact. Any change to either forces a rebuild.
# Repo-RELATIVE repo-dir key (host/container path mismatch: observed live
# 03-01, an absolute key dies at the inner stamp check after every build).
stamp_key() {
    local repo_part=ci
    if [ "$MODE" = dir ]; then
        local abs
        abs=$(cd -- "$REPO_DIR_ARG" 2>/dev/null && pwd) || abs="$REPO_DIR_ARG"
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
        archmage_info "building the x86_64 waydroid dev image first (mkrootfs-x86_64.sh)"
        MKROOTFS_ARGS=()
        if [ "$MODE" = dir ]; then
            MKROOTFS_ARGS+=(--repo-dir "$REPO_DIR_ARG")
        else
            MKROOTFS_ARGS+=(--from-ci)
        fi
        bash "$SCRIPT_DIR/../mkrootfs-x86_64.sh" "${MKROOTFS_ARGS[@]}"
        stamp_key > "$IMG_STAMP"
    fi
# --- Android image cache download (OUTER phase only: host network + the
# caller's proxy work here; a container-side direct OTA transfer stalls
# on CN networks — observed live 03-02). The seed-dir resolution below
# re-runs in the QEMU phase (inner included) and consumes the cache.
if [ -z "${ARCHMAGE_WAYDROID_IMAGE_DIR:-}" ] && \
   ! { [ -f "$CACHE_DIR/system.img" ] && [ -f "$CACHE_DIR/vendor.img" ]; }; then
    archmage_info "fetching waydroid Android images from OTA base: $OTA_BASE (one-time; cache: $CACHE_DIR)"
    mkdir -p "$CACHE_DIR"
    fetch_ota() {  # fetch_ota <json-url> <out-img-prefix> <zip-name>
        local json_url=$1 prefix=$2 zipname=$3
        local meta url sha dl part attempt size
        meta=$(curl -sL --retry 3 --max-time 60 "$json_url") || die "cannot fetch OTA JSON: $json_url"
        url=$(printf '%s' "$meta" | jq -r '.response[0].url') || true
        sha=$(printf '%s' "$meta" | jq -r '.response[0].id') || true
        [ -n "$url" ] && [ "$url" != null ] || die "no image entry in $json_url"
        [ -n "$sha" ] && [ "$sha" != null ] || die "no sha256 (id) in $json_url"
        dl="$CACHE_DIR/$zipname"
        part="$dl.part"
        # Flaky/throttled transfer discipline (observed live 03-02: the
        # sourceforge route through a CN proxy stalls at 80-350 KB/s and
        # drops with SSL EOF mid-file): resume-from-offset retry loop.
        # curl -C - sends Range: bytes=<existing>-, so each attempt picks up
        # where the last one died; the sha256 check below is the only
        # success criterion.
        for attempt in $(seq 1 12); do
            if curl -L --continue-at - --retry 2 --max-time 1800 \
                    --output "$part" "$url"; then
                break
            fi
            size=$(stat -c%s "$part" 2>/dev/null || echo 0)
            archmage_warn "download attempt $attempt failed — resuming from $size bytes"
            sleep 5
        done
        echo "$sha  $part" | sha256sum -c - >/dev/null \
            || die "sha256 mismatch for $zipname after $attempt attempt(s) (waydroid upstream OTA hash discipline; partial file kept at $part for a resumed re-run)"
        unzip -o -q "$part" -d "$CACHE_DIR/extract-$prefix"
        rm -f "$part"
    }
    fetch_ota "$OTA_BASE/system/$ROM_TYPE/waydroid_$VM_ARCH/$SYSTEM_TYPE.json" system \
        "waydroid-system-$VM_ARCH.zip"
    fetch_ota "$OTA_BASE/vendor/waydroid_$VM_ARCH/$VENDOR_TYPE.json" vendor \
        "waydroid-vendor-$VM_ARCH.zip"
    # Flatten whatever the zips carried (system.img / vendor.img at any depth).
    find "$CACHE_DIR/extract-system" -name 'system.img' -exec mv {} "$CACHE_DIR/system.img" \;
    find "$CACHE_DIR/extract-vendor" -name 'vendor.img' -exec mv {} "$CACHE_DIR/vendor.img" \;
    rm -rf "$CACHE_DIR/extract-system" "$CACHE_DIR/extract-vendor"
    [ -s "$CACHE_DIR/system.img" ] && [ -s "$CACHE_DIR/vendor.img" ] || \
        die "OTA zips did not carry system.img/vendor.img — inspect $CACHE_DIR"
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
        # A5 overrides must survive the self-wrap: -e VAR passes the caller's
        # value, or an empty string the lookups treat as "unset". The image
        # cache is normally filled in the OUTER (host) phase below — where
        # the caller's proxy env works — so the inner fetch only runs on a
        # genuinely empty cache (kept as a fallback, never the first choice:
        # direct OTA transfer from inside a container stalls on CN networks
        # without the proxy — observed live 03-02).
        WRAP_ARGS+=(-e ARCHMAGE_WAYDROID_MIRROR -e ARCHMAGE_WAYDROID_IMAGE_DIR)
        if [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ]; then
            # The caller's proxy listens on the host loopback — only reachable
            # from the container via the shared host network namespace.
            WRAP_ARGS+=(--network host -e https_proxy -e http_proxy -e no_proxy \
                        -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY)
        fi
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
            "pacman -Sy --noconfirm qemu-emulators-full qemu-hw-display-virtio-gpu qemu-hw-display-virtio-vga unzip openssh jq >/dev/null 2>&1 && bash test/waydroid/waydroid-verify.sh $INNER_CMD"
        RC=$?
        set -e
        exit "$RC"
    fi

fi

# --------------------------------------------------------------------------
# QEMU phase (native host with qemu, or inside the self-wrapped container).
# --------------------------------------------------------------------------
archmage::require_cmd qemu-system-x86_64 jq ssh unzip

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
    timeout 300 scp -P 2222 -i "$SMOKE_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes \
        "$@" "root@127.0.0.1:$dest"
}

vm_scp_from() {  # vm_scp_from <guest-path> <local-path>
    timeout 300 scp -P 2222 -i "$SMOKE_KEY" \
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
    if [ "$INNER" = yes ] && [ -n "${ARCHMAGE_HOST_UID:-}" ] && [ -n "$RESULT_DIR" ]; then
        chown -R "$ARCHMAGE_HOST_UID" "$RESULT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# Android image cache — seed-dir resolution (runs in BOTH phases, BEFORE
# result_begin so a missing cache cannot leave a phantom result dir; the
# actual OTA download already happened in the OUTER phase above).
# Priority: ARCHMAGE_WAYDROID_IMAGE_DIR (manual offline dir) >
# waydroid-cache hit > (outer-phase OTA download, or ARCHMAGE_WAYDROID_MIRROR).
# --------------------------------------------------------------------------
IMAGE_SRC=""

seed_images_dir=""
if [ -n "${ARCHMAGE_WAYDROID_IMAGE_DIR:-}" ]; then
    [ -f "$ARCHMAGE_WAYDROID_IMAGE_DIR/system.img" ] && \
        [ -f "$ARCHMAGE_WAYDROID_IMAGE_DIR/vendor.img" ] || \
        die "ARCHMAGE_WAYDROID_IMAGE_DIR='$ARCHMAGE_WAYDROID_IMAGE_DIR' lacks system.img and/or vendor.img"
    seed_images_dir=$ARCHMAGE_WAYDROID_IMAGE_DIR
    IMAGE_SRC="manual:$ARCHMAGE_WAYDROID_IMAGE_DIR"
elif [ -f "$CACHE_DIR/system.img" ] && [ -f "$CACHE_DIR/vendor.img" ]; then
    seed_images_dir=$CACHE_DIR
    IMAGE_SRC="cache:$CACHE_DIR"
    archmage_info "waydroid image cache hit: $CACHE_DIR (download skipped)"
else
    die "waydroid Android images missing (cache $CACHE_DIR empty and no ARCHMAGE_WAYDROID_IMAGE_DIR) — the OUTER phase should have filled the cache (research A5: OTA direct transfer may need ARCHMAGE_WAYDROID_MIRROR)"
fi
archmage_info "waydroid images: $IMAGE_SRC"

# Result bookkeeping starts only here: AFTER the seed-dir resolution above
# (a missing cache must not leave a phantom result dir), and with the
# canonical order source -> result_begin -> result_set_tier (the prior
# draft called result_set_tier before result.sh was sourced — "command not
# found", observed live 03-02 resume).
# shellcheck source=../lib/result.sh
source "$SCRIPT_DIR/../lib/result.sh"
result_begin archmage-qemu-x86_64-waydroid x86_64 "$ACCEL_RESOLVED" "$RESULTS_ROOT" waydroid.json
result_set_tier qemu-kvm
SERIAL_LOG=$RESULT_DIR/serial.log
JOURNAL_LOG=$RESULT_DIR/journal.log
PID_FILE=$RESULT_DIR/qemu.pid
QEMU_PID=""

# The recorded image source rides the result artifacts (honest provenance
# for what entered the device data area — T-03-32).
printf '{"image_source": "%s", "seed_dir": "%s"}\n' "$IMAGE_SRC" "$seed_images_dir" \
    > "$RESULT_DIR/image-source.json"

archmage_info "starting QEMU ($ACCEL_RESOLVED, virtio GPU, timeout ${TIMEOUT}s) — serial: $SERIAL_LOG"
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

# --- phosh session bring-up (03-01's dev-image unit; waydroid needs the
# Wayland display + session bus to run its session in) -----------------------
SESSION_BUDGET=240
vm_ssh "systemctl reset-failed phosh 2>/dev/null || true; \
        pkill -x fcitx5 2>/dev/null || true; \
        systemctl start phosh" \
    > "$RESULT_DIR/phosh-start.log" 2>&1 || true
if ! VMSSH_TIMEOUT=$((TIMEOUT + 60)) vm_ssh "systemctl is-active phosh" \
        > "$RESULT_DIR/phosh-active.log" 2>&1 || \
        ! grep -qx active "$RESULT_DIR/phosh-active.log"; then
    result_assert phosh_session_reachable fail \
        "systemctl start phosh failed — see $(basename "$RESULT_DIR/phosh-start.log")/serial/journal"
    result_finish
    die "phosh session failed to start (waydroid session needs it)"
fi

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
if [ -n "$WAYLAND_DISPLAY" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    result_assert phosh_session_reachable pass \
        "phosh session up (pixman renderer): WAYLAND_DISPLAY=$WAYLAND_DISPLAY in /run/user/0"
else
    result_assert phosh_session_reachable fail \
        "phosh session did not become reachable within ${SESSION_BUDGET}s (WAYLAND_DISPLAY socket missing)"
    result_finish
    die "phosh session not reachable"
fi

# Session env file for in-VM processes joining the phosh session.
vm_ssh 'bash -s' <<REMOTE
set -e
WD='$WAYLAND_DISPLAY'
{
    printf 'XDG_RUNTIME_DIR=/run/user/0\n'
    printf 'WAYLAND_DISPLAY=%s\n' "\$WD"
    grep -h 'DBUS_SESSION_BUS_ADDRESS=' /run/user/0/phosh-session.env 2>/dev/null || true
} > /run/user/0/waydroid-env.sh
chmod 644 /run/user/0/waydroid-env.sh
# Dev-VM audio-stack gap (observed live 03-02): waydroid's generated lxc
# session config binds /run/user/0/pulse/native NON-optionally
# (lxc.mount.entry ... run/xdg/pulse/native); with no PulseAudio/PipeWire
# user session in the headless QEMU image the bind source does not exist
# and lxc aborts the WHOLE container spawn ("Failed to mount
# /run/user/0/pulse/native ... Failed to setup container"). A plain file
# satisfies the bind-mount; audio functionality is not part of the smoke.
# On real devices the audio stack provides the socket — factory config
# (archmage-waydroid-init) must NOT fake it, this is smoke-only.
mkdir -p /run/user/0/pulse
touch /run/user/0/pulse/native
echo waydroid-env-written
REMOTE

# --- binder face: kernel config + binderfs mount (03-RESEARCH Q2's "QEMU
# smoke is viable on the Arch kernel" conclusion, re-proven live) -----------
BINDER_CFG_REPORT=$RESULT_DIR/binder-config.txt
vm_ssh "zcat /proc/config.gz 2>/dev/null | grep -E 'BINDER|ASHMEM' | sort" \
    > "$BINDER_CFG_REPORT" 2>&1 || true
BINDERFS_MOUNT_LOG=$RESULT_DIR/binderfs-mount.log
BINDERFS_OK=no
vm_ssh 'bash -s' > "$BINDERFS_MOUNT_LOG" 2>&1 <<'REMOTE' && BINDERFS_OK=yes
set -e
mkdir -p /dev/binderfs
mount -t binder binder /dev/binderfs
ls -la /dev/binderfs
REMOTE
BINDER_NODES=$(grep -cE 'binder|binderfs' "$BINDERFS_MOUNT_LOG" 2>/dev/null || true)
# The kernel binder comes in two forms: the legacy C implementation
# (CONFIG_ANDROID_BINDER_IPC) and the Rust rewrite (CONFIG_ANDROID_BINDER_IPC_RUST
# — the form Arch's `linux` ships; 03-RESEARCH Q2's rust_binder conclusion).
# Match the kernel's ACTUAL form (plan: "rust_binder 形态,按宿主内核实际值匹配")
# — a C-binder-only grep falsifies on a healthy rust_binder kernel (observed
# live 03-02: binderfs mounted fine while the C symbol is deliberately unset).
BINDER_RUST=$(grep -cE '^CONFIG_ANDROID_BINDER_IPC_RUST=y' "$BINDER_CFG_REPORT" || true)
BINDER_C=$(grep -cE '^CONFIG_ANDROID_BINDER_IPC=y' "$BINDER_CFG_REPORT" || true)
if { [ "$BINDER_RUST" -gt 0 ] || [ "$BINDER_C" -gt 0 ]; } && \
   [ "$BINDERFS_OK" = yes ] && [ "${BINDER_NODES:-0}" -gt 0 ]; then
    KERNEL_FORM=$(grep -E 'CONFIG_ANDROID_BINDER_IPC(_RUST)?=|CONFIG_ANDROID_BINDER_DEVICES' \
        "$BINDER_CFG_REPORT" | tr '\n' ' ' || true)
    result_assert binder_present pass \
        "kernel binder present (${KERNEL_FORM:-<n/a>}) + binderfs mounted live with $BINDER_NODES binder nodes (rust_binder form per 03-RESEARCH Q2)"
else
    result_assert binder_present fail \
        "binder face broken: binder_ipc_rust=$BINDER_RUST, binder_ipc_c=$BINDER_C, mount=$BINDERFS_OK, nodes=${BINDER_NODES:-0} — see binder-config.txt/binderfs-mount.log (03-RESEARCH rust_binder conclusion falsified?)"
fi

# --- seed the Android images + waydroid init --------------------------------
archmage_info "seeding Android images into the VM at $IMG_DIR_VM (waydroid preinstalled path — OTA short-circuit)"
vm_ssh "mkdir -p $IMG_DIR_VM" >/dev/null 2>&1
vm_scp_to "$IMG_DIR_VM/system.img" "$seed_images_dir/system.img" >/dev/null
vm_scp_to "$IMG_DIR_VM/vendor.img" "$seed_images_dir/vendor.img" >/dev/null

INIT_LOG=$RESULT_DIR/waydroid-init.log
INIT_BUDGET=180
INIT_OK=no
VMSSH_TIMEOUT=$((TIMEOUT + INIT_BUDGET)) vm_ssh 'bash -s' > "$INIT_LOG" 2>&1 <<REMOTE && INIT_OK=yes
set -e
export PATH=/usr/bin:/bin
systemctl start waydroid-container
sleep 2
waydroid init 2>&1
echo "--- waydroid status after init ---"
waydroid status || true
test -f /var/lib/waydroid/waydroid.cfg
REMOTE

STATUS_AFTER_INIT=$RESULT_DIR/waydroid-status-init.log
vm_ssh "waydroid status" > "$STATUS_AFTER_INIT" 2>&1 || true
if [ "$INIT_OK" = yes ] && [ -s "$STATUS_AFTER_INIT" ]; then
    result_assert waydroid_init pass \
        "waydroid init succeeded with preseeded images (OTA skipped: $IMAGE_SRC); waydroid status: $(head -2 "$STATUS_AFTER_INIT" | tr '\n' ' ' | tr '\t' ' ')"
else
    INIT_TAIL=$(tail -5 "$INIT_LOG" 2>/dev/null | tr '\n' ' ' || true)
    result_assert waydroid_init fail \
        "waydroid init failed (rc): log tail: $INIT_TAIL — see waydroid-init.log"
fi

# --- data placement: /var/lib/waydroid on the @var nodatacow subvolume ------
VAR_FSROOT=$(vm_ssh "findmnt -no FSROOT /var" 2>/dev/null || true)
VAR_NOCOW=$(vm_ssh "lsattr -d /var/lib/waydroid 2>/dev/null" 2>/dev/null || true)
if printf '%s' "$VAR_FSROOT" | grep -q '@var' && printf '%s' "$VAR_NOCOW" | grep -q 'C'; then
    result_assert waydroid_data_on_var pass \
        "/var/lib/waydroid sits on $VAR_FSROOT (the @var nodatacow subvolume, PITFALLS 6): '$VAR_NOCOW'" informational
else
    result_assert waydroid_data_on_var fail \
        "waydroid data placement: FSROOT='$VAR_FSROOT' lsattr='$VAR_NOCOW' (expected @var + NoCOW)" informational
fi

# --- waydroid session start -> Session: RUNNING -----------------------------
# (renderer adaptation hook, plan-authorized: retry once with a software-GL
# compositor if the pixman session cannot serve the Android hwcomposer).
WAYDROID_SESSION_BUDGET=600
try_session() {
    vm_ssh 'bash -s' > "$RESULT_DIR/waydroid-session.log" 2>&1 <<'REMOTE'
set -a; . /run/user/0/waydroid-env.sh; set +a
setsid nohup waydroid session start \
    > /root/waydroid-artifacts/session-start.log 2>&1 < /dev/null &
echo "session-start-issued pid=$!"
REMOTE
    [ -s "$RESULT_DIR/waydroid-session.log" ] || return 1
    grep -q 'session-start-issued' "$RESULT_DIR/waydroid-session.log" || return 1
    local i=0 st
    while [ "$i" -lt "$WAYDROID_SESSION_BUDGET" ]; do
        st=$(vm_ssh "set -a; . /run/user/0/waydroid-env.sh; set +a; waydroid status 2>/dev/null" 2>/dev/null || true)
        if printf '%s' "$st" | grep -qE '^Session:[[:space:]]*RUNNING'; then
            printf '%s\n' "$st" > "$RESULT_DIR/waydroid-status.log"
            return 0
        fi
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        sleep 5
        i=$((i + 5))
    done
    return 1
}

R=/root/waydroid-artifacts
vm_ssh "mkdir -p '$R'" >/dev/null 2>&1

SESSION_OK=no
RENDERER_USED=pixman
if try_session; then
    SESSION_OK=yes
else
    archmage_info "session did not reach RUNNING under pixman — retrying with software-GL compositor (plan-authorized renderer adaptation)"
    vm_ssh "printf 'WLR_RENDERER=gles2\nWLR_RENDERER_ALLOW_SOFTWARE=1\nLIBGL_ALWAYS_SOFTWARE=1\n' > /etc/default/phosh-dev-session; \
            waydroid session stop >/dev/null 2>&1 || true; \
            systemctl restart phosh" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt "$SESSION_BUDGET" ]; do
        WAYLAND_DISPLAY=$(vm_ssh "ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort | tail -1" 2>/dev/null || true)
        [ -n "$WAYLAND_DISPLAY" ] && break
        kill -0 "$QEMU_PID" 2>/dev/null || break
        sleep 5
        i=$((i + 5))
    done
    if [ -n "$WAYLAND_DISPLAY" ]; then
        vm_ssh 'bash -s' <<REMOTE
set -e
WD='$WAYLAND_DISPLAY'
{
    printf 'XDG_RUNTIME_DIR=/run/user/0\n'
    printf 'WAYLAND_DISPLAY=%s\n' "\$WD"
    grep -h 'DBUS_SESSION_BUS_ADDRESS=' /run/user/0/phosh-session.env 2>/dev/null || true
} > /run/user/0/waydroid-env.sh
chmod 644 /run/user/0/waydroid-env.sh
mkdir -p /run/user/0/pulse
touch /run/user/0/pulse/native
REMOTE
        RENDERER_USED="gles2+LIBGL_ALWAYS_SOFTWARE"
        if try_session; then
            SESSION_OK=yes
        fi
    fi
fi

if [ "$SESSION_OK" = yes ]; then
    ST_DISPLAY=$(head -4 "$RESULT_DIR/waydroid-status.log" | tr '\n' ' ' | tr '\t' ' ' | sed 's/  */ /g')
    result_assert waydroid_session_running pass \
        "waydroid session start reached Session: RUNNING under the $RENDERER_USED compositor renderer — $ST_DISPLAY (Android container stack end-to-end: binder -> lxc -> Android session on the phosh Wayland display)"
else
    SESS_TAIL=$(tail -5 "$R/session-start.log" 2>/dev/null | tr '\n' ' ' || true)
    LXC_STATE=$(vm_ssh "waydroid status 2>/dev/null; systemctl is-active waydroid-container 2>/dev/null" 2>/dev/null | tr '\n' ' ' || true)
    result_assert waydroid_session_running fail \
        "waydroid session never reached RUNNING under pixman OR $RENDERER_USED (status/container: ${LXC_STATE:-<none>}; session log tail: $SESS_TAIL) — see waydroid-session.log/session-start.log/journal"
fi

# --- failed units (gating; checked after the full stack came up) ------------
FAILED_UNITS=$(vm_ssh "systemctl --failed --no-legend" 2>/dev/null || true)
if [ -z "$FAILED_UNITS" ]; then
    result_assert no_failed_units pass "systemctl --failed --no-legend -> empty (waydroid-container/waydroid-net included)"
else
    result_assert no_failed_units fail "failed units: ${FAILED_UNITS//$'\n'/; }"
fi

# --- diagnostics before shutdown: container + session + Android logs --------
vm_ssh "journalctl -b --no-pager" > "$JOURNAL_LOG" 2>/dev/null || \
    archmage_warn "journal capture failed (guest may be degraded) — see serial log"
vm_ssh "waydroid status 2>&1; echo ---; cat /var/lib/waydroid/waydroid.cfg 2>/dev/null; echo ---; ls -la /dev/binderfs 2>/dev/null" \
    > "$RESULT_DIR/waydroid-final-diag.log" 2>&1 || true
vm_scp_from "$R/session-start.log" "$RESULT_DIR/session-start.log" >/dev/null 2>&1 || true

# --- teardown ----------------------------------------------------------------
vm_ssh "set -a; . /run/user/0/waydroid-env.sh 2>/dev/null; set +a; \
        waydroid session stop >/dev/null 2>&1 || true; \
        systemctl stop waydroid-container >/dev/null 2>&1 || true" \
    > /dev/null 2>&1 || true

vm_ssh poweroff >/dev/null 2>&1 || true
WAITED=0
while kill -0 "$QEMU_PID" 2>/dev/null && [ "$WAITED" -lt 60 ]; do
    sleep 3
    WAITED=$((WAITED + 3))
done

result_finish

if [ "$RESULT_STATUS" = pass ]; then
    archmage_info "waydroid-verify PASS: $RESULT_DIR/waydroid.json"
    exit 0
fi
archmage_warn "waydroid-verify FAIL: $RESULT_DIR/waydroid.json"
exit 1
