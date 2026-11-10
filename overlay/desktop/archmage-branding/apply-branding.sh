#!/usr/bin/env bash
# apply-branding.sh — (re)apply the ArchMage L1+L2 brand layer on the Omarchy
# base. Runs from the alpm hook (99-archmage-branding.hook) after every
# transaction touching omarchy/omarchy-settings, and explicitly from the image
# builder after pacstrap. Idempotent; every step tolerates a missing upstream
# path so a future Omarchy refactor degrades instead of breaking the hook.
#
# Tiering per docs/internal/omarchy-rebrand-inventory.md: L1 cosmetics + L2
# command layer only. L3 internals (/usr/share/omarchy paths, ~/.config/
# omarchy, [omarchy] repo name) stay upstream — that is what keeps pacman
# updates working.
set -u

OMA=/usr/share/omarchy
BR=/usr/share/archmage/branding

log()  { printf '[archmage-branding] %s\n' "$*"; }
skip() { printf '[archmage-branding] skip: %s (missing upstream path)\n' "$*"; }

# --- B1: os-release ---------------------------------------------------------
# omarchy-settings' .INSTALL force-copies /usr/share/omarchy/etc-overrides/
# os-release to /etc/os-release on EVERY install/upgrade, so we rewrite the
# SOURCE (with BUILD_ID/VERSION_ID tracking the installed omarchy-settings
# version) and then refresh /etc/os-release from it.
if [ -d "$OMA/etc-overrides" ] && [ -f "$BR/os-release" ]; then
    base_ver="$(pacman -Q omarchy-settings 2>/dev/null | awk '{print $2}')"
    base_ver="${base_ver%%-*}"
    base_ver="${base_ver:-unknown}"
    sed "s/@BASE_VERSION@/$base_ver/g" "$BR/os-release" > "$OMA/etc-overrides/os-release"
    cp -f "$OMA/etc-overrides/os-release" /etc/os-release
    chmod 0644 /etc/os-release
    log "B1 os-release -> ArchMage (base $base_ver)"
else
    skip "B1 os-release"
fi

# --- B7: logo.svg / logo.txt (ASCII wordmark) -------------------------------
if [ -d "$OMA" ]; then
    [ -f "$BR/archmage-logo.svg" ] && cp -f "$BR/archmage-logo.svg" "$OMA/logo.svg"
    [ -f "$BR/logo.txt" ] && cp -f "$BR/logo.txt" "$OMA/logo.txt"
    log "B7 logo.svg/logo.txt -> ArchMage wordmark"
else
    skip "B7 logo assets"
fi

# --- B8: skel branding about.txt (+ screensaver), incl. existing /home users -
if [ -d /etc/skel/.config/omarchy/branding ]; then
    [ -f "$BR/about.txt" ] && cp -f "$BR/about.txt" /etc/skel/.config/omarchy/branding/about.txt
    [ -f "$BR/about.txt" ] && cp -f "$BR/about.txt" /etc/skel/.config/omarchy/branding/screensaver.txt
    log "B8 skel branding -> ArchMage about"
fi
for d in /home/*/.config/omarchy/branding; do
    [ -d "$d" ] || continue
    [ -f "$BR/about.txt" ] && cp -f "$BR/about.txt" "$d/about.txt"
done

# --- B9: fastfetch config ---------------------------------------------------
if [ -d /etc/fastfetch ] && [ -f "$BR/fastfetch.jsonc" ]; then
    cp -f "$BR/fastfetch.jsonc" /etc/fastfetch/config.jsonc
    log "B9 fastfetch -> ArchMage config"
else
    skip "B9 fastfetch"
fi

# --- B5: SDDM theme copy -> archmage + Current=archmage ---------------------
# The deployed theme lives at /usr/share/sddm/themes/omarchy (omarchy-settings
# ships it; pacman backup path). We copy it aside, swap the logo, brand the
# QML/metadata words and flip 10-theme.conf — the default/ template below is
# kept in sync for future re-provisioning flows.
if [ -d /usr/share/sddm/themes/omarchy ]; then
    rm -rf /usr/share/sddm/themes/archmage
    cp -a /usr/share/sddm/themes/omarchy /usr/share/sddm/themes/archmage
    if [ -f "$BR/archmage-logo.png" ]; then
        cp -f "$BR/archmage-logo.png" /usr/share/sddm/themes/archmage/logo.png
    fi
    sed -i 's/Omarchy/ArchMage/g' \
        /usr/share/sddm/themes/archmage/Main.qml \
        /usr/share/sddm/themes/archmage/metadata.desktop 2>/dev/null || true
    sed -i 's/^Name=.*/Name=ArchMage/' \
        /usr/share/sddm/themes/archmage/metadata.desktop 2>/dev/null || true
    mkdir -p /etc/sddm.conf.d
    printf '[Theme]\nCurrent=archmage\n' > /etc/sddm.conf.d/10-theme.conf
    log "B5 SDDM theme -> archmage (Current=archmage)"
