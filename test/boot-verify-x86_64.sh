#!/usr/bin/env bash
# boot-verify-x86_64.sh — D-0.3 desktop boot verification (runs INSIDE an
# archlinux:base-devel container, invoked by the desktop-boot-verify CI job).
#
# Why a container: the apt channel on the migrated ubuntu-26 runner stalled
# 18 minutes and died installing qemu/ovmf; the pacman channel is the exact
# path the desktop builder uses twice-green on the same runners. qemu runs
# unprivileged (TCG, no KVM) inside the container.
#
# Chain under test: OVMF -> limine fallback EFI (\EFI\BOOT\BOOTX64.EFI) ->
# linux-omarchy -> SDDM autologin -> Hyprland session. Gate: the final QMP
# screenshot renders non-black (mean luminance >= 2/255) — the D-0.3
# "grim 非黑屏" contract measured from outside the VM.
#
# Expects (bind-mounted at /w):
#   /w/desktop-image-in/archmage-desktop-*.img   decompressed raw image
# Outputs:
#   /w/desktop-boot-screens/  last two frames + serial tail + BOOT-VERIFY.txt
#   /w/boot-out/              console log + all frames (triage)
set -Eeuo pipefail

OUT=/w/boot-out
mkdir -p "$OUT"
exec > >(tee "$OUT/console.log") 2>&1
on_err() {
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    joined="$(tail -n 12 "$OUT/console.log" | cut -c1-100 \
        | awk '{printf "%s%%0A", $0}')"
    printf '::error::boot verify failed rc=%s\n' "$rc" >&2
    printf '::error::console tail: %s\n' "${joined:-<nothing captured>}" >&2
}
trap on_err EXIT
pmark() { printf '::notice::%s\n' "$*"; }

# ---- toolchain: pacman (proven path on these runners) ----------------------
grep -q '^DisableSandbox$' /etc/pacman.conf \
    || sed -i 's/^\[options\]$/[options]\nDisableSandbox/' /etc/pacman.conf
printf '%s\n' \
    'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
    'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
    > /etc/pacman.d/mirrorlist
pacman -Syu --noconfirm --needed qemu-system-x86 edk2-ovmf imagemagick
pmark "toolchain ready (qemu $(qemu-system-x86_64 --version | head -1 | awk '{print $3, $4}'))"

# ---- OVMF (Arch edk2-ovmf layout) ------------------------------------------
# Arch ships the 4M flash variants (OVMF_CODE.4m.fd / OVMF_VARS.4m.fd) —
# the first container round died on the non-4m glob, and its directory
# annotation listed the real names (instrumentation paying off).
OVMF_CODE="$(ls /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd \
                 /usr/share/edk2-ovmf/x64/OVMF_CODE.fd 2>/dev/null | head -1 || true)"
OVMF_VARS_SRC="$(ls /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd \
                    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd 2>/dev/null | head -1 || true)"
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS_SRC" ] || {
    echo "::error::edk2-ovmf files missing — /usr/share/edk2-ovmf contents:"
    ls -R /usr/share/edk2-ovmf 2>/dev/null || true
    exit 1
}
pmark "OVMF: $OVMF_CODE"
cp "$OVMF_VARS_SRC" "$OUT/OVMF_VARS.fd"

IMG="$(ls /w/desktop-image-in/archmage-desktop-*.img | head -1)"
[ -n "$IMG" ] || { echo "::error::no desktop image at /w/desktop-image-in/"; exit 1; }
pmark "image: $(basename "$IMG") ($(du -h "$IMG" | cut -f1))"

# ---- boot + settle-loop screenshots ----------------------------------------
# Plain q35 AHCI (no virtio): omarchy's busybox-HOOKS initramfs guarantees
# ahci, not virtio_blk. TCG explicit (no KVM on runners). Screendumps via
# native QMP (format=png, qemu >= 7.1).
qemu-system-x86_64 \
    -accel tcg,thread=multi \
    -machine q35 -m 4096 -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$OUT/OVMF_VARS.fd" \
    -drive file="$IMG",format=raw,media=disk \
    -display none -no-reboot \
    -serial "file:$OUT/serial.log" \
    -qmp unix:/tmp/qmp.sock,server,nowait &
QEMU_PID=$!
pmark "qemu booting (pid $QEMU_PID)"

python3 - <<'PYEOF'
import json, socket, sys, time

sock = socket.socket(socket.AF_UNIX)
sock.connect('/tmp/qmp.sock')
f = sock.makefile('rwb')

