# common.sh — shared helpers for the linuxphoneOS QEMU test harness.
#
# Sourced by test/*.sh. Callers own shell options (they run with
# `set -euo pipefail`); this library deliberately sets none so sourcing it
# never changes caller behaviour.
#
# Provides:
#   lpos::require_cmd <cmd>...      fail-fast tool probing
#   lpos::repo_root                  resolve the repository root (stdout)
#   lpos::engine_detect              container engine probing (docker first,
#                                    podman fallback) INCLUDING daemon
#                                    reachability; sets LPOS_ENGINE
#   lpos::ensure_binfmt_arm64        register the qemu-aarch64 binfmt handler
#                                    on x86_64 hosts (tonistiigi/binfmt)
#   lpos::host_is_aarch64            true when the host itself is aarch64
#   lpos::kvm_available              true when /dev/kvm is writable
#   lpos::hostfwd_tcp <port>         SAFE hostfwd spec — always 127.0.0.1
#   lpos::download <url> <dest>      curl/wget downloader with retries

lpos_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

lpos_warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

lpos_info() {
    printf '==> %s\n' "$*" >&2
}

# lpos::require_cmd <cmd> [<cmd>...]
# Fail fast when a host tool is missing; print an Arch-flavoured hint.
lpos::require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || \
            lpos_die "required tool '$c' not found in PATH — install it (Arch: pacman -S <pkg>) and re-run."
    done
}

# lpos::repo_root
# Resolve the repository root from this library's location (test/lib/ ->
# repo root) and validate it looks like the linuxphoneOS checkout.
lpos::repo_root() {
    local d
    d=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd) || lpos_die "cannot resolve repo root"
    if [ -d "$d/.planning" ] || [ -d "$d/.git" ]; then
        printf '%s\n' "$d"
        return 0
    fi
    d=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || \
        lpos_die "repo root validation failed (no .planning/.git marker above test/lib)"
    printf '%s\n' "$d"
}

# lpos::engine_detect
# Detect a usable container engine and export it as LPOS_ENGINE.
# docker is preferred, podman is the fallback. Detection ALWAYS includes
# daemon reachability ("docker info"), because a CLI without a daemon
# fails later in confusing ways. When the docker CLI exists but its daemon
# is unreachable and no working fallback exists, fail fast with the exact
# repair commands.
lpos::engine_detect() {
    if [ -n "${LPOS_ENGINE:-}" ]; then
        case "$LPOS_ENGINE" in
            docker|podman) ;;
            *) lpos_die "LPOS_ENGINE must be 'docker' or 'podman', got '$LPOS_ENGINE'" ;;
        esac
        if "$LPOS_ENGINE" info >/dev/null 2>&1; then
            return 0
        fi
        lpos_die "LPOS_ENGINE=$LPOS_ENGINE was forced but its daemon is unreachable ('${LPOS_ENGINE} info' failed)."
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            LPOS_ENGINE=docker
            export LPOS_ENGINE
            return 0
        fi
        lpos_warn "docker CLI present but daemon unreachable (docker info failed)."
        if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
            lpos_warn "falling back to podman (docker preferred, podman 兜底)."
            LPOS_ENGINE=podman
            export LPOS_ENGINE
            return 0
        fi
        cat >&2 <<'EOF'
Repair the docker engine, then start a fresh session (group membership is
evaluated at login) and re-run:

    sudo systemctl enable --now docker && sudo usermod -aG docker $USER

EOF
        lpos_die "no usable container engine: docker daemon is down and podman is unavailable."
    fi

    if command -v podman >/dev/null 2>&1; then
        if podman info >/dev/null 2>&1; then
            LPOS_ENGINE=podman
            export LPOS_ENGINE
            return 0
        fi
        lpos_die "podman CLI present but daemon unreachable (podman info failed)."
    fi

    lpos_die "no container engine found — install docker (pacman -S docker) or podman and re-run."
}

# lpos::ensure_binfmt_arm64
# On an x86_64 host, ensure the qemu-aarch64 binfmt_misc handler is
# registered with the F (fixed-binary/interpreter-always) flag so aarch64
# containers can run. Requires lpos::engine_detect to have run (uses the
# privileged tonistiigi/binfmt image, the standard registration path).
lpos::ensure_binfmt_arm64() {
    local reg=/proc/sys/fs/binfmt_misc/qemu-aarch64
    if [ "$(uname -m)" = "aarch64" ]; then
        return 0
    fi
    if [ -r "$reg" ] && grep -q '^flags:.*F' "$reg" 2>/dev/null; then
        return 0
    fi
    lpos_info "registering arm64 binfmt handlers (tonistiigi/binfmt --install arm64)..."
    [ -n "${LPOS_ENGINE:-}" ] || lpos_die "ensure_binfmt_arm64 requires engine_detect first"
    "$LPOS_ENGINE" run --privileged --rm tonistiigi/binfmt:master --install arm64
    if [ -r "$reg" ] && grep -q '^flags:.*F' "$reg" 2>/dev/null; then
        return 0
    fi
    lpos_die "arm64 binfmt registration did not take effect ($reg missing F flag)"
}

# lpos::host_is_aarch64 — true when the host itself is aarch64.
lpos::host_is_aarch64() {
    [ "$(uname -m)" = "aarch64" ]
}

# lpos::kvm_available — true when /dev/kvm exists and is writable.
lpos::kvm_available() {
    [ -w /dev/kvm ]
}

# lpos::hostfwd_tcp <host_port>
# T-01-06: every hostfwd in this harness binds 127.0.0.1 ONLY. Binding
# 0.0.0.0 would expose the throwaway root-SSH of the test VM to the local
# network. Always build hostfwd specs through this helper.
lpos::hostfwd_tcp() {
    local host_port="${1:?host port required}"
    printf 'tcp:127.0.0.1:%s-:22\n' "$host_port"
}

# lpos::download <url> <dest>
# Download with retries via curl (preferred) or wget.
lpos::download() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry 3 --output "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --output-document "$dest" "$url"
    else
        lpos_die "need curl or wget to download: $url"
    fi
}
