#!/usr/bin/env bash
# perf-x86_64.sh — one-command QEMU performance baseline (04-02, PERF-01).
#
#   existing x86_64 dev image (--image, default test/build/x86_64/rootfs.img)
#   -> QEMU boot (KVM-required per the Phase 3 exit-code contract)
#   -> SSH (127.0.0.1:$PORT, default 2223 — never 2222, so a live smoke VM
#      cannot collide with a baseline run)
#   -> settle (default 60s) -> collect the QEMU-measurable set (04-RESEARCH
#      Q4): ① systemd-analyze kernel/userspace + critical-chain artifact,
#      ② MemAvailable -> metrics.mem_available_mb, ③ systemd-cgtop per-unit
#      RSS Top table (ARTIFACT ONLY — per-unit RSS values are deliberately
#      NOT squeezed into the metrics schema), ④ running service count ->
#      metrics.services_running, ⑤ cold start = top running units from
#      systemd-analyze blame + the phosh session THIS harness starts
#      (activation latency; journal archived). Units the image does not have
#      are honestly omitted — nothing is invented.
#
# The result contract is test/lib/result.sh (schema_version 1) written as
# perf.json with tier=qemu-kvm and source=qemu (PERF-01 reserved the device
# source for the real-hardware face — 33/DEVICE_REQUIRED, not this script).
#
# GATES vs NUMBERS (STRATEGY §8 / 04-RESEARCH Q4): every metric is
# INFORMATIONAL-ONLY. The gating assertions assert that COLLECTION SUCCEEDED
# (boot to SSH, no failed units, each metric actually measured); no value is
# threshold-compared anywhere — QEMU numbers carry runner/TCG noise and the
# baseline exists to accumulate data, not to gate.
#
# KVM-required (Phase 3 convention): without a writable /dev/kvm the script
# prints `KVM_REQUIRED: ...` as the FIRST stderr line and exits 34. The only
# exemption is ARCHMAGE_QEMU_ALLOW_TCG=1 (caller explicitly accepts the long
# TCG runtime and must raise --timeout itself).
#
# Boot mode (automatic, recorded in the result + collect.log provenance):
#   direct-kernel  when vmlinuz-linux + initramfs-linux.img sit next to the
#                  image (local dev loop; same path as smoke-x86_64.sh);
#   ovmf-grub      otherwise (published nightly artifacts ship ONLY the
#                  image — the pure GRUB path proven by rollback-x86_64.sh
#                  boots exactly these via the ESP fallback loader).
# The published CI artifact carries a CI-run-internal SSH key, so the CI
# face provisions its OWN throwaway key into the image offline and passes
# it via --ssh-key (see .github/workflows/perf.yml).
#
# One command, self-wrapping: when qemu-system-x86_64 is missing on the
# host, the QEMU phase re-executes itself inside an archlinux container
# after installing qemu-emulators-full + edk2-ovmf there.
#
# Usage:
#   bash test/perf/perf-x86_64.sh [--image PATH] [--ssh-key PATH]
#                                 [--port N] [--settle SECS] [--timeout SECS]
#                                 [--accel kvm|tcg] [--repo-dir PATH]
#
# Outputs: test/results/<ts>/{perf.json, serial.log, journal.log, console.log,
# systemd-analyze.txt, critical-chain.txt, cgtop.txt, blame.txt,
# running-services.txt, cold-start-units.txt, phosh-start.log,
# phosh-journal.log, collect.log, qemu.pid} and the test/results/latest
# symlink. Exit code 0 iff every GATING (collection) assertion passed.
# Baseline publication copies the green perf.json to
# test/perf/baseline-latest.json (committed; provenance travels inside the
# JSON: tier/source/accel/target/started_at).

set -euo pipefail