else
    skip "B5 SDDM theme"
fi
if [ -d "$OMA/default/sddm/omarchy" ]; then
    rm -rf "$OMA/default/sddm/archmage"
    cp -a "$OMA/default/sddm/omarchy" "$OMA/default/sddm/archmage"
    [ -f "$BR/archmage-logo.png" ] && \
        cp -f "$BR/archmage-logo.png" "$OMA/default/sddm/archmage/logo.png"
    sed -i 's/Omarchy/ArchMage/g' \
        "$OMA/default/sddm/archmage/Main.qml" \
        "$OMA/default/sddm/archmage/metadata.desktop" 2>/dev/null || true
fi

# --- B4: plymouth logo (theme script name stays: not user-visible) ----------
if [ -d /usr/share/plymouth/themes/omarchy ] && [ -f "$BR/archmage-logo.png" ]; then
    cp -f "$BR/archmage-logo.png" /usr/share/plymouth/themes/omarchy/logo.png
fi
if [ -d "$OMA/default/plymouth" ] && [ -f "$BR/archmage-logo.png" ]; then
    cp -f "$BR/archmage-logo.png" "$OMA/default/plymouth/logo.png"
fi
log "B4 plymouth logo -> ArchMage (where present)"

# --- limine interface_branding + OS name (boot menu is user-visible) --------
if [ -f "$OMA/default/limine/limine.conf" ]; then
    sed -i 's/^interface_branding:.*/interface_branding: ArchMage Bootloader/' \
        "$OMA/default/limine/limine.conf"
fi
[ -f /boot/limine.conf ] && \
    sed -i 's/^interface_branding:.*/interface_branding: ArchMage Bootloader/' /boot/limine.conf
if [ -f /etc/limine-entry-tool.d/omarchy-defaults.conf ]; then
    sed -i 's/^TARGET_OS_NAME=.*/TARGET_OS_NAME="ArchMage"/' \
        /etc/limine-entry-tool.d/omarchy-defaults.conf
fi
log "limine branding -> ArchMage Bootloader / TARGET_OS_NAME"

# --- B10: menu i18n (zh-CN mandatory per inventory; en best-effort) ---------
if [ -d "$OMA/default/i18n" ]; then
    for f in "$OMA"/default/i18n/zh-CN*.json "$OMA"/default/i18n/en.json; do
        [ -f "$f" ] || continue
        sed -i 's/Omarchy/ArchMage/g' "$f"
    done
    log "B10 i18n brand words -> ArchMage (zh-CN + en)"
else
    skip "B10 i18n"
fi

# --- C1: /usr/bin/archmage* entry symlinks -> omarchy implementations -------
# L2 contract: the user types archmage-*, the omarchy implementations keep
# working (internal omarchy->omarchy calls stay intact). Regenerated on every
# omarchy package upgrade so new upstream entries appear automatically.
count=0
for src in /usr/bin/omarchy*; do
    [ -e "$src" ] || continue
    dst="/usr/bin/archmage${src#/usr/bin/omarchy}"
    # never clobber a real (non-symlink) file
    [ -e "$dst" ] && [ ! -L "$dst" ] && continue
    ln -sfn "$(basename "$src")" "$dst"
    count=$((count + 1))
done
log "C1 entry symlinks: $count archmage* -> omarchy*"

# --- greeter compositor shim (only if nothing provides start-hyprland) ------
# SDDM's [Wayland] CompositorCommand references start-hyprland. If no package
# ships it (observed in omarchy/omarchy-settings/quickshell 4.5.0), a missing
# shim turns every SDDM greeter fallback into a dead screen. Created only
# when absent so a future upstream owner is never clobbered.
if ! command -v start-hyprland >/dev/null 2>&1 && [ -x /usr/bin/Hyprland ]; then
    printf '#!/usr/bin/env bash\n# ArchMage greeter shim (no package owned start-hyprland).\n[ "$1" = "--" ] && shift\nexec Hyprland "$@"\n' > /usr/bin/start-hyprland
    chmod 0755 /usr/bin/start-hyprland
    log "greeter shim /usr/bin/start-hyprland created"
fi

# --- I6: primary AI-skill wording (mechanism stays upstream) ----------------
if [ -f "$OMA/default/agents/skills/omarchy/SKILL.md" ]; then
    sed -i 's/Omarchy/ArchMage/g' "$OMA/default/agents/skills/omarchy/SKILL.md"
    log "I6 agents/skills/omarchy SKILL.md -> ArchMage wording"
fi

log "brand layer applied"
exit 0
