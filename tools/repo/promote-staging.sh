#!/usr/bin/env bash
# promote-staging.sh — staging → stable 双通道发布链(03-03 Task 3,UPDATE-03)。
#
# 机器面边界(STRATEGY §8 / 03-RESEARCH Q4):
#   - CI 只产 staging;本脚本整体不进 CI —— 脚本级守卫:检测到
#     GITHUB_ACTIONS/CI 环境(无论 --dry-run 还是 --real)首行 stderr 打印
#     HUMAN_GATE 后退 2。
#   - --dry-run(默认):在 mktemp 的 GNUPGHOME 里现造一把临时 stable 密钥
#     走完整签名流程,并以临时根 pacman(SigLevel Required + 只含 stable
#     仓库)做客户端信任链闭环验证 —— 临时密钥仅证明流程可跑,不作信任源。
#   - --real:使用本机 GNUPGHOME 里的真实 stable 密钥(--key/STABLE_KEY_FPR
#     指定,且必须存在秘密钥)。密钥永不离开本机 GNUPGHOME;本脚本不读取、
#     不拷贝、不导出任何私钥。
#   - 真正的发布仪式(docs/REPO-CHANNELS.md):gh run download → sha256 核对
#     → 泡期人工检查 → 逐包 detach-sign → repo-add -s -k → 发布
#     db+db.sig+pkg+pkg.sig。脚本是仪式的机械骨架,不是仪式本身。
#
# 退出码:0 成功;1 失败;2 HUMAN_GATE_REQUIRED(CI 环境,专用码,不挪用)。
#
# Usage:
#   tools/repo/promote-staging.sh [--from-ci | --repo-dir PATH]
#                                 [--out-dir DIR] [--min-age-days N]
#                                 [--dry-run | --real]
#                                 [--key FPR]
#
# Options:
#   --from-ci         Download the staging-repo artifact of the latest
#                     successful packages.yml run on main via gh (01-01
#                     contract; same acquisition as mkrootfs).
#   --repo-dir PATH   Use an already-acquired staging artifact directory.
#   --out-dir DIR     Output directory (default: test/build/stable-dryrun in
#                     dry-run, test/build/stable in --real). Created fresh.
#   --min-age-days N  Minimum soak age of the staging artifact, measured
#                     from the staging database's mtime (default 3; the
#                     staging↔stable soak window is 3–7 days). Pass 0 to
#                     skip the gate — allowed in --dry-run only.
#   --key FPR         Signing fingerprint for --real (or STABLE_KEY_FPR env).
#                     Ignored in --dry-run (an ephemeral key is generated).
#   -h, --help        Show this help.
#
# Environment:
#   ARCHMAGE_GH_REPO   GitHub <owner>/<repo> for --from-ci
#                      (default: uMaj35ty/ArchMage)
#   STABLE_KEY_FPR     Default for --key in --real mode
#   GNUPGHOME          used as-is in --real mode (default ~/.gnupg)

set -euo pipefail

usage() {
    sed -n '2,60p' "$0" | grep -E '^#' | sed 's/^# \{0,1\}//'
}

die() {
    printf 'ERROR(promote-staging): %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# CI 人工门禁(最先执行,任何模式都拒绝):stable 签名不进自动化。
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI:-}" ]; then
    printf 'HUMAN_GATE: promote-staging.sh never runs in CI (stable signing is a maintainer-host ceremony, STRATEGY §8; docs/REPO-CHANNELS.md).\n' >&2
    printf 'HUMAN_GATE: run it on a maintainer machine with the real key in the local GNUPGHOME (--real), or locally for the --dry-run rehearsal.\n' >&2
    exit 2
fi

# Defaults ---------------------------------------------------------------
MODE=dry-run
SOURCE=""
REPO_DIR_ARG=""
OUT_DIR_ARG=""
MIN_AGE_DAYS=""
KEY_FPR="${STABLE_KEY_FPR:-}"
ARCHMAGE_GH_REPO=${ARCHMAGE_GH_REPO:-uMaj35ty/ArchMage}

