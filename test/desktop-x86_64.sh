#!/usr/bin/env bash
# desktop-x86_64.sh — build the ArchMage DESKTOP x86_64 image (Omarchy-lineage
# stack: Hyprland/uwsm + Ghostty + waybar + fuzzel + fcitx5 CN IME + gum/fzf
# TUI tooling, see overlay/desktop/archmage-desktop).
#
# Runs as ROOT inside a privileged archlinux:base container (loop devices +
# mounts). Self-wraps via docker when pacman is missing, same pattern as
# test/mkrootfs-x86_64.sh.
#
# Usage:
#   bash test/desktop-x86_64.sh [--from-ci | --repo-dir PATH] [--out IMG]
#
#   --from-ci      download the staging-repo-x86_64 artifact of the latest
#                  successful packages.yml run on main (GH_TOKEN required;
#                  desktop staging repo, 01-01 contract sibling).
#   --repo-dir DIR use an already-acquired staging-repo-x86_64 directory.
#   --out IMG      output image path (default test/build/desktop/rootfs.img).
#
# Disk layout (rollback-ready, mirrors the phone image discipline):
#   GPT: p1 ESP (vfat, 512M) | p2 btrfs -L archmage-desktop
#   btrfs subvolumes: @ (root), @var (NoCOW), @snapshots — snapper/snap-pac
#   preconfigured so the desktop gets the same rollback story as the phone.
#
# Gates (structural, exit code IS the gate): Hyprland stack binaries, CN
# locale + fonts, fcitx5, gum/fzf, archmage-desktop in the pacman db,
# GRUB installed, subvolumes + snapper config, user archmage present.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/test/build/desktop"
OUT_IMG="$OUT_DIR/rootfs.img"
REPO_DIR=""
FROM_CI=no

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --from-ci) FROM_CI=yes ;;
        --repo-dir) [ $# -ge 2 ] || die "--repo-dir needs a PATH"; REPO_DIR=$2; shift ;;
        --out) [ $# -ge 2 ] || die "--out needs a PATH"; OUT_IMG=$2; shift ;;
        -h|--help) sed -n '2,26p' "$0" | grep -E '^#'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

# ---- self-wrap: privileged archlinux:base container when pacman missing ----
if ! command -v pacman >/dev/null 2>&1; then
    command -v docker >/dev/null 2>&1 || die "no pacman and no docker — cannot build"
    info "self-wrapping into a privileged archlinux:base container"
    mkdir -p "$REPO_ROOT/test/build/desktop/pacman-cache"
    exec docker run --rm --privileged --platform linux/x86_64 \
        -v "$REPO_ROOT":/w -w /w \
        -v "$REPO_ROOT/test/build/desktop/pacman-cache":/var/cache/pacman/pkg \
        -e GH_TOKEN="${GH_TOKEN:-}" -e ARCHMAGE_IN_CONTAINER=1 \
        -e ARCHMAGE_DESKTOP_MIRROR_ORDER="${ARCHMAGE_DESKTOP_MIRROR_ORDER:-}" \
        archlinux:base-devel \
        bash test/desktop-x86_64.sh "$@"
fi

[ "$(id -u)" = 0 ] || die "must run as root (inside the privileged container)"

# GH Actions docker blocks Landlock; pacman 7 sandbox cannot be satisfied in
# job containers — container-own pacman only (01-02 decision, throwaway root).
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i 's/^\[options\]$/[options]\nDisableSandbox/' /etc/pacman.conf
# archlinux:base ships a pacman.conf WITHOUT [extra] — gh and the desktop
# stack live in extra. Enable it (idempotent) before any pacman -Sy.
grep -q '^\[extra\]' /etc/pacman.conf || printf '\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
# Deterministic dual mirrorlist BEFORE any pacman -Sy. Order is
# environment-aware: CI runners (US-hosted) want the geo CDN first; local
# CN-network builds want TUNA first (the geo CDN can HANG — not just slow —
# from CN networks; measured live 2026-11-10). Set
# ARCHMAGE_DESKTOP_MIRROR_ORDER=cn for local builds.
if [ "${ARCHMAGE_DESKTOP_MIRROR_ORDER:-geo}" = "cn" ]; then
    printf '%s\n' \
        'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
        'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
        > /etc/pacman.d/mirrorlist
else
    printf '%s\n' \
        'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
        'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
        > /etc/pacman.d/mirrorlist
