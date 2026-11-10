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
    exec docker run --rm --privileged --platform linux/x86_64 \
        -v "$REPO_ROOT":/w -w /w \
        -e GH_TOKEN="${GH_TOKEN:-}" -e ARCHMAGE_IN_CONTAINER=1 \
        archlinux:base \
        bash test/desktop-x86_64.sh "$@"
fi

[ "$(id -u)" = 0 ] || die "must run as root (inside the privileged container)"
command -v gh >/dev/null 2>&1 || pacman -Sy --noconfirm --needed gh >/dev/null 2>&1

# GH Actions docker blocks Landlock; pacman 7 sandbox cannot be satisfied in
# job containers — container-own pacman only (01-02 decision, throwaway root).
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i 's/^\[options\]$/[options]\nDisableSandbox/' /etc/pacman.conf
# Deterministic dual mirrorlist BEFORE any pacman -Sy (US-hosted runner:
# geo CDN first, TUNA fallback — same standard as packages.yml x86_64 leg).
printf '%s\n' \
    'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
    'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
    > /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm --needed arch-install-scripts btrfs-progs dosfstools \
    e2fsprogs gnupg grub jq sudo >/dev/null
command -v gh >/dev/null 2>&1 || pacman -Sy --noconfirm --needed gh

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
[ -f "$STAGING/cn.db.tar.zst" ] || die "staging repo lacks cn.db.tar.zst — wrong artifact?"
[ -f "$STAGING/staging-key.asc" ] || die "staging repo lacks staging-key.asc"

# ---- staging keyring: import + lsign, SigLevel Required (01-02 pattern) ----
gpgdir="$OUT_DIR/pacman-keyring"
mkdir -p "$gpgdir"; chmod 700 "$gpgdir"
export GNUPGHOME="$gpgdir"
pacman-key --gpgdir "$gpgdir" --init >/dev/null 2>&1
pacman-key --gpgdir "$gpgdir" --add "$STAGING/staging-key.asc" >/dev/null 2>&1
fpr="$(awk '/^FINGERPRINT:/ {print $2}' "$STAGING/FINGERPRINT.txt")"
[ -n "$fpr" ] || die "cannot parse FINGERPRINT.txt"
pacman-key --gpgdir "$gpgdir" --lsign-key "$fpr" >/dev/null 2>&1
info "staging key $fpr imported and locally signed"

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

# ---- disk: GPT + ESP + btrfs(@ @var @snapshots) ----
mkdir -p "$(dirname "$OUT_IMG")"
rm -f "$OUT_IMG"
truncate -s 8G "$OUT_IMG"
sfdisk -q "$OUT_IMG" <<DISK
label: gpt
type=UEFI, size=512MiB, bootable
type=linux
DISK
LOOP="$(losetup --find --show "$OUT_IMG")"
partprobe "$LOOP"
ESP="${LOOP}p1"; ROOT="${LOOP}p2"
mkfs.vfat -F 32 -n ARCHMAGE-ESP "$ESP"
mkfs.btrfs -L archmage-desktop -f "$ROOT"

mnt="$OUT_DIR/mnt"
mkdir -p "$mnt"
mount -o compress=zstd:1 "$ROOT" "$mnt"
btrfs subvolume create "$mnt/@"
btrfs subvolume create "$mnt/@var"
btrfs subvolume create "$mnt/@snapshots"
mkdir -p "$mnt/@var/lib/snapper"  # snapper wants a plain dir home
umount "$mnt"
mount -o compress=zstd:1,subvol=@ "$ROOT" "$mnt"
mkdir -p "$mnt/var" "$mnt/.snapshots" "$mnt/boot" "$mnt/esp"
mount -o compress=zstd:1,subvol=@var "$ROOT" "$mnt/var"
chattr +C "$mnt/var" 2>/dev/null || true   # NoCOW for DBs (PITFALLS 6)
mount -o compress=zstd:1,subvol=@snapshots "$ROOT" "$mnt/.snapshots"
mount "$ESP" "$mnt/esp"

cleanup() {
    umount "$mnt/esp" "$mnt/.snapshots" "$mnt/var" "$mnt/boot" "$mnt" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- install: Arch desktop stack from repos + archmage-desktop from
# staging (SigLevel Required — the 01-02 Required discipline) ----
pacstrap -C "$pacman_conf" -K -G -M "$mnt" \
    base linux linux-firmware linux-headers \
    grub efibootmgr os-prober \
    networkmanager ufw \
    pipewire wireplumber pipewire-pulse \
    hyprland uwsm ghostty waybar fuzzel \
    xdg-desktop-portal-hyprland polkit-gnome brightnessctl \
    fcitx5 fcitx5-chinese-addons fcitx5-gtk fcitx5-qt \
    noto-fonts-cjk noto-fonts ttf-jetbrainsmono-nerd \
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
    # snapper config for the rollback story
    snapper -c root create-config / 2>/dev/null || true
    # allow NOTHING to silently skip the desktop umbrella
    pacman -Q archmage-desktop >/dev/null
    echo "--- desktop chroot config complete ---"
'

# ---- GRUB into the ESP ----
LANG=C.UTF-8 chroot "$chroot" /bin/bash -ec '
    set -euo pipefail
    grub-install --target=x86_64-efi --efi-directory=/esp \
        --bootloader-id=ArchMage-Desktop --removable >/dev/null 2>&1
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
    echo "--- grub installed ---"
'

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
gate desktop_meta_pkg  ls -d "$DB"/archmage-desktop-*/ >/dev/null 2>&1
gate cn_locale_pkg     ls -d "$DB"/archmage-cn-locale-*/ >/dev/null 2>&1
gate user_archmage     grep -q "^archmage:" "$chroot/etc/passwd"
gate locale_conf       grep -q "zh_CN.UTF-8" "$chroot/etc/locale.conf"
gate grub_bin          test -f "$chroot/esp/EFI/ArchMage-Desktop/grubx64.efi" || test -d "$chroot/boot/grub"
gate snapper_cfg       test -d "$chroot/etc/snapper/configs" && ls "$chroot/etc/snapper/configs" | grep -q root
gate subvol_layout     mountpoint -q "$mnt/var" && mountpoint -q "$mnt/.snapshots"
gate esp_mounted       mountpoint -q "$mnt/esp"

if [ "$fails" -eq 0 ]; then
    printf 'desktop-x86_64: status=pass (17 gates)\n'
else
    printf 'desktop-x86_64: status=fail (%d gate failure(s))\n' "$fails"
fi

info "image: $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
[ "$fails" -eq 0 ] || exit 1