def readmsg():
    line = f.readline()
    if not line:
        raise RuntimeError('QMP EOF')
    return json.loads(line)

while 'QMP' not in readmsg():
    pass
f.write(json.dumps({'execute': 'qmp_capabilities'}).encode() + b'\n'); f.flush()
while 'return' not in readmsg():
    pass

def screendump(path):
    f.write(json.dumps({'execute': 'screendump',
                        'arguments': {'filename': path, 'format': 'png'}}).encode() + b'\n'); f.flush()
    deadline = time.time() + 60
    while time.time() < deadline:
        msg = readmsg()
        if 'return' in msg:
            return True
        if 'error' in msg:
            print('screendump error:', msg['error'])
            return False
    return False

shots = []
for i in range(26):  # 26 x 30s = 13.5 min settle window (TCG boot is slow)
    time.sleep(60 if not shots else 30)
    path = f'/w/boot-out/shot-{i:02d}.png'
    if screendump(path):
        shots.append(path)
        print(f'shot {i}: {path}')

if not shots:
    print('::error::no screendump succeeded')
    sys.exit(1)

# Per-shot mean luminance sequence as ONE notice: all-black throughout = boot
# hang; a rise = the framebuffer reached a real renderer. Tokyo Night (the
# whole Omarchy theme) is DARK — a correct desktop frame can mean <2/255, so
# this sequence is the diagnostic, the mean alone is not.
import subprocess
means = []
for p in shots:
    try:
        m = subprocess.run(['convert', p, '-colorspace', 'Gray',
                            '-format', '%[fx:mean*255]', 'info:'],
                           capture_output=True, text=True, timeout=120).stdout.strip()
        means.append(m.splitlines()[0] if m else '0')
    except Exception:
        means.append('ERR')
seq = ' '.join(f'{i:02d}={v}' for i, v in enumerate(means))
print(f'::notice::luminance sequence: {seq}')
PYEOF
pmark "screens captured"

# ---- evidence FIRST (upload step runs even on gate failure: if: always()) ---
mkdir -p /w/desktop-boot-screens
ls -t "$OUT"/shot-*.png | head -3 | while read -r p; do cp "$p" /w/desktop-boot-screens/; done
tail -n 80 "$OUT/serial.log" > /w/desktop-boot-screens/serial-tail.log 2>/dev/null || true

# ---- render gate: bright-pixel fraction OR mean (dark-theme aware) ----------
# Tokyo Night is dark; a correct SDDM/Hyprland frame has few but REAL bright
# pixels (text, bar, window edges). Pass when mean >= 2/255 OR >0.2% of
# pixels exceed luminance 40. A hung/black frame has ~none of either.
LAST="$(ls -t "$OUT"/shot-*.png | head -1)"
# Fraction of bright pixels: threshold at ~40/255 then 1-mean (the fx
# 'mean>0.157' form evaluates once on the whole-image mean, not per pixel).
BRIGHT_FRAC="$(convert "$LAST" -colorspace Gray -threshold 16% -format "%[fx:1-mean]" info: 2>/dev/null || echo 0)"
MEAN="$(convert "$LAST" -colorspace Gray -format "%[fx:mean*255]" info: 2>/dev/null || echo 0)"
BRIGHT_PCT="$(python3 -c "print(round(float('$BRIGHT_FRAC' or 0)*100, 3))")"
echo "final frame: $LAST (mean luminance $MEAN, bright(>40) pixels ${BRIGHT_PCT}%)"
python3 - <<PYEOF
import sys
mean = float('$MEAN' or 0)
bright = float('$BRIGHT_PCT' or 0)
if mean < 2.0 and bright < 0.2:
    print('::error::final frame is (near-)black: mean %.1f/255, bright pixels %.3f%%'
          % (mean, bright))
    sys.exit(1)
print('boot render OK: mean %.1f/255, bright pixels %.3f%%' % (mean, bright))
PYEOF
pmark "non-black gate passed"

{
    echo "ArchMage desktop boot verification (D-0.3)"
    echo "frame: $(basename "$LAST") — mean $MEAN/255, bright(>40) ${BRIGHT_PCT}% (render gate passed)"
    echo "chain: OVMF -> limine fallback EFI -> linux-omarchy -> SDDM autologin -> Hyprland"
} > /w/desktop-boot-screens/BOOT-VERIFY.txt
cat /w/desktop-boot-screens/BOOT-VERIFY.txt
kill "$QEMU_PID" 2>/dev/null || true
pmark "boot verification complete"