fi
pacman -Sy --noconfirm --needed arch-install-scripts btrfs-progs dosfstools \
    e2fsprogs gnupg grub jq sudo github-cli

# ---- staging repo acquisition ----
STAGING="$OUT_DIR/staging"
mkdir -p "$STAGING"
if [ "$FROM_CI" = yes ]; then
    [ -n "${GH_TOKEN:-}" ] || die "--from-ci needs GH_TOKEN"
    run_id="$(gh run list --repo "${ARCHMAGE_GH_REPO:-Arcane-Reflection/ArchMage}" \
        --workflow packages.yml --branch main --status success --limit 1 \
        --json databaseId --jq '.[0].databaseId')"
    [ -n "$run_id" ] || die "no successful packages.yml run on main yet"
    info "downloading staging-repo-x86_64 from packages run $run_id"
    rm -rf "$STAGING"; mkdir -p "$STAGING"
    gh run download "$run_id" --repo "${ARCHMAGE_GH_REPO:-Arcane-Reflection/ArchMage}" \
        --name staging-repo-x86_64 --dir "$STAGING"
elif [ -n "$REPO_DIR" ]; then
    rm -rf "$STAGING"; cp -a "$REPO_DIR/." "$STAGING/"
fi
if [ ! -f "$STAGING/cn.db.tar.zst" ]; then
    echo "::error::staging repo lacks cn.db.tar.zst — downloaded content:"
    ls -la "$STAGING" >&2 || true
    die "wrong artifact downloaded?"
fi
[ -f "$STAGING/staging-key.asc" ] || die "staging repo lacks staging-key.asc"
# packages.yml keeps producing cn.db.tar.zst; the [archmage-testing] section
# requests archmage-testing.db — provide both names (mkrootfs 03-03 pattern).
ln -sfn cn.db.tar.zst "$STAGING/archmage-testing.db"
[ -s "$STAGING/cn.db.tar.zst.sig" ] && \
    ln -sfn cn.db.tar.zst.sig "$STAGING/archmage-testing.db.sig" || true

# ---- staging keyring: import + lsign, SigLevel Required (01-02 pattern) ----
gpgdir="$OUT_DIR/pacman-keyring"
mkdir -p "$gpgdir"; chmod 700 "$gpgdir"
export GNUPGHOME="$gpgdir"
pacman-key --init >/dev/null 2>&1
# The pacstrap GPGDir keyring needs ARCHLINUX keys (repo packages) AND the
# staging key (overlay packages); the host DEFAULT keyring needs the staging
# key too, because pacstrap -K seeds the image's keyring from it (first-boot
# archmage-testing sig verification would otherwise fail).
pacman-key --populate archlinux >/dev/null 2>&1
pacman-key --add "$STAGING/staging-key.asc" >/dev/null 2>&1
fpr="$(awk '/^FINGERPRINT:/ {print $2}' "$STAGING/FINGERPRINT.txt")"
[ -n "$fpr" ] || die "cannot parse FINGERPRINT.txt"
pacman-key --lsign-key "$fpr" >/dev/null 2>&1
# Mirror into the pacstrap GPGDir keyring.
pacman-key --gpgdir "$gpgdir" --init >/dev/null 2>&1
pacman-key --gpgdir "$gpgdir" --populate archlinux >/dev/null 2>&1
pacman-key --gpgdir "$gpgdir" --add "$STAGING/staging-key.asc" >/dev/null 2>&1
pacman-key --gpgdir "$gpgdir" --lsign-key "$fpr" >/dev/null 2>&1
info "staging key $fpr imported and locally signed (default + pacstrap keyrings)"

pacman_conf="$OUT_DIR/pacman-desktop-install.conf"
cat > "$pacman_conf" <<EOF
[options]
Architecture = x86_64
SigLevel = Required DatabaseOptional
NoProgressBar
DisableSandbox
GPGDir = $gpgdir
HoldPkg = pacman glibc

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[archmage-testing]
SigLevel = Required
Server = file://$STAGING
EOF

# ---- disk: separate ESP/root sparse files, bare loop mounts, dd assembly.
# Partition-node racing on the shared-host /dev is a live PITFALL (mkrootfs
# x86_64: loopNpN nodes materialize asynchronously and "on some hosts
# never"); bare loop attaches of standalone files sidestep partition scan
# entirely. The final GPT image is assembled by dd at the end.
ESP_IMG="$OUT_DIR/esp.img"
ROOT_IMG="$OUT_DIR/root-btrfs.img"
# Stale images from a failed earlier run carry an old btrfs signature —
# clean them (the final assembled image is cleaned separately).
rm -f "$ESP_IMG" "$ROOT_IMG"
truncate -s 512M "$ESP_IMG"
truncate -s 7G "$ROOT_IMG"