while [ $# -gt 0 ]; do
    case "$1" in
        --from-ci) SOURCE=ci ;;
        --repo-dir)
            [ $# -ge 2 ] || die "--repo-dir needs a PATH argument"
            REPO_DIR_ARG=$2
            SOURCE=dir
            shift
            ;;
        --out-dir)
            [ $# -ge 2 ] || die "--out-dir needs a DIR argument"
            OUT_DIR_ARG=$2
            shift
            ;;
        --min-age-days)
            [ $# -ge 2 ] || die "--min-age-days needs a number"
            MIN_AGE_DAYS=$2
            shift
            ;;
        --dry-run) MODE=dry-run ;;
        --real) MODE=real ;;
        --key)
            [ $# -ge 2 ] || die "--key needs a fingerprint"
            KEY_FPR=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done
[ -n "$SOURCE" ] || SOURCE=ci
case "$MIN_AGE_DAYS" in
    '') if [ "$MODE" = real ]; then MIN_AGE_DAYS=3; else MIN_AGE_DAYS=0; fi ;;
    ''|*[!0-9]*) die "--min-age-days must be a non-negative integer, got '$MIN_AGE_DAYS'" ;;
esac
if [ "$MODE" = real ] && [ "$MIN_AGE_DAYS" -lt 3 ]; then
    die "the staging soak floor is 3 days (3–7 day window); --min-age-days $MIN_AGE_DAYS is only allowed with --dry-run"
fi

REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
# Base scratch dir, created in the PARENT shell: tmpdir() runs inside $(...)
# command substitutions, and an array append there is lost with the subshell
# (observed live: cleanup saw an empty TMPDIRS, every scratch dir leaked into
# /tmp, and the failing EXIT trap flipped the script's own exit status to 1).
# Everything lives under this one base; removing the base removes every
# tmpdir() artifact — ephemeral GNUPGHOMEs included.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/archmage-promote.XXXXXX")
cleanup() {
    if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
        # The client simulation runs pacman as root inside a container over
        # bind mounts — its files are root-owned on the host side, so a
        # plain user-space rm -rf cannot remove them (observed live). Hand
        # ownership back through the same engine before deleting.
        chmod -R u+w "$SCRATCH" 2>/dev/null || true
        rm -rf "$SCRATCH" 2>/dev/null || true
        if [ -d "$SCRATCH" ]; then
            local engine
            engine=$(command -v docker || command -v podman || true)
            if [ -n "$engine" ]; then
                "$engine" run --rm --platform linux/x86_64 \
                    -v "$SCRATCH":/scratch archlinux:base \
                    chown -R "$(id -u):$(id -g)" /scratch >/dev/null 2>&1 || true
                chmod -R u+w "$SCRATCH" 2>/dev/null || true
            fi
            rm -rf "$SCRATCH" 2>/dev/null || true
        fi
    fi
    # Best-effort: a cleanup failure must never override the script's own
    # exit status (the EXIT trap's rc would otherwise become the exit code).
    return 0
}
trap cleanup EXIT INT TERM

tmpdir() {
    local d
    d=$(mktemp -d "$SCRATCH/sub.XXXXXX")
    printf '%s' "$d"
}

info() { printf '==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1) Acquire the staging artifact (01-01 contract).
# ---------------------------------------------------------------------------
case "$SOURCE" in
    dir)
        STAGING_DIR=$REPO_DIR_ARG
        [ -d "$STAGING_DIR" ] || die "staging dir '$STAGING_DIR' does not exist"
        ;;
    ci)
        command -v gh >/dev/null 2>&1 || die "gh CLI not found (--from-ci needs it)"
        STAGING_DIR=$(tmpdir)/staging-repo
        run_id=$(gh run list -R "$ARCHMAGE_GH_REPO" --workflow packages.yml \
            --branch main --status success --limit 1 \
            --json databaseId --jq '.[0].databaseId')
        [ -n "$run_id" ] || die "no successful packages.yml run on main in $ARCHMAGE_GH_REPO yet"
        info "downloading staging-repo artifact from run $run_id"
        mkdir -p "$STAGING_DIR"
        gh run download -R "$ARCHMAGE_GH_REPO" "$run_id" \
            --name staging-repo --dir "$STAGING_DIR"
        ;;
