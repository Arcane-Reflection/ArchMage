#!/usr/bin/env bash
# bootstrap.sh — drive kupferbootstrap (kbs) to build the ArchMage OP6 image
# (profile archmage-op6-phosh, device sdm845-oneplus-enchilada, flavour
# phosh), layering the CN defaults from the ArchMage staging repo into the
# image with full signature discipline.
#
# Host/container split (same pattern as test/mkrootfs-aarch64.sh, 01-02):
#   HOST    (any engine host, e.g. the ubuntu-24.04-arm CI runner):
#           normalize the downloaded staging artifact layout, then re-exec
#           this script inside a privileged aarch64 arch container.
#   CONTAINER (--inner; menci/archlinuxarm:base, root):
#           install kbs pinned by bootstrap/kbs-version.txt, stage the
#           config, and run the three build stages.
#
# The three stages (why: kbs's image transaction runs `pacstrap -G` into a
# fresh rootfs that has NO pacman keyring, with every repo in the build-time
# pacman.conf at the upstream SigLevel Never because kupfer prebuilts are
# unsigned — a SigLevel Required repo cannot pass a keyring-less
# transaction; verified against kbs chroot/base.py, distro/distro.py and
# distro/repo_config.py at the pinned tag):
#
#   stage 1  `kbs image build archmage-op6-phosh-build`
#            Upstream image assembly: ALARM base + kupfer device/flavour/
#            phosh packages. The build-time repos.local.yml written into the
#            pkgbuilds checkout is the canonical bootstrap/repos.local.yml
#            WITHOUT the archmage section, and the build profile excludes
#            the staging-repo packages — archmage-cn plus the 02-03 overlays
#            (see bootstrap/archmage.toml).
#   stage 2  CN + overlay layer via OUR pacman transaction, signature-
#            verified: the staging key is imported + locally signed into the
#            image's pacman keyring, then `pacman -r` installs the
#            pkgs_include set (archmage-cn and the 02-03 overlays such as
#            archmage-phosh-safety) from the staging repo with SigLevel
#            Required (the signed database is verified too). Foreign-root
#            keyring surgery identical to
#            test/mkrootfs-aarch64.sh (01-02). The seeded keyring ships in
#            the image, so on-device pacman trusts exactly what built it.
#   stage 3  Harden the shipped /etc/pacman.conf:
#            - ALARM sections (core/extra/community/alarm/aur[+-testing])
#              drop the build-time `SigLevel = Never` override so the global
#              `Required DatabaseOptional` written by kbs applies (ALARM
#              distributes signed packages but unsigned databases).
#            - kupfer prebuilt sections keep their upstream `SigLevel =
#              Never` verbatim (their prebuilts are unsigned; upstream
#              policy, not an ArchMage weakening).
#            - the [archmage] section (SigLevel = Required) is appended from
#              the canonical bootstrap/repos.local.yml.
#
# Usage:
#   bootstrap/bootstrap.sh --staging-dir PATH   # full build (containerized)
#   bootstrap/bootstrap.sh --install-only       # toolchain + config only
#   bootstrap/bootstrap.sh --check              # offline config self-check
#
# Internal flag (do not pass): --inner — re-executed inside the build
# container by the host phase.
#
# Never executed: curl|bash-style remote scripts; pip only installs the
# pinned upstream kbs tag from gitlab.com/kupfer (official source).

set -euo pipefail