usage() {
    cat <<'EOF'
perf-x86_64.sh — QEMU performance baseline collection (PERF-01)

Usage:
  bash test/perf/perf-x86_64.sh [options]

Options:
  --image PATH     Dev image to boot (default test/build/x86_64/rootfs.img).
                   A published nightly artifact works as-is (ovmf-grub boot
                   path is selected automatically when no kernel/initramfs
                   sit next to the image).
  --ssh-key PATH   SSH private key for root@vm (default
                   test/build/x86_64/smoke_key — the pair baked into images
                   built by test/mkrootfs-x86_64.sh on THIS checkout).
  --port N         Host SSH forward port (default 2223; smoke owns 2222).
  --settle SECS    Idle settle before collection (default 60).
  --timeout SECS   SSH-readiness budget (default 600; raise for TCG).
  --accel MODE     kvm (default; KVM-required per the exit-code contract) |
                   tcg (only honoured with ARCHMAGE_QEMU_ALLOW_TCG=1).
  --repo-dir PATH  Only used when the default image is missing: build it
                   first from this local staging directory (same pass-through
                   semantics as smoke-x86_64.sh). Perf never rebuilds a
                   present image.
  -h, --help       Show this help.

Environment:
  ARCHMAGE_QEMU_ALLOW_TCG=1   Exemption switch for the KVM_REQUIRED guard
                              (exit 34): accept the slow TCG emulation.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SETTLE=60
TIMEOUT=600
PORT=2223
REPO_DIR_ARG=""
IMAGE_ARG=""
SSH_KEY_ARG=""
ACCEL=""
INNER=no
while [ $# -gt 0 ]; do
    case "$1" in
        --image)
            [ $# -ge 2 ] || die "--image needs a PATH argument"
            IMAGE_ARG=$2
            shift
            ;;
        --ssh-key)
            [ $# -ge 2 ] || die "--ssh-key needs a PATH argument"
            SSH_KEY_ARG=$2
            shift
            ;;
        --port)
            [ $# -ge 2 ] || die "--port needs a number"
            PORT=$2
            shift
            ;;
        --settle)
            [ $# -ge 2 ] || die "--settle needs a number of seconds"
            SETTLE=$2
            shift
            ;;
        --timeout)
            [ $# -ge 2 ] || die "--timeout needs a number of seconds"
            TIMEOUT=$2
            shift
            ;;
        --accel)
            [ $# -ge 2 ] || die "--accel needs kvm|tcg"
            ACCEL=$2
            shift
            ;;
        --repo-dir)
            [ $# -ge 2 ] || die "--repo-dir needs a PATH argument"
            REPO_DIR_ARG=$2
            shift
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
case "$PORT" in
    ''|*[!0-9]*) die "--port must be a positive integer, got '$PORT'" ;;
esac
case "$SETTLE" in
    ''|*[!0-9]*) die "--settle must be a non-negative integer, got '$SETTLE'" ;;
esac
case "$TIMEOUT" in
    ''|*[!0-9]*) die "--timeout must be a positive integer, got '$TIMEOUT'" ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# --------------------------------------------------------------------------
# KVM guard (Phase 3 exit-code contract) — runs in the HOST phase before
# anything else prints AND again in the self-wrapped container phase, so the
# very first stderr line is KVM_REQUIRED whenever KVM is genuinely
# unavailable.
# --------------------------------------------------------------------------
if ! archmage::kvm_available && [ "${ARCHMAGE_QEMU_ALLOW_TCG:-}" != "1" ]; then
    printf 'KVM_REQUIRED: perf-x86_64.sh needs KVM-accelerated QEMU but /dev/kvm is not accessible (missing, or not passed into the container).\n' >&2
    printf 'KVM_REQUIRED: enable KVM on the host (load the kvm module, ensure your user can write /dev/kvm) and pass --device /dev/kvm when containerized; or re-run with ARCHMAGE_QEMU_ALLOW_TCG=1 and a larger --timeout to accept the slow TCG emulation.\n' >&2
    exit 34
fi

REPO_ROOT=$(archmage::repo_root)
X86_64_DIR=$REPO_ROOT/test/build/x86_64
RESULTS_ROOT=$REPO_ROOT/test/results