attach_bare() {  # attach_bare <img> -> prints the bare loop device
    local img="$1" attempt minor node loop
    for attempt in 1 2 3; do
        if loop="$(losetup -f --show "$img" 2>/dev/null)"; then
            printf '%s\n' "$loop"
            return 0
        fi
        # Fallback: instantiate the /dev node for a free index and attach
        # directly (shared-host /dev sometimes never creates the node the
        # loop-control index points at — observed live 03-01).
        [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237 2>/dev/null || true
        for minor in $(seq 0 127); do
            node="/dev/loop$minor"
            [ -e "$node" ] || mknod "$node" b 7 "$minor" 2>/dev/null || true
            [ -e "$node" ] || continue
            if losetup "$node" "$img" 2>/dev/null; then
                printf '%s\n' "$node"
                return 0
            fi
        done
        sleep 2
    done
    return 1
}

ESP_LOOP="$(attach_bare "$ESP_IMG")" || die "losetup failed for $ESP_IMG"
ROOT_LOOP="$(attach_bare "$ROOT_IMG")" || die "losetup failed for $ROOT_IMG"

mnt="$OUT_DIR/mnt"
mkdir -p "$mnt"
mkfs.vfat -F 32 -n AMDESP "$ESP_LOOP"
mkfs.btrfs -f -L archmage-desktop "$ROOT_LOOP"
mount "$ROOT_LOOP" "$mnt"
btrfs subvolume create "$mnt/@"
btrfs subvolume create "$mnt/@var"
btrfs subvolume create "$mnt/@snapshots"
umount "$mnt"
mount -o compress=zstd:1,subvol=@ "$ROOT_LOOP" "$mnt"
mkdir -p "$mnt/var" "$mnt/.snapshots" "$mnt/esp"
mount -o compress=zstd:1,subvol=@var "$ROOT_LOOP" "$mnt/var"
chattr +C "$mnt/var" 2>/dev/null || true   # NoCOW for DBs (PITFALLS 6)
mount -o compress=zstd:1,subvol=@snapshots "$ROOT_LOOP" "$mnt/.snapshots"
mount "$ESP_LOOP" "$mnt/esp"

cleanup() {
    umount "$mnt/dev" "$mnt/proc" "$mnt/sys" 2>/dev/null || true
    umount "$mnt/esp" "$mnt/.snapshots" "$mnt/var" "$mnt" 2>/dev/null || true
    losetup -d "$ESP_LOOP" "$ROOT_LOOP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- install: Arch desktop stack from repos + archmage-desktop from
# staging (SigLevel Required — the 01-02 Required discipline) ----
# Scriptlet-visible pseudofs binds: systemd systemctl + mkinitcpio +
# grub tooling all require /dev /proc /sys inside the chroot.
mkdir -p "$mnt/dev" "$mnt/proc" "$mnt/sys"
mount --bind /dev  "$mnt/dev"
mount --bind /proc "$mnt/proc"
mount --bind /sys  "$mnt/sys"
pacstrap -C "$pacman_conf" -K -G -M "$mnt" \
    base linux linux-firmware linux-headers \
    grub efibootmgr os-prober \
    networkmanager ufw \
    pipewire wireplumber pipewire-pulse \
    hyprland uwsm ghostty waybar fuzzel \
    xdg-desktop-portal-hyprland polkit-gnome brightnessctl \
    fcitx5 fcitx5-chinese-addons fcitx5-gtk fcitx5-qt \
    noto-fonts-cjk noto-fonts ttf-jetbrains-mono-nerd \
    gum fzf sudo git \
    snapper snap-pac \
    archmage-desktop

# ---- configuration (chroot) ----
chroot="$mnt"
LANG=C.UTF-8 chroot "$chroot" /bin/bash -ec '
    set -euo pipefail
    # locale: zh_CN primary with en_US fallback
    printf "en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\n" > /etc/locale.gen
    locale-gen
    printf "LANG=zh_CN.UTF-8\n" > /etc/locale.conf
    # timezone + hostname
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    printf "archmage-desktop\n" > /etc/hostname
    # fcitx5 wayland IME defaults (environment.d; Omarchy 3.0 --wayland-ime fix)
    mkdir -p /usr/lib/environment.d
    cat > /usr/lib/environment.d/10-archmage-desktop-ime.conf <<ENV
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
INPUT_METHOD=fcitx
ENV
    # user archmage (uid 1000, wheel) — dev-image password convention 1234
    useradd -m -u 1000 -G wheel,video,audio,input archmage
    echo "archmage:1234" | chpasswd
    printf "archmage ALL=(ALL:ALL) ALL\n" > /etc/sudoers.d/archmage
    chmod 440 /etc/sudoers.d/archmage
    # services
    systemctl enable NetworkManager.service
    systemctl enable ufw.service
    systemctl enable fstrim.timer
    # greetd autologin into the Hyprland uwsm session
    pacman -S --noconfirm --needed greetd greetd-tuigreet >/dev/null 2>&1 || true
    mkdir -p /etc/greetd
    cat > /etc/greetd/config.toml <<GREETD
[terminal]
vt = 7

[default_session]
command = "tuigreet --time --remember --cmd uwsm start hyprland.desktop"
user = "archmage"
GREETD
    systemctl enable greetd.service 2>/dev/null || {
        mkdir -p /etc/systemd/system/multi-user.target.wants
        ln -sf /usr/lib/systemd/system/greetd.service \
            /etc/systemd/system/multi-user.target.wants/greetd.service
    }
    # fstab: btrfs subvol mounts by label (ESP mounts are handled by GRUB;
    # no runtime ESP fstab entry needed for the first boot)
    cat > /etc/fstab <<FSTAB
LABEL=archmage-desktop  /           btrfs   rw,compress=zstd:1,subvol=@         0 0
LABEL=archmage-desktop  /var        btrfs   rw,compress=zstd:1,subvol=@var      0 0
LABEL=archmage-desktop  /.snapshots btrfs   rw,compress=zstd:1,subvol=@snapshots 0 0
FSTAB
    # allow NOTHING to silently skip the desktop umbrella
    pacman -Q archmage-desktop >/dev/null
    echo "--- desktop chroot config complete ---"
'

# ---- initramfs + GRUB (mkrootfs-x86_64 proven recipe) ----
# - mkinitcpio -P: the image is unbootable without an initramfs
# - --removable --no-nvram: no EFI-vars/NVRAM dependency in a container;
#   OVMF/GRUB boots \EFI\BOOT\BOOTX64.EFI directly
# - --modules pins part_gpt explicitly: /boot sits on a BARE loop here, so
#   grub-install's partmap probe sees no partition table and the core would
#   ship without part_gpt — on the real GPT disk GRUB drops to rescue
#   (observed live, mkrootfs-x86_64)
# - the grub-btrfs snapshot script must LEAVE /etc/grub.d for THIS
#   grub-mkconfig: no udev in the chroot means its device scan kills
#   grub-mkconfig under set -e (observed live, mkrootfs-x86_64)
chroot "$chroot" /usr/bin/mkinitcpio -P
GRUB_BTRFS_SNIPPET="$chroot/etc/grub.d/41_snapshots-btrfs"
GRUB_BTRFS_HOLD="$OUT_DIR/41_snapshots-btrfs.hold"
if [ -f "$GRUB_BTRFS_SNIPPET" ]; then
    mv "$GRUB_BTRFS_SNIPPET" "$GRUB_BTRFS_HOLD"
fi
chroot "$chroot" /usr/bin/grub-install \
    --target=x86_64-efi --efi-directory=/esp --boot-directory=/boot \
    --bootloader-id=ArchMage-Desktop --removable --no-nvram \
    --modules="part_gpt part_msdos btrfs zstd search_fs_uuid search_label"
chroot "$chroot" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
if [ -f "$GRUB_BTRFS_HOLD" ]; then
    mv "$GRUB_BTRFS_HOLD" "$GRUB_BTRFS_SNIPPET"
fi
echo "--- initramfs + grub installed ---"

# ---- gates: structural assertions (exit code IS the gate) ----
fails=0
gate() { # gate <name> <command...>
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  [pass] %s\n' "$name"
    else
        printf '  [FAIL] %s\n' "$name"
        fails=$((fails + 1))
    fi
}
DB="$chroot/var/lib/pacman/local"
gate hyprland_bin      test -x "$chroot/usr/bin/Hyprland"
gate ghostty_bin       test -x "$chroot/usr/bin/ghostty"
gate waybar_bin        test -x "$chroot/usr/bin/waybar"
gate fuzzel_bin        test -x "$chroot/usr/bin/fuzzel"
gate gum_bin           test -x "$chroot/usr/bin/gum"
gate fzf_bin           test -x "$chroot/usr/bin/fzf"
gate fcitx5_bin        test -x "$chroot/usr/bin/fcitx5"
gate cn_fonts          test -d "$chroot/usr/share/fonts/noto-cjk"
gate ime_env           grep -q "GTK_IM_MODULE=fcitx" "$chroot/usr/lib/environment.d/10-archmage-desktop-ime.conf"
gate ime_env           grep -q "GTK_IM_MODULE=fcitx" "$chroot/usr/lib/environment.d/10-archmage-desktop-ime.conf"
gate user_archmage     grep -q "^archmage:" "$chroot/etc/passwd"
gate locale_conf       grep -q "zh_CN.UTF-8" "$chroot/etc/locale.conf"
gate cn_fonts_pkg      ls -d "$DB"/archmage-cn-fonts-meta-*/ 2>/dev/null
# Compound gates: explicit if-blocks — the gate() wrapper passes args as a
# command, and &&/pipes/redirections inside those args do not re-parse the
# way a script line would (run 42731233186+ local: silent mid-gate death).
if ls -d "$DB"/archmage-desktop-*/ >/dev/null 2>&1; then
    printf '  [pass] desktop_meta_pkg\n'
else
    printf '  [FAIL] desktop_meta_pkg\n'; fails=$((fails + 1))
fi
if ls -d "$DB"/archmage-cn-locale-*/ >/dev/null 2>&1; then
    printf '  [pass] cn_locale_pkg\n'
else
    printf '  [FAIL] cn_locale_pkg\n'; fails=$((fails + 1))
fi
if [ -f "$chroot/esp/EFI/BOOT/BOOTX64.EFI" ] && [ -f "$chroot/boot/grub/grub.cfg" ]; then
    printf '  [pass] grub_bin\n'
else
    printf '  [FAIL] grub_bin\n'; fails=$((fails + 1))
fi
if ls -d "$DB"/snapper-*/ >/dev/null 2>&1 && ls -d "$DB"/snap-pac-*/ >/dev/null 2>&1 \
   && grep -q "subvol=@snapshots" "$chroot/etc/fstab" \
   && [ -d "$chroot/.snapshots" ]; then
    printf '  [pass] snapper_cfg\n'
else
    printf '  [FAIL] snapper_cfg\n'; fails=$((fails + 1))
fi
if mountpoint -q "$mnt/var" && btrfs subvolume show "$mnt/.snapshots" >/dev/null 2>&1; then
    printf '  [pass] subvol_layout\n'
else
    printf '  [FAIL] subvol_layout\n'; fails=$((fails + 1))
fi
if mountpoint -q "$mnt/esp"; then
    printf '  [pass] esp_mounted\n'
else
    printf '  [FAIL] esp_mounted\n'; fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
    printf 'desktop-x86_64: status=pass (18 gates)\n'
else
    printf 'desktop-x86_64: status=fail (%d gate failure(s))\n' "$fails"
fi
[ "$fails" -eq 0 ] || exit 1

# ---- unmount and dd-assemble the final GPT image ----
umount "$mnt/dev" "$mnt/proc" "$mnt/sys" 2>/dev/null || true
umount "$mnt/esp" "$mnt/.snapshots" "$mnt/var" "$mnt" 2>/dev/null || true
losetup -d "$ESP_LOOP" "$ROOT_LOOP" 2>/dev/null || true
trap - EXIT INT TERM

rm -f "$OUT_IMG"
truncate -s 8G "$OUT_IMG"
# p1 ESP: start 2048, 1048576 sectors (512M); p2 root fills the rest.
sfdisk -q "$OUT_IMG" <<DISK
label: gpt
type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, start=2048, size=1048576
type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
DISK
info "dd-assembling ESP and btrfs payloads into the GPT image"
dd if="$ESP_IMG"  of="$OUT_IMG" bs=512 seek=2048    conv=notrunc status=none
dd if="$ROOT_IMG" of="$OUT_IMG" bs=512 seek=1050624 conv=notrunc status=none
rm -f "$ESP_IMG" "$ROOT_IMG"

info "image: $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
[ "$fails" -eq 0 ] || exit 1
