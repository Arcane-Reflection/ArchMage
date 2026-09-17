# common.sh — shared helpers for the ArchMage QEMU test harness.
#
# Sourced by test/*.sh. Callers own shell options (they run with
# `set -euo pipefail`); this library deliberately sets none so sourcing it
# never changes caller behaviour.
#
# Provides:
#   archmage::require_cmd <cmd>...      fail-fast tool probing
#   archmage::repo_root                  resolve the repository root (stdout)
#   archmage::engine_detect              container engine probing (docker first,
#                                    podman fallback) INCLUDING daemon
#                                    reachability; sets ARCHMAGE_ENGINE
#   archmage::ensure_binfmt_arm64        register the qemu-aarch64 binfmt handler
#                                    on x86_64 hosts (tonistiigi/binfmt)
#   archmage::host_is_aarch64            true when the host itself is aarch64
#   archmage::kvm_available              true when /dev/kvm is writable
#   archmage::hostfwd_tcp <port>         SAFE hostfwd spec — always 127.0.0.1
#   archmage::download <url> <dest>      curl/wget downloader with retries

archmage_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

archmage_warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

archmage_info() {
    printf '==> %s\n' "$*" >&2
}

# archmage::require_cmd <cmd> [<cmd>...]
# Fail fast when a host tool is missing; print an Arch-flavoured hint.
archmage::require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || \
            archmage_die "required tool '$c' not found in PATH — install it (Arch: pacman -S <pkg>) and re-run."
    done
}

# archmage::repo_root
# Resolve the repository root from this library's location (test/lib/ ->
# repo root) and validate it looks like the ArchMage checkout.
archmage::repo_root() {
    local d
    d=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd) || archmage_die "cannot resolve repo root"
    if [ -d "$d/.planning" ] || [ -d "$d/.git" ]; then
        printf '%s\n' "$d"
        return 0
    fi
    d=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || \
        archmage_die "repo root validation failed (no .planning/.git marker above test/lib)"
    printf '%s\n' "$d"
}

# archmage::engine_detect
# Detect a usable container engine and export it as ARCHMAGE_ENGINE.
# docker is preferred, podman is the fallback. Detection ALWAYS includes
# daemon reachability ("docker info"), because a CLI without a daemon
# fails later in confusing ways. When the docker CLI exists but its daemon
# is unreachable and no working fallback exists, fail fast with the exact
# repair commands.
archmage::engine_detect() {
    if [ -n "${ARCHMAGE_ENGINE:-}" ]; then
        case "$ARCHMAGE_ENGINE" in
            docker|podman) ;;
            *) archmage_die "ARCHMAGE_ENGINE must be 'docker' or 'podman', got '$ARCHMAGE_ENGINE'" ;;
        esac
        if "$ARCHMAGE_ENGINE" info >/dev/null 2>&1; then
            return 0
        fi
        archmage_die "ARCHMAGE_ENGINE=$ARCHMAGE_ENGINE was forced but its daemon is unreachable ('${ARCHMAGE_ENGINE} info' failed)."
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            ARCHMAGE_ENGINE=docker
            export ARCHMAGE_ENGINE
            return 0
        fi
        archmage_warn "docker CLI present but daemon unreachable (docker info failed)."
        if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
            archmage_warn "falling back to podman (docker preferred, podman 兜底)."
            ARCHMAGE_ENGINE=podman
            export ARCHMAGE_ENGINE
            return 0
        fi
        cat >&2 <<'EOF'
Repair the docker engine, then start a fresh session (group membership is
evaluated at login) and re-run:

    sudo systemctl enable --now docker && sudo usermod -aG docker $USER

EOF
        archmage_die "no usable container engine: docker daemon is down and podman is unavailable."
    fi

    if command -v podman >/dev/null 2>&1; then
        if podman info >/dev/null 2>&1; then
            ARCHMAGE_ENGINE=podman
            export ARCHMAGE_ENGINE
            return 0
        fi
        archmage_die "podman CLI present but daemon unreachable (podman info failed)."
    fi

    archmage_die "no container engine found — install docker (pacman -S docker) or podman and re-run."
}

# archmage::ensure_binfmt_arm64
# On an x86_64 host, ensure the qemu-aarch64 binfmt_misc handler is
# registered with the F (fixed-binary/interpreter-always) flag so aarch64
# containers can run. Requires archmage::engine_detect to have run (uses the
# privileged tonistiigi/binfmt image, the standard registration path).
archmage::ensure_binfmt_arm64() {
    local reg=/proc/sys/fs/binfmt_misc/qemu-aarch64
    if [ "$(uname -m)" = "aarch64" ]; then
        return 0
    fi
    if [ -r "$reg" ] && grep -q '^flags:.*F' "$reg" 2>/dev/null; then
        return 0
    fi
    archmage_info "registering arm64 binfmt handlers (tonistiigi/binfmt --install arm64)..."
    [ -n "${ARCHMAGE_ENGINE:-}" ] || archmage_die "ensure_binfmt_arm64 requires engine_detect first"
    "$ARCHMAGE_ENGINE" run --privileged --rm tonistiigi/binfmt:master --install arm64
    if [ -r "$reg" ] && grep -q '^flags:.*F' "$reg" 2>/dev/null; then
        return 0
    fi
    archmage_die "arm64 binfmt registration did not take effect ($reg missing F flag)"
}

# archmage::host_is_aarch64 — true when the host itself is aarch64.
archmage::host_is_aarch64() {
    [ "$(uname -m)" = "aarch64" ]
}

# archmage::kvm_available — true when /dev/kvm exists and is writable.
archmage::kvm_available() {
    [ -w /dev/kvm ]
}

# archmage::hostfwd_tcp <host_port>
# T-01-06: every hostfwd in this harness binds 127.0.0.1 ONLY. Binding
# 0.0.0.0 would expose the throwaway root-SSH of the test VM to the local
# network. Always build hostfwd specs through this helper.
archmage::hostfwd_tcp() {
    local host_port="${1:?host port required}"
    printf 'tcp:127.0.0.1:%s-:22\n' "$host_port"
}

# archmage::download <url> <dest>
# Download with retries via curl (preferred) or wget.
archmage::download() {
    local url="$1" dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry 3 --output "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --output-document "$dest" "$url"
    else
        archmage_die "need curl or wget to download: $url"
    fi
}