usage() {
    cat <<'EOF'
bootstrap.sh — build the ArchMage OP6 image via kupferbootstrap

Usage:
  bootstrap/bootstrap.sh --staging-dir PATH [options]   full build
  bootstrap/bootstrap.sh --install-only                 install kbs + stage
                                                        and validate config,
                                                        no image build
  bootstrap/bootstrap.sh --check                        offline self-check of
                                                        bootstrap/ config
                                                        files (no engine)

Options:
  --staging-dir PATH  Directory of the downloaded packages.yml staging-repo
                      artifact (cn.db.tar.zst + .sig + staging-key.asc +
                      FINGERPRINT.txt + package files). Flat and $arch/$repo
                      layouts are both auto-detected and normalized.
  --install-only      Stop after kbs installation and config validation.
  --check             Parse and structurally assert bootstrap/archmage.toml
                      and bootstrap/repos.local.yml; verify the version pin.
                      Needs python3 (tomllib + yaml). No container engine.
  -h, --help          Show this help.

Environment:
  ARCHMAGE_ENGINE     Container engine override (docker|podman), else
                      autodetected with daemon reachability check.
  ARCHMAGE_HOST_UID   Set by the host phase; container phase hands build
                      outputs back to this uid.

Outputs (bootstrap/.work/, gitignored):
  kupfer/images/sdm845-oneplus-enchilada-phosh-boot.img   boot partition (ext4)
  kupfer/images/sdm845-oneplus-enchilada-phosh-root.img   rootfs partition (ext4)
  kupfer/images/sdm845-oneplus-enchilada-phosh-full.img   full flashable image
  kupfer/images/sdm845-oneplus-enchilada-aboot.img        Android boot image
                                                         (extracted from the
                                                         boot partition, for
                                                         `fastboot flash boot`)
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

MODE=""
STAGING_DIR=""
INNER=no
while [ $# -gt 0 ]; do
    case "$1" in
        --staging-dir)
            [ $# -ge 2 ] || die "--staging-dir needs a PATH argument"
            STAGING_DIR=$2
            MODE=build
            shift
            ;;
        --install-only)
            MODE=install-only
            ;;
        --check)
            MODE=check
            ;;
        --inner)
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
[ -n "$MODE" ] || { usage >&2; die "one of --staging-dir / --install-only / --check is required"; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=../test/lib/common.sh
source "$REPO_ROOT/test/lib/common.sh"

BOOTSTRAP_DIR=$REPO_ROOT/bootstrap
WORK_DIR=$BOOTSTRAP_DIR/.work
KBS_VERSION_FILE=$BOOTSTRAP_DIR/kbs-version.txt
CANONICAL_REPOS_YML=$BOOTSTRAP_DIR/repos.local.yml
KBS_TOML=$BOOTSTRAP_DIR/archmage.toml

# kbs-side constants (must match bootstrap/archmage.toml [paths] and the
# profile in it).
CONTAINER_REPO=/work
KBS_CACHE=$WORK_DIR/kupfer
KBS_PKG_BUILDS=$KBS_CACHE/pkgbuilds
KBS_IMAGES=$KBS_CACHE/images
KBS_DEVICE=sdm845-oneplus-enchilada
KBS_FLAVOUR=phosh
KBS_PROFILE=archmage-op6-phosh
KBS_BUILD_PROFILE=archmage-op6-phosh-build
BUILD_CONTAINER=menci/archlinuxarm:base
CONTAINER_STAGING=/staging

kbs_version() {
    local v
    v=$(tr -d '[:space:]' < "$KBS_VERSION_FILE")
    [ -n "$v" ] || die "$KBS_VERSION_FILE is empty — write the pinned kupferbootstrap tag (e.g. v0.3.0-rc0)"
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# Offline config self-check (--check; also reused as the container-side
# validation after staging the config).
# ---------------------------------------------------------------------------
check_config_files() {
    local python="${ARCHMAGE_PYTHON:-python3}"
    command -v "$python" >/dev/null 2>&1 || die "python3 required for the config self-check"
    "$python" -c "import yaml, tomllib" 2>/dev/null || \
        die "the config self-check needs python3 with tomllib (>=3.11) and PyYAML"
    local kbs_ver
    kbs_ver=$(kbs_version)
    "$python" - "$KBS_TOML" "$CANONICAL_REPOS_YML" "$kbs_ver" <<'PYEOF'
import sys, tomllib
import yaml

toml_path, repos_path, kbs_ver = sys.argv[1], sys.argv[2], sys.argv[3]

cfg = tomllib.load(open(toml_path, 'rb'))
prof = cfg['profiles'][prof_name := 'archmage-op6-phosh']
assert prof['device'] == 'sdm845-oneplus-enchilada', 'device drifted'
assert prof['flavour'] == 'phosh', 'flavour drifted'
assert 'archmage-cn' in prof['pkgs_include'], 'pkgs_include lost archmage-cn'
assert cfg['wrapper']['type'] == 'none', 'wrapper type must stay none'
assert cfg['profiles'].get('current') == prof_name, 'current profile drifted'
build_prof = cfg['profiles']['archmage-op6-phosh-build']
assert build_prof['parent'] == prof_name, 'build profile parent drifted'
assert 'archmage-cn' in build_prof.get('pkgs_exclude', []), 'build profile must exclude archmage-cn (two-stage design)'
# 02-03: every staging-repo overlay in pkgs_include must ride the same
# two-stage design (stage-1 exclude + stage-2 verified install), otherwise
# the keyring-less kbs transaction would fail or the package never lands.
# 03-03: archmage-btrfs-rollback rides the same pattern (its install
# scriptlet weak-binds to btrfs roots, so the ext4 kbs rootfs simply skips
# the snapper configuration — verified by verify-image's btrfs_layout gate
# on the x86_64 btrfs image instead).
# 03-01: archmage-fcitx5-osk rides the same pattern too (it Conflicts
# squeekboard; the kupfer phosh flavour package set must never pull both —
# stage-2 installs ours over whatever the flavour stage left, and the
# pacman transaction's conflict handling removes squeekboard if present).
# 03-02: waydroid + archmage-waydroid-config ride the same pattern (the
# Android-in-container runtime + its ArchMage factory layer; the vendored
# waydroid PKGBUILD lives in overlay/apps/waydroid with its DIVERGENCE
# ledger, the factory config in overlay/apps/archmage-waydroid-config).
OVERLAYS = ('archmage-phosh-safety', 'archmage-cn-apn', 'archmage-btrfs-rollback', 'archmage-fcitx5-osk', 'waydroid', 'archmage-waydroid-config')
for overlay in OVERLAYS:
    assert overlay in prof['pkgs_include'], f'pkgs_include lost {overlay}'
    assert overlay in build_prof.get('pkgs_exclude', []), \
        f'build profile must exclude {overlay} (two-stage design)'

repos = yaml.safe_load(open(repos_path))
assert repos['repos']['archmage']['options']['SigLevel'] == 'Required', 'archmage SigLevel must be Required'
for needed in ('main', 'device', 'phosh', 'boot', 'firmware', 'linux', 'cross'):
    assert needed in repos['repos'], f'repos.local.yml lost upstream repo {needed}'
for arch in ('x86_64', 'aarch64', 'armv7h'):
    assert arch in repos.get('base_distros', {}), f'repos.local.yml lost base_distro {arch}'
assert 'DatabaseOptional' not in yaml.dump(repos), 'weakening database token found'
assert kbs_ver.startswith('v') and kbs_ver[1:].count('.') == 2, f'bad kbs version pin: {kbs_ver!r}'
print(f'config self-check OK (kbs pin {kbs_ver})')
PYEOF
}

# ---------------------------------------------------------------------------
# Staging artifact layout normalization.
#
# kupferbootstrap substitutes $arch/$repo into remote_url templates only
# when the tokens are present (distro/repo.py resolve_url); our archmage
# remote_url is a token-less flat file:// URL, so pacman resolves it
# literally and asks for `archmage.db` in that directory. The packages.yml
# artifact names its database cn.db.tar.zst, so we symlink the canonical
# pacman names next to it. Both the flat artifact layout and a pre-split
# $arch/$repo layout are supported: the server directory is wherever
# cn.db.tar.zst actually lives.
# ---------------------------------------------------------------------------
# Sets STAGING_REL (server dir relative to the staging root, '' for flat).
detect_staging_layout() {
    local root="$1"
    [ -s "$root/cn.db.tar.zst" ] && { STAGING_REL=""; return 0; }
    local found
    found=$(find "$root" -mindepth 2 -maxdepth 4 -name cn.db.tar.zst -print -quit 2>/dev/null || true)
    [ -n "$found" ] || die "no cn.db.tar.zst under '$root' — is this a packages.yml staging-repo artifact?"
    STAGING_REL=${found#"$root"/}
    STAGING_REL=${STAGING_REL%/cn.db.tar.zst}
    STAGING_REL=${STAGING_REL%/}
}

normalize_staging() {
    local root="$1" server_dir rel
    [ -d "$root" ] || die "staging dir '$root' does not exist"
    for f in cn.db.tar.zst staging-key.asc FINGERPRINT.txt; do
        local hit
        hit=$(find "$root" -maxdepth 4 -name "$f" -print -quit 2>/dev/null || true)
        [ -n "$hit" ] || die "staging dir '$root' is missing required file '$f'"
    done
    detect_staging_layout "$root"
    server_dir=$root
    [ -z "$STAGING_REL" ] || server_dir=$root/$STAGING_REL
    # pacman>=6 requests the extensionless <repo>.db first; symlink both the
    # canonical and legacy names to the artifact's zst database. 03-03
    # two-channel: the shipped /etc/pacman.conf declares [archmage-testing]
    # (the CI staging channel), and pacman requests <section>.db per section
    # name — so the testing-channel DB name is provided alongside.
    ln -sfn cn.db.tar.zst "$server_dir/archmage.db"
    [ -s "$server_dir/cn.db.tar.zst.sig" ] && ln -sfn cn.db.tar.zst.sig "$server_dir/archmage.db.sig" || true
    ln -sfn cn.db.tar.zst "$server_dir/archmage-testing.db"
    [ -s "$server_dir/cn.db.tar.zst.sig" ] && ln -sfn cn.db.tar.zst.sig "$server_dir/archmage-testing.db.sig" || true
    if grep -q '^EPHEMERAL: yes' "$(find "$root" -maxdepth 4 -name FINGERPRINT.txt -print -quit)" 2>/dev/null; then
        archmage_warn "staging artifact was signed with an EPHEMERAL run key (GPG_PRIVATE_KEY secret not configured). It is still consumed for this image build, but signatures only prove the run's own integrity, not ArchMage provenance — configure the persistent staging key."
    fi
    archmage_info "staging server dir: ${STAGING_REL:-<flat root>} (archmage.db + archmage-testing.db -> cn.db.tar.zst)"
}

# ---------------------------------------------------------------------------
# HOST phase
# ---------------------------------------------------------------------------
host_main() {
    if [ "$MODE" = check ]; then
        check_config_files
        archmage_info "bootstrap/ config self-check passed (no engine needed)"
        return 0
    fi

    [ -n "$STAGING_DIR" ] || die "--staging-dir is required for a build"
    STAGING_DIR=$(cd -- "$STAGING_DIR" && pwd)
    [ -d "$STAGING_DIR" ] || die "staging dir '$STAGING_DIR' does not exist"

    normalize_staging "$STAGING_DIR"

    archmage::engine_detect
    archmage_info "building inside $BUILD_CONTAINER (privileged: kbs needs losetup/mount; arm64: native build on aarch64 runners)"
    local -a run_args=(
        --rm --privileged --platform linux/arm64
        -e ARCHMAGE_HOST_UID="$(id -u)"
        -v "$REPO_ROOT":"$CONTAINER_REPO" -w "$CONTAINER_REPO"
        -v "$STAGING_DIR":"$CONTAINER_STAGING"
    )
    local -a inner_args=(--inner --staging-dir "$CONTAINER_STAGING")
    [ "$MODE" = install-only ] && inner_args+=(--install-only)
    "$ARCHMAGE_ENGINE" run "${run_args[@]}" "$BUILD_CONTAINER" \
        bash bootstrap/bootstrap.sh "${inner_args[@]}"
}

# ---------------------------------------------------------------------------
# CONTAINER phase (--inner)
# ---------------------------------------------------------------------------
container_main() {
    [ "$(uname -m)" = aarch64 ] || die "container phase requires aarch64 (native build); run on an arm64 host/runner — cross builds are intentionally unsupported"

    archmage::require_cmd pacman

    local kbs_ver
    kbs_ver=$(kbs_version)
    archmage_info "pinned kupferbootstrap: $kbs_ver"

    # 1) Toolchain (ALARM official repos only, TUNA mirror for speed).
    printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo\n' \
        > /etc/pacman.d/mirrorlist
    # pacman 7's landlock/seccomp sandbox is unavailable inside this
    # ephemeral build container (observed: "Landlock is not supported by the
    # kernel" on containerized ALARM). The container itself is a throwaway
    # root, so its OWN /etc/pacman.conf disables the sandbox — same scope
    # rule as 01-02: throwaway roots only, never shipped configs.
    if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
        sed -i 's/^\[options\]$/[options]\nDisableSandbox/' /etc/pacman.conf
    fi
    # rsync is mandatory: kbs chroot/build.py clones base_aarch64 with
    # `rsync -a --delete` and swallows the "command not found" stderr, so a
    # missing rsync only surfaces as "Failed to copy base_aarch64" after the
    # whole pacstrap. parted/e2fsprogs cover partprobe/e2fsck/resize2fs which
    # kbs image/image.py calls at host level.
    pacman -Sy --noconfirm --needed \
        arch-install-scripts base-devel git e2fsprogs parted rsync sudo openssh \
        archlinuxarm-keyring
    archmage::require_cmd makepkg pacstrap losetup debugfs mkfs.ext4 git python3 \
        rsync parted partprobe e2fsck resize2fs ssh-keygen

    # Patch out makepkg's root refusal at container level — verbatim from the
    # upstream kbs Dockerfile. kbs (as root) shells out to makepkg for PKGBUILD
    # srcinfo parsing and re-patches the chroot's own makepkg copy itself. A
    # `sudo -u builduser` PATH wrapper here instead breaks srcinfo parsing with
    # "no write permission for $BUILDDIR" on the root-owned pkgbuilds checkout
    # (observed live, 2026-10-05 CI run 37253509343).
    sed -i "s/EUID == 0/EUID == -1/g" /usr/bin/makepkg
    makepkg --version

    # 2) kbs from the pinned upstream tag (official gitlab.com/kupfer source).
    local venv=/opt/kbs-venv
    [ -x "$venv/bin/kupferbootstrap" ] || {
        python3 -m venv "$venv"
        "$venv/bin/pip" install --quiet \
            "git+https://gitlab.com/kupfer/kupferbootstrap.git@${kbs_ver}"
    }
    KBS_BIN=$venv/bin/kupferbootstrap
    KBS_PY=$venv/bin/python
    local installed
    installed=$("$KBS_BIN" version 2>/dev/null || printf 'unknown (no .git after pip install; pin is %s)' "$kbs_ver")
    archmage_info "kupferbootstrap installed: $installed (pin: $kbs_ver)"

    # 3) Stage the effective config; validate structure.
    mkdir -p "$WORK_DIR" "$KBS_CACHE"
    cp "$KBS_TOML" "$WORK_DIR/kupferbootstrap.toml"
    ARCHMAGE_PYTHON=$KBS_PY
    check_config_files
    # kbs runs as root (privileged container, upstream design); chroot
    # internals that must not be root are handled by kbs itself (it patches
    # the chroot's makepkg EUID check) — a `sudo -u kupfer` wrapper here
    # breaks os.path.exists/ownership assumptions in create_rootfs.
    kbs() { "$KBS_BIN" -C "$WORK_DIR/kupferbootstrap.toml" "$@"; }

    if [ "$MODE" = install-only ]; then
        # CLI smoke: --help short-circuits before the -C config load, hence
        # the suppressed default-config warning.
        "$KBS_BIN" --help >/dev/null 2>&1
        archmage_info "--install-only complete: kbs $kbs_ver ready, config staged at $WORK_DIR/kupferbootstrap.toml"
        return 0
    fi

    # 4) pkgbuilds checkout + build-variant repos.local.yml + drift check.
    archmage_info "kbs packages init (clones pkgbuilds @ dev into $KBS_PKG_BUILDS)"
    kbs packages init

    "$KBS_PY" - "$CANONICAL_REPOS_YML" "$KBS_PKG_BUILDS/repos.yml" \
        "$KBS_PKG_BUILDS/repos.local.yml" <<'PYEOF'
import sys, yaml

canonical_path, upstream_path, out_path = sys.argv[1:4]
canonical = yaml.safe_load(open(canonical_path))
upstream = yaml.safe_load(open(upstream_path))

repos = dict(canonical['repos'])
injected = repos.pop('archmage', None)
assert injected is not None, 'canonical repos.local.yml lost the archmage section'

# Drift check (REPLACES semantics: our file must cover the full upstream
# key set). Missing upstream keys would silently break kbs package
# resolution after upstream evolves.
missing = set(upstream['repos']) - set(repos)
assert not missing, (
    'repos.local.yml is missing upstream repos present in the pinned '
    f'pkgbuilds repos.yml: {sorted(missing)} — re-sync bootstrap/repos.local.yml '
    'against the new pin (copy upstream repos.yml verbatim, re-add the archmage section)'
)
for arch, udef in upstream.get('base_distros', {}).items():
    ours = canonical.get('base_distros', {}).get(arch)
    assert ours is not None, f'repos.local.yml lost base_distro {arch}'
    m = set(udef.get('repos', {})) - set(ours.get('repos', {}))
    assert not m, f'base_distros[{arch}] missing upstream repos {sorted(m)} — re-sync per new pin'

header = (
    '# BUILD VARIANT — generated by bootstrap/bootstrap.sh from the canonical\n'
    '# bootstrap/repos.local.yml (upstream repos.yml verbatim, archmage section\n'
    '# REMOVED). The kbs image transaction runs pacstrap -G with no target\n'
    '# keyring, so a SigLevel Required repo cannot pass it; the CN layer is\n'
    '# installed afterwards by bootstrap.sh stage 2 with full verification.\n'
)
with open(out_path, 'w') as fd:
    fd.write(header)
    yaml.safe_dump({'kbs_ci_version': canonical.get('kbs_ci_version'),
                    'kbs_min_version': canonical.get('kbs_min_version'),
                    'remote_url': canonical.get('remote_url'),
                    'repos': repos,
                    'base_distros': canonical['base_distros']}, fd, sort_keys=False)
print(f'build-variant repos.local.yml written: {len(repos)} repos (archmage held for stage 2/3)')
PYEOF

    # gitlab.alpinelinux.org fronts raw file downloads with an anti-bot proxy
    # (go-away, HTTP 418) that blocks datacenter runners, and hexagonrpcd pulls
    # its udev rule from an aports commit there. The same commits are mirrored
    # on raw.githubusercontent.com (content identical, checksums unaffected) —
    # rewrite the host before kbs builds anything. Generic loop: any future
    # PKGBUILD referencing aports raw gets the same treatment.
    local aports_hits
    aports_hits=$(grep -rl --include=PKGBUILD \
        "gitlab.alpinelinux.org/alpine/aports/-/raw" "$KBS_PKG_BUILDS" || true)
    if [ -n "$aports_hits" ]; then
        while IFS= read -r f; do
            sed -i 's#gitlab\.alpinelinux\.org/alpine/aports/-/raw/#raw.githubusercontent.com/alpinelinux/aports/#' "$f"
            archmage_info "aports raw -> github mirror: $f"
        done <<< "$aports_hits"
    fi

    # 5) Stage 1 — upstream image assembly.
    # kbs copy_ssh_keys asks via click.confirm to generate a host ssh key
    # when $HOME/.ssh has none — that prompt aborts headless (no TTY) and
    # killed the run 37256733476 right after the rootfs pacstrap. Pre-create
    # an ephemeral per-run key so the flow stays non-interactive; kbs copies
    # its pubkey into the image's authorized_keys (throwaway with the runner).
    if [ ! -f /root/.ssh/id_ed25519 ]; then
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        ssh-keygen -f /root/.ssh/id_ed25519 -t ed25519 -N "" -C archmage-ci-ephemeral
    fi

    archmage_info "stage 1: kbs image build $KBS_BUILD_PROFILE"
    kbs image build "$KBS_BUILD_PROFILE"

    local root_img=$KBS_IMAGES/$KBS_DEVICE-$KBS_FLAVOUR-root.img
    local boot_img=$KBS_IMAGES/$KBS_DEVICE-$KBS_FLAVOUR-boot.img
    [ -s "$root_img" ] || die "kbs did not produce $root_img"
    [ -s "$boot_img" ] || die "kbs did not produce $boot_img"

    # 6) Stage 2 — CN layer, signature-verified, foreign-root pattern (01-02).
    normalize_staging "$STAGING_DIR"
    local stage2_server="file://$CONTAINER_STAGING"
    [ -n "$STAGING_REL" ] && stage2_server="$stage2_server/$STAGING_REL"

    local mnt=/mnt/archmage-rootfs gpgdir
    mkdir -p "$mnt"
    # Hardcode the mountpoint: after a set -e failure inside container_main,
    # bash unwinds the frame BEFORE running the EXIT trap, so `local` vars
    # are gone and "$mnt" would die under set -u (run 37258537871).
    cleanup_mount() {
        umount /mnt/archmage-rootfs/dev 2>/dev/null || true
        umount /mnt/archmage-rootfs/sys 2>/dev/null || true
        umount /mnt/archmage-rootfs/proc 2>/dev/null || true
        umount /mnt/archmage-rootfs 2>/dev/null || true
    }
    # Scriptlet-visible kernel mounts: `pacman -r` chroots scriptlets and
    # alpm hooks into the image, and mkinitcpio hooks hard-fail without
    # /proc ("==> ERROR: /proc must be mounted!", run 37260366462) — the
    # archmage-btrfs-rollback initramfs rebuild silently never ran on the
    # OP6 path. Bind the pseudofs trio for the transaction window.
    mount_chroot_pseudo() {
        mount -t proc proc /mnt/archmage-rootfs/proc 2>/dev/null || true
        mount -t sysfs sys /mnt/archmage-rootfs/sys 2>/dev/null || true
        mount --bind /dev /mnt/archmage-rootfs/dev 2>/dev/null || true
    }
    umount_chroot_pseudo() {
        umount /mnt/archmage-rootfs/dev 2>/dev/null || true
        umount /mnt/archmage-rootfs/sys 2>/dev/null || true
        umount /mnt/archmage-rootfs/proc 2>/dev/null || true
    }
    trap cleanup_mount EXIT INT TERM
    mount -o loop "$root_img" "$mnt"
    [ -s "$mnt/etc/pacman.conf" ] || die "mounted rootfs has no /etc/pacman.conf"
    mkdir -p /mnt/archmage-rootfs/{proc,sys,dev}
    mount_chroot_pseudo

    gpgdir=$mnt/etc/pacman.d/gnupg
    mkdir -p "$gpgdir"
    archmage_info "stage 2: seeding image pacman keyring (ALARM keyring + staging key lsign)"
    pacman-key --gpgdir "$gpgdir" --init
    pacman-key --gpgdir "$gpgdir" --populate archlinuxarm
    pacman-key --gpgdir "$gpgdir" --add "$CONTAINER_STAGING/staging-key.asc"
    local staging_key
    staging_key=$(find "$CONTAINER_STAGING" -maxdepth 4 -name FINGERPRINT.txt -print -quit)
    local fpr
    fpr=$(awk '/^FINGERPRINT:/ {print $2}' "$staging_key")
    [ -n "$fpr" ] || die "cannot parse signing fingerprint from $staging_key"
    pacman-key --gpgdir "$gpgdir" --lsign-key "$fpr"

    local stage2_conf=$WORK_DIR/pacman-image-install.conf
    cat > "$stage2_conf" <<EOF
# pacman.conf used INSIDE the build container to install the CN layer into
# the OP6 rootfs image (bootstrap.sh stage 2). The install root is passed via
# \`pacman -r\`; GPGDir targets the image's own (just-seeded) keyring.
[options]
Architecture = aarch64
# ALARM upstream: signed packages, unsigned databases.
SigLevel = Required DatabaseOptional
NoProgressBar
# pacman 7's landlock/seccomp sandbox is not reliably satisfiable inside
# this throwaway-root transaction under containerization; disabled here and
# ONLY here — never in shipped configs (01-02 decision).
DisableSandbox
GPGDir = $gpgdir

[core]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo

[extra]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo

[alarm]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo

[aur]
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo

[archmage-testing]
# ArchMage testing channel (= the packages.yml CI staging artifact; 03-03
# two-channel model): strictest level — package signatures Required; no
# weaker database token, so the signed database is verified as well.
SigLevel = Required
Server = $stage2_server
EOF
    archmage_info "stage 2: pacman -r install archmage-cn archmage-phosh-safety archmage-cn-apn archmage-btrfs-rollback archmage-fcitx5-osk waydroid archmage-waydroid-config (SigLevel Required, signed DB verified)"
    mkdir -p "$KBS_CACHE/pacman-image-cache"
    # --overwrite /etc/locale.conf: kupfer's base-kupfer ships that file;
    # archmage-cn-locale's zh_CN default is the intended winner (the x86_64
    # pipeline never sees this because it has no base-kupfer). Pacman lists
    # ALL conflicts before aborting, and this was the only one reported.
    # 03-01 full OSK replacement: the kupfer phosh flavour stage resolves
    # phosh's phosh-osk-provider dependency to squeekboard (or stevia) in
    # stage 1. archmage-fcitx5-osk Conflicts both — and pacman's
    # conflict-removal question defaults to "no" under --noconfirm, so the
    # transaction would abort instead of replacing. Remove the repo OSK
    # explicitly first (-dd: phosh's virtual provider dep is re-satisfied
    # moments later by archmage-fcitx5-osk's provides= in the install
    # transaction below).
    for osk in squeekboard stevia; do
        if pacman -r "$mnt" -Q "$osk" >/dev/null 2>&1; then
            archmage_info "stage 2: removing $osk (replaced by archmage-fcitx5-osk, phosh OSK contract)"
            pacman -r "$mnt" --config "$stage2_conf" -Rdd --noconfirm "$osk"
        fi
    done
    # Keep this list identical to the canonical profile's pkgs_include in
    # archmage.toml (bootstrap.sh --check asserts the two stay in sync).
    # 03-02: waydroid resolution note — at execution time (2026-10-02) ALARM's
    # aarch64 [extra] carries waydroid 1.6.3-1 + the gbinder chain, so pacman
    # picks the higher pkgver there; the staging repo's vendored 1.5.4-1 chain
    # (overlay/apps, DIVERGENCE ledger) is the fallback line if ALARM/Arch
    # drop or lag the chain again. archmage-waydroid-config (depends=waydroid)
    # always comes from the staging repo.
    # -r quirk: the file-conflict check reports root-prefixed paths, and
    # --overwrite matching has varied across pacman versions — pass both
    # the in-image and root-prefixed forms (additive flags).
    pacman -r "$mnt" --config "$stage2_conf" \
        --cachedir "$KBS_CACHE/pacman-image-cache" \
        --noconfirm --needed -Sy \
        --overwrite "/etc/locale.conf" --overwrite "$mnt/etc/locale.conf" \
        archmage-cn archmage-phosh-safety \
        archmage-cn-apn archmage-btrfs-rollback archmage-fcitx5-osk \
        waydroid archmage-waydroid-config
    # Transaction window over: scriptlets (mkinitcpio) have run — drop the
    # pseudofs binds before stage 3 touches only plain files.
    umount_chroot_pseudo

    # 7) Stage 3 — harden the shipped /etc/pacman.conf.
    archmage_info "stage 3: hardening shipped /etc/pacman.conf"
    "$KBS_PY" - "$mnt/etc/pacman.conf" "$stage2_server" <<'PYEOF'
import re, sys

conf_path, archmage_server = sys.argv[1], sys.argv[2]
ALARM_SECTIONS = {'core', 'extra', 'community', 'alarm', 'aur',
                  'core-testing', 'extra-testing', 'community-testing',
                  'alarm-testing', 'aur-testing'}
KUPFER_SECTIONS = {'kupfer_local', 'boot', 'cross', 'device', 'firmware',
                   'linux', 'main', 'phosh', 'plasma_mobile', 'gnome_mobile'}

lines = open(conf_path).read().splitlines()
out, section = [], None
for line in lines:
    m = re.match(r'^\[([^]]+)\]\s*$', line)
    if m:
        section = m.group(1)
        out.append(line)
        continue
    if (section in ALARM_SECTIONS and re.match(r'^\s*SigLevel\s*=', line)
            and 'Never' in line):
        # Drop the build-time override: kbs's global policy
        # `SigLevel = Required DatabaseOptional` then applies — the ALARM
        # upstream policy (signed packages, unsigned databases).
        continue
    out.append(line)

assert '[archmage]' not in out, 'shipped pacman.conf already has an [archmage] section?'
out += [
    '',
    '# ArchMage testing channel (= CI staging; 03-03 two-channel model):',
    '# package signatures Required; no weaker database token, so the signed',
    '# database is verified as well. The file:// Server records the build-time',
    '# staging source; hosted-mirror configuration is owned by the image',
    '# publishing step (02-02/02-03).',
    '[archmage-testing]',
    'SigLevel = Required',
    f'Server = {archmage_server}',
    '',
    '# ArchMage stable channel (human-signed; docs/REPO-CHANNELS.md): ships',
    '# COMMENTED — stable is produced only by the maintainer-host signing',
    '# ceremony, never by CI. Enable it after filling',
    '# /etc/pacman.d/archmage/channels/stable.conf with the hosted Server.',
    '#[archmage-stable]',
    '#SigLevel = Required',
    '#Include = /etc/pacman.d/archmage/channels/stable.conf',
]
open(conf_path, 'w').write('\n'.join(out) + '\n')

# Channel Include files ship pre-created (03-03): testing.conf documents the
# active channel, stable.conf ships with an EMPTY server list — it is filled
# in by the admin at switch time (docs/REPO-CHANNELS.md §5).
import os
chan_dir = os.path.join(os.path.dirname(conf_path), 'pacman.d/archmage/channels')
os.makedirs(chan_dir, exist_ok=True)
with open(os.path.join(chan_dir, 'testing.conf'), 'w') as f:
    f.write(
        '# [archmage-testing] channel servers(active by default)。\n'
        '# 出厂镜像经 /etc/pacman.conf 的 Server 行消费内嵌 staging 副本;\n'
        '# testing 通道托管化后,在此追加托管镜像的 Server 行。\n')
with open(os.path.join(chan_dir, 'stable.conf'), 'w') as f:
    f.write(
        '# [archmage-stable] channel servers(切换时由管理员填写)。\n'
        '# 出厂态刻意为空:stable 通道只在人工签名仪式(docs/REPO-CHANNELS.md)\n'
        '# 之后才存在。启用方法:在此填 Server 行,再到 /etc/pacman.conf 取消\n'
        '# [archmage-stable] 段的注释。SigLevel Required 纪律两个通道都不放松。\n'
        '# Server = https://<stable-mirror>/<path>\n')

# Post-conditions.
final = open(conf_path).read()
sec = None
never_secs = []
for line in final.splitlines():
    m = re.match(r'^\[([^]]+)\]\s*$', line)
    if m:
        sec = m.group(1)
    elif re.match(r'^\s*SigLevel\s*=', line) and 'Never' in line:
        never_secs.append(sec)
bad = [s for s in never_secs if s not in KUPFER_SECTIONS]
assert not bad, f'non-kupfer sections still carry SigLevel Never: {bad}'
assert '[archmage-testing]' in final, '[archmage-testing] section missing after hardening'
assert '#[archmage-stable]' in final, 'commented [archmage-stable] block missing after hardening'
print('shipped pacman.conf hardened: ALARM sections on Required DatabaseOptional, [archmage-testing] active + [archmage-stable] shipped commented at Required')
PYEOF

    # 8) Extract the Android boot image from the boot partition (the
    #    flashable `fastboot flash boot` artifact; kbs keeps it inside the
    #    ext4 boot partition at /aboot.img — same extraction as kbs's own
    #    dump_aboot, via debugfs).
    local aboot_img=$KBS_IMAGES/$KBS_DEVICE-aboot.img
    debugfs -R "dump /aboot.img $aboot_img" "$boot_img" >/dev/null 2>&1
    [ -s "$aboot_img" ] || die "failed to extract /aboot.img from $boot_img (device flavour did not produce an Android boot image?)"

    # gpg-agent, spawned by the pacman-key lsign calls, daemonizes with its
    # homedir INSIDE the loop mount and keeps it busy — plain umount fails
    # EBUSY (exit 32, run 37260366462). Kill it, then unmount.
    GNUPGHOME="$gpgdir" gpgconf --kill gpg-agent 2>/dev/null || true
    sleep 1
    umount "$mnt" || umount -l "$mnt"
    trap - EXIT INT TERM

    # 9) Hand everything back to the invoking host user.
    if [ -n "${ARCHMAGE_HOST_UID:-}" ]; then
        chown -R "$ARCHMAGE_HOST_UID" "$WORK_DIR"
    fi

    archmage_info "build complete: $KBS_IMAGES"
    ls -la "$KBS_IMAGES"
}

if [ "$INNER" = yes ]; then
    container_main
else
    host_main
fi