IMAGE=${IMAGE_ARG:-$X86_64_DIR/rootfs.img}
SSH_KEY=${SSH_KEY_ARG:-$X86_64_DIR/smoke_key}

# Repo-relative normalization for the self-wrap re-exec: paths under the
# repo must reach the inner shell as repo-relative (the container mounts the
# repo at /w), paths outside stay verbatim (the CI workflow mounts their
# directory explicitly).
to_repo_relative() {
    local p=$1
    case "$p" in
        "$REPO_ROOT"/*) printf '%s\n' "${p#"$REPO_ROOT"/}" ;;
        *) printf '%s\n' "$p" ;;
    esac
}
WRAP_IMAGE=$(to_repo_relative "$IMAGE")
WRAP_KEY=$(to_repo_relative "$SSH_KEY")

# --------------------------------------------------------------------------
# Host phase: image presence (never auto-built when present — the perf
# baseline measures the EXISTING dev image; the build entry points live in
# the precondition), then self-wrap when qemu is missing.
# --------------------------------------------------------------------------
if [ "$INNER" = no ]; then
    if [ ! -s "$IMAGE" ]; then
        if [ -n "$REPO_DIR_ARG" ] && [ "$IMAGE" = "$X86_64_DIR/rootfs.img" ]; then
            archmage_info "dev image missing — building it first from $REPO_DIR_ARG (mkrootfs-x86_64.sh)"
            bash "$SCRIPT_DIR/mkrootfs-x86_64.sh" --repo-dir "$REPO_DIR_ARG"
        else
            die "dev image missing: $IMAGE (rebuild it with: bash test/smoke-x86_64.sh --rebuild, or bash test/mkrootfs-x86_64.sh --repo-dir <staging-dir>, or pass --image PATH)"
        fi
    fi
    [ -f "$SSH_KEY" ] || die "SSH private key missing: $SSH_KEY (mkrootfs-x86_64.sh creates the pair; CI faces provision their own key into the image and pass --ssh-key)"

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        archmage_info "qemu-system-x86_64 missing on host — self-wrapping the QEMU phase in an archlinux container (qemu-emulators-full + edk2-ovmf)"
        archmage::engine_detect
        WRAP_ARGS=(--rm --platform linux/x86_64 -v "$REPO_ROOT":/w -w /w)
        if archmage::kvm_available; then
            WRAP_ARGS+=(--device /dev/kvm)
        fi
        # The container runs as root; RESULT_DIR files must go back to the
        # invoking user (chowned in the inner EXIT trap).
        WRAP_ARGS+=(-e ARCHMAGE_HOST_UID="$(id -u)")
        INNER_ARGS=(--image "$WRAP_IMAGE" --ssh-key "$WRAP_KEY" --port "$PORT" \
                    --settle "$SETTLE" --timeout "$TIMEOUT" --in-container)
        if [ -n "$ACCEL" ]; then
            INNER_ARGS+=(--accel "$ACCEL")
        fi
        INNER_CMD=""
        if [ ${#INNER_ARGS[@]} -gt 0 ]; then
            INNER_CMD=$(printf '%q ' "${INNER_ARGS[@]}")
        fi
        set +e
        # shellcheck disable=SC2086
        "$ARCHMAGE_ENGINE" run "${WRAP_ARGS[@]}" archlinux:base bash -c \
            "pacman -Sy --noconfirm qemu-emulators-full edk2-ovmf openssh jq >/dev/null 2>&1 && bash test/perf/perf-x86_64.sh $INNER_CMD"
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

# Boot mode selection (see header): direct-kernel when the kernel pair sits
# next to the image, ovmf-grub otherwise (published artifacts).
IMAGE_DIR=$(cd -- "$(dirname -- "$IMAGE")" && pwd)
if [ -s "$IMAGE_DIR/vmlinuz-linux" ] && [ -s "$IMAGE_DIR/initramfs-linux.img" ]; then
    BOOT_MODE=direct-kernel
else
    BOOT_MODE=ovmf-grub
fi

OVMF_CODE=""
OVMF_VARS_TPL=""
if [ "$BOOT_MODE" = ovmf-grub ]; then
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
    [ -n "$OVMF_CODE" ] || die "no OVMF firmware found (install edk2-ovmf — required for the ovmf-grub boot path)"
fi

# The forward port must be free (T-01-06: hostfwd is loopback-only). Perf
# defaults to 2223 precisely so a live smoke/waydroid VM on 2222 cannot
# collide with a baseline run.
if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then
    die "127.0.0.1:$PORT is already in use — is another harness VM running? Pass --port or kill the stale instance."
fi

# shellcheck source=../lib/result.sh
source "$SCRIPT_DIR/../lib/result.sh"
result_begin archmage-qemu-x86_64-perf x86_64 "$ACCEL_RESOLVED" "$RESULTS_ROOT" perf.json
result_set_tier qemu-kvm
result_set_source qemu
SERIAL_LOG=$RESULT_DIR/serial.log
JOURNAL_LOG=$RESULT_DIR/journal.log
PID_FILE=$RESULT_DIR/qemu.pid
QEMU_PID=""

# SSH into the guest (user-mode NAT, loopback-only forward). Rapid sequential
# connections can trip the guest's sshd MaxStartups (observed live in 03-03)
# — retry transient failures before giving up.
vm_ssh() {
    local secs=${VMSSH_TIMEOUT:-60}
    local rc=0
    for _ in 1 2 3; do
        if timeout "$secs" ssh -p "$PORT" -i "$SSH_KEY" \
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
        for _ in $(seq 1 20); do
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

archmage_info "starting QEMU (boot mode: $BOOT_MODE, $ACCEL_RESOLVED, port $PORT, timeout ${TIMEOUT}s) — serial: $SERIAL_LOG"
VARS_FD=""
case "$BOOT_MODE" in
    direct-kernel)
        qemu-system-x86_64 \
            -M q35 -cpu "$QEMU_CPU" -m 2048 -smp 2 \
            -accel "$ACCEL_RESOLVED" \
            -kernel "$IMAGE_DIR/vmlinuz-linux" \
            -initrd "$IMAGE_DIR/initramfs-linux.img" \
            -append "root=/dev/vda2 rw console=ttyS0" \
            -drive file="$IMAGE",if=virtio,format=raw \
            -netdev "user,id=n0,hostfwd=$(archmage::hostfwd_tcp "$PORT")" \
            -device virtio-net-pci,netdev=n0 \
            -nographic -monitor none -no-reboot \
            -serial "file:$SERIAL_LOG" \
            -pidfile "$PID_FILE" \
            </dev/null >>"$RESULT_DIR/console.log" 2>&1 &
        ;;
    ovmf-grub)
        VARS_FD=$RESULT_DIR/OVMF_VARS.fd
        cp "$OVMF_VARS_TPL" "$VARS_FD"
        qemu-system-x86_64 \
            -M q35 -cpu "$QEMU_CPU" -m 2048 -smp 2 \
            -accel "$ACCEL_RESOLVED" \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
            -drive if=pflash,format=raw,file="$VARS_FD" \
            -drive file="$IMAGE",if=virtio,format=raw \
            -netdev "user,id=n0,hostfwd=$(archmage::hostfwd_tcp "$PORT")" \
            -device virtio-net-pci,netdev=n0 \
            -nographic -monitor none -no-reboot \
            -serial "file:$SERIAL_LOG" \
            -pidfile "$PID_FILE" \
            </dev/null >>"$RESULT_DIR/console.log" 2>&1 &
        ;;
esac
QEMU_PID=$!

# Wait for SSH readiness within the budget; the elapsed time IS boot_seconds
# (QEMU start -> SSH ready, the smoke contract's definition).
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
    result_assert ssh_ready pass \
        "SSH ready at 127.0.0.1:$PORT after ${SECONDS}s (boot mode: $BOOT_MODE); boot_seconds value is informational-only"
    result_set_boot_seconds "$SECONDS"
else
    result_assert ssh_ready fail "SSH not ready within ${TIMEOUT}s (boot timeout)"
    result_finish
    die "boot timeout — serial log: $SERIAL_LOG"
fi

# --- Gate: clean systemd state (STRATEGY §8 hard gates: boot + SSH + no
#     failed units; same semantics as the smoke assertion set). -------------
FAILED_UNITS=$(vm_ssh "systemctl --failed --no-legend" 2>/dev/null || true)
if [ -z "$FAILED_UNITS" ]; then
    result_assert no_failed_units pass "systemctl --failed --no-legend -> empty"
else
    result_assert no_failed_units fail "failed units: ${FAILED_UNITS//$'\n'/; }"
fi

# --- Idle settle: let the boot churn drain before the idle-state metrics ---
archmage_info "settling ${SETTLE}s before idle-state collection"
sleep "$SETTLE"

# --- ① systemd-analyze: kernel/userspace seconds + critical-chain artifact -
# systemd-analyze formats spans with unit suffixes ("654ms (kernel)" is
# observed live) — capture the token before the paren, normalize to seconds.
to_seconds() {
    awk -v t="$1" 'BEGIN {
        if (t ~ /ms$/)       { sub(/ms$/, "", t);   printf "%.3f", t / 1000 }
        else if (t ~ /min$/) { sub(/min$/, "", t);  printf "%.3f", t * 60 }
        else                 { sub(/s$/, "", t);    printf "%.3f", t }
    }'
}
ANALYZE_TXT=$RESULT_DIR/systemd-analyze.txt
KERNEL_S=""
USERSPACE_S=""
if VMSSH_TIMEOUT=120 vm_ssh "LC_ALL=C systemd-analyze" > "$ANALYZE_TXT" 2>&1 &&
    grep -q 'Startup finished' "$ANALYZE_TXT"; then
    PARSED=$(awk '/Startup finished/ {
            for (i = 1; i < NF; i++) {
                if ($(i+1) == "(kernel)")    k = $i
                if ($(i+1) == "(userspace)") u = $i
            }
        }
        END { print (k != "" ? k : "-") "|" (u != "" ? u : "-") }' "$ANALYZE_TXT" | head -1)
    KERNEL_RAW=${PARSED%%|*}
    USERSPACE_RAW=${PARSED#*|}
    if [ "$KERNEL_RAW" != "-" ] && [ "$USERSPACE_RAW" != "-" ]; then
        KERNEL_S=$(to_seconds "$KERNEL_RAW")
        USERSPACE_S=$(to_seconds "$USERSPACE_RAW")
    fi
fi
if [ -n "$KERNEL_S" ] && [ -n "$USERSPACE_S" ]; then
    VMSSH_TIMEOUT=120 vm_ssh "systemd-analyze critical-chain --no-pager" \
        > "$RESULT_DIR/critical-chain.txt" 2>&1 || true
    result_assert systemd_analyze_collected pass \
        "systemd-analyze collected: kernel=${KERNEL_S}s userspace=${USERSPACE_S}s (informational-only; critical-chain artifact archived)"
else
    result_assert systemd_analyze_collected fail \
        "systemd-analyze output missing/unparseable — see $(basename "$ANALYZE_TXT")"
fi

# --- ② MemAvailable -> metrics.mem_available_mb -----------------------------
MEM_KB=""
MEM_KB=$(vm_ssh "awk '/^MemAvailable:/ {print \$2}' /proc/meminfo" 2>/dev/null | head -1)
MEM_MB=""
if [ -n "$MEM_KB" ] && [ "$MEM_KB" -gt 0 ] 2>/dev/null; then
    MEM_MB=$((MEM_KB / 1024))
    result_assert mem_available_collected pass \
        "MemAvailable collected: ${MEM_MB}MB (informational-only)"
else
    result_assert mem_available_collected fail \
        "/proc/meminfo MemAvailable unreadable over SSH (got '${MEM_KB:-<empty>}')"
fi

# --- ③ systemd-cgtop per-unit RSS: Top table -> ARTIFACT ONLY (the plan
#     explicitly keeps per-unit RSS out of the metrics schema) ---------------
CGTOP_TXT=$RESULT_DIR/cgtop.txt
CGTOP_LINES=0
if VMSSH_TIMEOUT=120 vm_ssh "systemd-cgtop -n1 --batch --order=memory" \
        > "$CGTOP_TXT" 2>&1; then
    CGTOP_LINES=$(grep -c . "$CGTOP_TXT" || true)
fi
if [ "${CGTOP_LINES:-0}" -ge 2 ]; then
    result_assert cgtop_collected pass \
        "systemd-cgtop one-shot sample archived (per-unit RSS lives in the artifact only — not a metrics-schema field, per plan)"
else
    result_assert cgtop_collected fail \
        "systemd-cgtop produced no usable sample — see $(basename "$CGTOP_TXT")"
fi

# --- ④ running service count -> metrics.services_running --------------------
SERVICES_N=""
SERVICES_N=$(vm_ssh "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')
if [ -n "$SERVICES_N" ] && [ "$SERVICES_N" -gt 0 ] 2>/dev/null; then
    result_assert services_running_collected pass \
        "running service count collected: $SERVICES_N (informational-only)"
else
    result_assert services_running_collected fail \
        "running service count unreadable or zero (got '${SERVICES_N:-<empty>}')"
fi

# --- ⑤ cold start: blame of ACTUALLY RUNNING units + the phosh session this
#     harness starts (activation latency; journal archived). Units the image
#     does not run are honestly omitted — nothing invented. ------------------
BLAME_TXT=$RESULT_DIR/blame.txt
RUNNING_TXT=$RESULT_DIR/running-services.txt
COLD_FILE=$RESULT_DIR/cold-start-units.txt
BLAME_OK=no
COLD_UNITS_JSON=null
if VMSSH_TIMEOUT=180 vm_ssh "systemd-analyze blame --no-pager" > "$BLAME_TXT" 2>&1 &&
    VMSSH_TIMEOUT=120 vm_ssh "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print \$1}'" \
        > "$RUNNING_TXT" 2>&1 &&
    [ -s "$BLAME_TXT" ] && [ -s "$RUNNING_TXT" ]; then
    # blame spans carry unit suffixes (s/ms/min — "159ms" observed live);
    # keep the top 5 entries that are RUNNING services (blame is already
    # sorted descending by activation time), normalized to seconds.
    awk 'NR==FNR { run[$1]=1; next }
         {
             t = $1; u = $2
             if (u == "" || !(u in run)) next
             if (t ~ /ms$/)       { sub(/ms$/, "", t);   t = t / 1000 }
             else if (t ~ /min$/) { sub(/min$/, "", t);  t = t * 60 }
             else if (t ~ /s$/)   { sub(/s$/, "", t) }
             else next
             printf "%s %.3f\n", u, t
         }' "$RUNNING_TXT" "$BLAME_TXT" | head -5 > "$COLD_FILE"
    if [ -s "$COLD_FILE" ]; then
        COLD_UNITS_JSON=$(jq -Rn '
            reduce (inputs | select(length > 0) | split(" ")) as [$u, $s]
            ({}; .[$u] = ($s | tonumber))' < "$COLD_FILE") || COLD_UNITS_JSON=null
        [ "$COLD_UNITS_JSON" != null ] && BLAME_OK=yes
    fi
fi
if [ "$BLAME_OK" = yes ]; then
    result_assert blame_cold_start_collected pass \
        "cold-start blame collected for $(wc -l < "$COLD_FILE" | tr -d ' ') running unit(s) (informational-only; absent units honestly omitted)"
else
    result_assert blame_cold_start_collected fail \
        "systemd-analyze blame / running-service cross-reference produced no parseable entries — see $(basename "$BLAME_TXT")"
fi

# phosh session activation: the dev image ships phosh as a system unit that
# harnesses start post-SSH (03-01 decision — boot-time starts get orphaned).
# The activation latency of the session THIS harness starts is the honest
# "session cold start" face available in QEMU (true GUI cold start on a real
# panel is 33/DEVICE_REQUIRED). Readiness signal = the Wayland socket in
# /run/user/0 (the ime/waydroid harnesses' session-ready contract): systemctl
# "active" is near-instant for a simple-type unit and says nothing about
# presentation.
PHOSH_START_EPOCH=$(date +%s)
vm_ssh "systemctl reset-failed phosh 2>/dev/null || true; systemctl start phosh" \
    > "$RESULT_DIR/phosh-start.log" 2>&1 || true
PHOSH_STATE=""
PHOSH_S=""
for _ in $(seq 1 60); do
    PHOSH_STATE=$(vm_ssh "systemctl is-active phosh" 2>/dev/null | head -1)
    if [ "$PHOSH_STATE" = active ]; then
        if [ -n "$(vm_ssh "ls /run/user/0/wayland-* 2>/dev/null")" ]; then
            PHOSH_S=$(( $(date +%s) - PHOSH_START_EPOCH ))
            break
        fi
    fi
    sleep 2
done
COLD_JSON=$COLD_UNITS_JSON
if [ -n "$PHOSH_S" ]; then
    VMSSH_TIMEOUT=120 vm_ssh "journalctl -b -u phosh -o short-unix --no-pager" \
        > "$RESULT_DIR/phosh-journal.log" 2>&1 || true
    COLD_JSON=$(jq -n --argjson base "$COLD_UNITS_JSON" --argjson s "$PHOSH_S" \
        '$base + {"phosh.service": $s}')
    result_assert phosh_cold_start_collected pass \
        "phosh session activation collected: ${PHOSH_S}s to Wayland socket (harness-started, 2s poll granularity; journal artifact archived; real-panel GUI cold start is 33/DEVICE_REQUIRED)"
else
    result_assert phosh_cold_start_collected fail \
        "phosh session never reached Wayland-socket readiness within 120s (state: '${PHOSH_STATE:-<unknown>}') — see $(basename "$RESULT_DIR/phosh-start.log") and serial log"
fi

# --- metrics assembly (only when the measurable set actually landed) -------
if [ -n "$KERNEL_S" ] && [ -n "$USERSPACE_S" ] && [ -n "$MEM_MB" ] &&
    [ -n "$SERVICES_N" ] && [ "$COLD_JSON" != null ]; then
    METRICS_JSON=$(jq -n \
        --argjson k "$KERNEL_S" \
        --argjson u "$USERSPACE_S" \
        --argjson mem "$MEM_MB" \
        --argjson svc "$SERVICES_N" \
        --argjson cold "$COLD_JSON" \
        '{systemd_analyze_kernel_s: $k,
          systemd_analyze_userspace_s: $u,
          mem_available_mb: $mem,
          services_running: $svc,
          cold_start: $cold}')
    result_set_metrics "$METRICS_JSON"
fi

# --- Archive the boot journal before shutdown (triage artifact) -------------
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

# --- Provenance sidecar (collect.log): image stamp + collection conditions --
# T-04-06: the baseline's provenance travels in the JSON (tier/source/accel/
# target/started_at); the image stamp + boot mode live here and in SUMMARY.
{
    echo "boot_mode: $BOOT_MODE"
    echo "accel: $ACCEL_RESOLVED"
    echo "port: $PORT"
    echo "settle_seconds: $SETTLE"
    echo "image: $IMAGE"
    echo "image_sha256: $(sha256sum "$IMAGE" | awk '{print $1}')"
    echo "collected_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RESULT_DIR/collect.log"

if [ "$RESULT_STATUS" = pass ]; then
    archmage_info "perf PASS: $RESULT_DIR/perf.json"
    exit 0
fi
archmage_warn "perf FAIL: $RESULT_DIR/perf.json"
exit 1