esac
for f in cn.db.tar.zst cn.db.tar.zst.sig staging-key.asc FINGERPRINT.txt; do
    [ -s "$STAGING_DIR/$f" ] || die "staging artifact incomplete: $STAGING_DIR/$f missing"
done

# soak gate: the staging DB's mtime is the artifact timestamp (01-01
# artifacts are produced once per run; --from-ci downloads preserve no
# mtimes, so CI-acquired artifacts must be re-acquired after the soak or
# consumed from a --repo-dir copy that has rested on disk).
db_mtime=$(stat -c '%Y' "$STAGING_DIR/cn.db.tar.zst")
now=$(date +%s)
age_days=$(( (now - db_mtime) / 86400 ))
if [ "$age_days" -lt "$MIN_AGE_DAYS" ]; then
    die "staging artifact is ${age_days}d old (< ${MIN_AGE_DAYS}d soak floor) — let it rest (3–7 days), then re-run"
fi

# ---------------------------------------------------------------------------
# 2) Verify the staging input BEFORE trusting it (T-03-20): DB + every
#    package signature verified against the artifact's own staging key, and
#    a sha256 manifest recorded for the promote log.
# ---------------------------------------------------------------------------
STAGE_GNUPG=$(tmpdir)/gnupg
export GNUPGHOME=$STAGE_GNUPG
mkdir -p -m 700 "$STAGE_GNUPG"
gpg --batch --import "$STAGING_DIR/staging-key.asc" >/dev/null 2>&1
STAGE_FPR=$(awk '/^FINGERPRINT:/ {print $2}' "$STAGING_DIR/FINGERPRINT.txt")
[ -n "$STAGE_FPR" ] || die "cannot parse FINGERPRINT from $STAGING_DIR/FINGERPRINT.txt"
# NOTE: deliberately NO --lsign-key here — this throwaway GNUPGHOME holds no
# secret key, so a local trust signature is impossible (observed live: lsign
# fails "no default secret key"). `gpg --verify` is purely cryptographic: its
# exit code reflects signature validity against the imported public key and
# never consults the trustdb, so no trust edit is needed (T-03-20).

info "verifying staging DB + package signatures (staging key $STAGE_FPR)"
gpg --batch --verify "$STAGING_DIR/cn.db.tar.zst.sig" "$STAGING_DIR/cn.db.tar.zst" ||
    die "staging DB signature FAILED — refusing to promote unverified input"
sig_missing=""
while IFS= read -r pkg; do
    [ -s "$STAGING_DIR/$pkg.sig" ] || sig_missing="${sig_missing:+$sig_missing; }$pkg"
    gpg --batch --verify "$STAGING_DIR/$pkg.sig" "$STAGING_DIR/$pkg" 2>/dev/null ||
        die "package signature verification FAILED: $pkg"
done < <(find "$STAGING_DIR" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%f\n' | sort)
[ -z "$sig_missing" ] || die "packages without detached signatures: $sig_missing"

# sha256 manifest of everything consumed (provenance record).
MANIFEST=$STAGING_DIR/../promote-consumed.sha256
( cd "$STAGING_DIR" && sha256sum cn.db.tar.zst cn.db.tar.zst.sig *.pkg.tar.zst *.pkg.tar.zst.sig ) > "$MANIFEST"
unset GNUPGHOME
info "staging input verified: DB + $(find "$STAGING_DIR" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l) package signatures; manifest: $MANIFEST"

# ---------------------------------------------------------------------------
# 3) Signing key: ephemeral (dry-run) or the maintainer's real stable key.
# ---------------------------------------------------------------------------
OUT_DIR=$OUT_DIR_ARG
if [ -z "$OUT_DIR" ]; then
    if [ "$MODE" = real ]; then OUT_DIR=$REPO_ROOT/test/build/stable; else OUT_DIR=$REPO_ROOT/test/build/stable-dryrun; fi
fi
mkdir -p "$OUT_DIR"
# docker/podman bind mounts need an absolute host path (the client
# simulation mounts $OUT_DIR read-only); the default/argument may be
# relative to the caller's cwd.
OUT_DIR=$(cd -- "$OUT_DIR" && pwd)
rm -rf "${OUT_DIR:?}"/*

if [ "$MODE" = dry-run ]; then
    info "dry-run: generating an EPHEMERAL stable key in a throwaway GNUPGHOME (proves the flow, proves nothing about provenance)"
    SIGN_GNUPG=$(tmpdir)/sign-gnupg
    mkdir -p -m 700 "$SIGN_GNUPG"
    export GNUPGHOME=$SIGN_GNUPG
    gpg --batch --passphrase '' --quick-gen-key \
        "ArchMage stable (EPHEMERAL dry-run) <stable@archmage.invalid>" \
        rsa2048 sign 0 >/dev/null 2>&1
    SIGN_FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
    [ -n "$SIGN_FPR" ] || die "ephemeral key generation failed"
    info "ephemeral signing key: $SIGN_FPR (EPHEMERAL — never publish it)"
else
    [ -n "$KEY_FPR" ] || die "--real needs the stable key fingerprint (--key FPR or STABLE_KEY_FPR)"
    printf '%s' "$KEY_FPR" | grep -Eq '^[0-9A-Fa-f]{40}$' ||
        die "STABLE key fingerprint must be 40 hex chars, got '$KEY_FPR'"
    export GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"
    [ -d "$GNUPGHOME" ] || die "GNUPGHOME $GNUPGHOME does not exist"
    gpg --batch --list-secret-keys "$KEY_FPR" >/dev/null 2>&1 ||
        die "no secret key for $KEY_FPR in $GNUPGHOME — the stable signing ceremony happens on the maintainer host (docs/REPO-CHANNELS.md)"
    SIGN_FPR=$KEY_FPR
    info "real mode: signing with $SIGN_FPR from $GNUPGHOME"
fi

# ---------------------------------------------------------------------------
# 4) Publish layout: copy packages in, detach-sign each, sign the DB.
# ---------------------------------------------------------------------------
info "assembling stable repo in $OUT_DIR"
cp "$STAGING_DIR"/*.pkg.tar.zst "$OUT_DIR"/
while IFS= read -r pkg; do
    gpg --batch --yes --local-user "$SIGN_FPR" \
        --output "$OUT_DIR/$pkg.sig" --detach-sign "$OUT_DIR/$pkg"
done < <(find "$OUT_DIR" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%f\n' | sort)
# repo-add -s -k signs stable.db.tar.zst itself; --include-sigs embeds the
# per-package signatures into the DB (mandatory since repo-add 2021 stopped
# embedding them implicitly — packages.yml CI uses the same flag).
repo-add -s --include-sigs -k "$SIGN_FPR" \
    "$OUT_DIR/stable.db.tar.zst" "$OUT_DIR"/*.pkg.tar.zst >/dev/null
[ -s "$OUT_DIR/stable.db.tar.zst.sig" ] || die "repo-add did not produce a signed database"
# extensionless + legacy names for pacman>=6 clients.
ln -sfn stable.db.tar.zst "$OUT_DIR/stable.db"
ln -sfn stable.db.tar.zst.sig "$OUT_DIR/stable.db.sig"

# ---------------------------------------------------------------------------
# 5) Closure verification: the dry-run/real artifact must satisfy a real
#    client trust chain — SigLevel Required + ONLY the stable repo + the
#    signing key's public half in a throwaway pacman keyring.
# ---------------------------------------------------------------------------
info "verifying stable DB embeds every package signature (%PGPSIG%)"
DESCS=$(tar -tf "$OUT_DIR/stable.db.tar.zst" | grep -c 'desc$' || true)
PGPSIGS=$(tar -xOf "$OUT_DIR/stable.db.tar.zst" | grep -c '%PGPSIG%' || true)
if [ "${PGPSIGS:-0}" -ne "${DESCS:-0}" ] || [ "${DESCS:-0}" -eq 0 ]; then
    die "PGPSIG count ($PGPSIGS) != package entry count ($DESCS) — repo-add --include-sigs did not embed all signatures"
fi

info "client simulation: throwaway root, SigLevel Required, stable repo only"
CLIENT_GNUPG=$(tmpdir)/client-pacman-gnupg
CLIENT_ROOT=$(tmpdir)/client-root
mkdir -p -m 700 "$CLIENT_GNUPG" "$CLIENT_ROOT/var/lib/pacman" "$CLIENT_ROOT/var/cache/pacman/pkg"
# Trust bootstrap WITHOUT pacman-key: pacman-key --init/--lsign-key refuse to
# run as non-root (observed live: "pacman-key 需要以 root 运行"). Plain gpg is
# root-free: import the signing key's public half and mark it ultimately
# trusted via ownertrust — gpgme (pacman's verifier) then reports ultimate
# validity, exactly what a populated keyring produces (docs/REPO-CHANNELS §4).
STABLE_PUB=$(tmpdir)/stable-pub.asc
gpg --batch --homedir "$GNUPGHOME" --export "$SIGN_FPR" > "$STABLE_PUB"
gpg --batch --homedir "$CLIENT_GNUPG" --import "$STABLE_PUB" >/dev/null 2>&1
printf '%s:6:\n' "$SIGN_FPR" |
    gpg --batch --homedir "$CLIENT_GNUPG" --import-ownertrust >/dev/null 2>&1

CLIENT_CONF=$(tmpdir)/pacman-client.conf
cat > "$CLIENT_CONF" <<EOF
[options]
Architecture = x86_64
# Strictest client policy: BOTH the database and the packages must verify
# against the imported stable key alone.
SigLevel = Required
NoProgressBar
# Throwaway verification root only — never a shipped config (01-02 rule).
DisableSandbox

[stable]
Server = file://$OUT_DIR
EOF

# The client transaction itself needs real root (pacman refuses install
# operations as a normal user, observed live) — same host/container split as
# the test harness: as root it runs directly, otherwise it re-runs inside an
# archlinux container with the throwaway dirs bind-mounted.
client_pacman() {
    local conf=$1
    shift
    if [ "$(id -u)" -eq 0 ]; then
        pacman --root "$CLIENT_ROOT" --config "$conf" --gpgdir "$CLIENT_GNUPG" "$@"
        return
    fi
    local engine
    engine=$(command -v docker || command -v podman || true)
    [ -n "$engine" ] ||
        die "client simulation needs root or a container engine (docker/podman) to run pacman's install transaction"
    local cconf
    cconf=$(tmpdir)/pacman-client-container.conf
    sed 's|file://'"$OUT_DIR"'|file:///stable|' "$conf" > "$cconf"
    "$engine" run --rm --platform linux/x86_64 \
        -v "$CLIENT_ROOT":/client-root \
        -v "$CLIENT_GNUPG":/client-gnupg \
        -v "$cconf":/client.conf:ro \
        -v "$OUT_DIR":/stable:ro \
        archlinux:base \
        pacman --root /client-root --config /client.conf --gpgdir /client-gnupg "$@"
}

# The client installs one target from the stable repo alone; any dependencies
# that live outside the channel are assumed-installed (this rehearsal proves
# the SIGNATURE trust chain, not dependency resolution).
TARGET=$(find "$OUT_DIR" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%f\n' | sort | head -1)
[ -n "$TARGET" ] || die "no packages in the stable repo output"
# %NAME% carries neither pkgver/pkgrel nor arch (makepkg forbids dashes in
# pkgver/pkgrel) — strip the "-ver-rel-arch" tail to get the pacman target.
TARGET=${TARGET%.pkg.tar.zst}
TARGET_NAME=${TARGET%-*-*-*}
DB_EXTRACT=$(tmpdir)/db
mkdir -p "$DB_EXTRACT"
tar -xf "$OUT_DIR/stable.db.tar.zst" -C "$DB_EXTRACT"
DESC_FILE=""
for d in "$DB_EXTRACT"/*/desc; do
    [ -f "$d" ] || continue
    if [ "$(awk '/^%NAME%$/ { getline; print }' "$d")" = "$TARGET_NAME" ]; then
        DESC_FILE=$d
        break
    fi
done
[ -n "$DESC_FILE" ] || die "no desc entry for $TARGET_NAME in the stable DB"

# deps_of <desc-file>: the %DEPENDS% entries (version constraints kept —
# --assume-installed accepts full dep strings).
deps_of() {
    awk '/^%DEPENDS%$/ { ind = 1; next }
         /^%/         { ind = 0 }
         ind          { gsub(/^[[:space:]]+/, ""); if (NF) print }' "$1"
}

# Dependency closure over the stable DB: a dep the channel itself satisfies
# is resolved (and verified) by pacman FROM the stable repo — its own deps
# are walked recursively — while everything outside the channel (official
# mirror deps of the channel packages, e.g. opencc/networkmanager) is
# assume-installed. The rehearsal proves the SIGNATURE trust chain, not
# dependency resolution against Arch mirrors. (Naively assume-installing
# only the target's direct deps is wrong in BOTH directions: channel deps
# would be virtual instead of really installed+verified, and their own
# official deps would be left unresolved — observed live.)
repo_pkgs=$(awk '/^%NAME%$/ { getline; print }' "$DB_EXTRACT"/*/desc | sort -u)
declare -A VISITED=()
ASSUME=()
walk_deps() {
    local dep=$1 base d
    base=${dep%%[<>=]*}
    [ -n "$base" ] || return 0
    [ -n "${VISITED[$base]:-}" ] && return 0
    VISITED[$base]=1
    if printf '%s\n' "$repo_pkgs" | grep -qx "$base"; then
        for d in "$DB_EXTRACT"/*/desc; do
            [ -f "$d" ] || continue
            [ "$(awk '/^%NAME%$/ { getline; print }' "$d")" = "$base" ] || continue
            local -a SUBDEPS=()
            mapfile -t SUBDEPS < <(deps_of "$d")
            local sd
            for sd in "${SUBDEPS[@]:-}"; do
                [ -n "$sd" ] && walk_deps "$sd"
            done
            break
        done
    else
        ASSUME+=(--assume-installed "$dep")
    fi
}
mapfile -t DEPS < <(deps_of "$DESC_FILE" | sort -u)
for d in "${DEPS[@]:-}"; do
    [ -n "$d" ] && walk_deps "$d"
done
info "client deps: $(find "$DB_EXTRACT" -mindepth 1 -maxdepth 1 -type d | wc -l) package(s) resolved from the channel, ${#ASSUME[@]} assume-installed outside dep(s)"
CLIENT_LOG=$(tmpdir)/client-pacman.log
if ! client_pacman "$CLIENT_CONF" --noconfirm -Sy "${ASSUME[@]}" \
        "$TARGET_NAME" >"$CLIENT_LOG" 2>&1; then
    sed 's/^/  | /' "$CLIENT_LOG" >&2
    die "client simulation FAILED: pacman could not install $TARGET_NAME from the stable repo under SigLevel Required (trust chain broken)"
fi
if ! client_pacman "$CLIENT_CONF" -Q "$TARGET_NAME" >"$CLIENT_LOG" 2>&1; then
    sed 's/^/  | /' "$CLIENT_LOG" >&2
    die "client simulation: package not registered in the throwaway root"
fi

( cd "$OUT_DIR" && sha256sum stable.db.tar.zst stable.db.tar.zst.sig *.pkg.tar.zst *.pkg.tar.zst.sig ) \
    > "$OUT_DIR/promote-produced.sha256"
unset GNUPGHOME

info "DONE ($MODE): stable repo verified end to end -> $OUT_DIR"
info "  DB: stable.db.tar.zst (+.sig, $DESCS packages, per-pkg sigs embedded)"
info "  client chain: SigLevel Required + imported stable pubkey -> install OK"
if [ "$MODE" = dry-run ]; then
    info "  NOTE: every signature above came from an EPHEMERAL key — this is a flow rehearsal only (docs/REPO-CHANNELS.md for the real ceremony)"
fi
exit 0
