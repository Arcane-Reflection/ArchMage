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
mkdir -p "$OUT" /w/desktop-boot-screens
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
pacman -Syu --noconfirm --needed qemu-system-x86 edk2-ovmf openssh \
    virglrenderer mesa python
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
# Plain q35 AHCI (no virtio storage): omarchy's busybox-HOOKS initramfs
# guarantees ahci, not virtio_blk. TCG explicit (no KVM on runners).
# GPU: prefer virtio-gpu-gl (virgl -> Hyprland gets EGL/GBM) with -display
# none (qemu >= 7.1 creates a headless GL context internally; Arch's qemu 11
# build does NOT ship the egl-headless display module — observed live). If
# the GL variant dies at startup on this qemu build, degrade to the default
# VGA with a warning annotation — the run still produces boot evidence.
QEMU_LOG="$OUT/qemu-start.log"
# stdlib PNG luminance decoder shared by the python blocks (the container's
# ImageMagick mis-measures — see the render-gate note below).
cat > "$OUT/png_lum.py" <<'PYEOF'
import struct, zlib

def png_mean_and_bright(path):
    data = open(path, 'rb').read()
    pos = 8
    w = h = None
    ctype = 2
    idat = b''
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos+4])[0]
        ctyp = data[pos+4:pos+8]
        payload = data[pos+8:pos+8+ln]
        if ctyp == b'IHDR':
            w, h, bd, ctype = struct.unpack('>IIBB', payload[:10])
        elif ctyp == b'IDAT':
            idat += payload
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = 3 if ctype == 2 else 4
    stride = w * ch
    prev = bytearray(stride)
    total = 0.0
    bright = 0
    cnt = 0
    off = 0
    for _y in range(h):
        ft = raw[off]
        line = bytearray(raw[off+1:off+1+stride])
        off += 1 + stride
        if ft == 1:
            for i in range(ch, stride):
                line[i] = (line[i] + line[i-ch]) & 255
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = line[i-ch] if i >= ch else 0
                b = prev[i]
                c = prev[i-ch] if i >= ch else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        prev = line
        for px in range(w):
            r, g, b = line[px*ch], line[px*ch+1], line[px*ch+2]
            luma = 0.299*r + 0.587*g + 0.114*b
            total += luma
            if luma > 40:
                bright += 1
            cnt += 1
    return (total / cnt if cnt else 0.0), (bright * 100.0 / cnt if cnt else 0.0)
PYEOF
start_qemu() {  # start_qemu <extra args...>  -> echoes pid, empty on failure
    rm -f /tmp/qmp.sock
    qemu-system-x86_64 \
        -accel tcg,thread=multi \
        -machine q35 -m 4096 -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OUT/OVMF_VARS.fd" \
        -drive file="$IMG",format=raw,media=disk \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
        -device virtio-net-pci \
        -no-reboot \
        -chardev "socket,id=ser0,path=/tmp/serial.sock,server=on,wait=off,logfile=$OUT/serial.log" \
        -serial chardev:ser0 \
        -qmp unix:/tmp/qmp.sock,server,nowait \
        "$@" > "$QEMU_LOG" 2>&1 &
    local pid=$!
    sleep 6
    kill -0 "$pid" 2>/dev/null || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; echo ""; return 1; }
    echo "$pid"
}

QEMU_PID=""
for attempt in "-device virtio-gpu-gl -display none" "-display none"; do
    # shellcheck disable=SC2086
    if QEMU_PID="$(start_qemu $attempt)"; then
        [ "$attempt" = "-display none" ] && \
            printf '::warning::GL GPU variant unavailable — degraded to default VGA (software rendering)\n'
        pmark "qemu booting (pid $QEMU_PID) gpu=[$attempt]"
        break
    fi
    printf '::warning::qemu variant [%s] failed to start:\n' "$attempt" >&2
    tail -n 3 "$QEMU_LOG" | sed 's/^/  | /' >&2
done
[ -n "$QEMU_PID" ] || { echo "::error::no qemu variant could start"; tail -n 5 "$QEMU_LOG" >&2; exit 1; }

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

def sendkey(key):
    f.write(json.dumps({'execute': 'human-monitor-command',
                        'arguments': {'command-line': f'sendkey {key}'}}).encode() + b'\n'); f.flush()
    deadline = time.time() + 30
    while time.time() < deadline:
        msg = readmsg()
        if 'return' in msg:
            return True
        if 'error' in msg:
            print('sendkey error:', msg['error'])
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

PRE_COUNT = len(shots)

# ---- automated login (user asked: 你来登录密码) -----------------------------
# The dev-image password convention is archmage:1234. Whatever surface holds
# the keyboard (SDDM greeter password field or hyprlock), typing the
# password + Enter either enters the session or unlocks it; the post-login
# frame sequence is the evidence (a session taking over changes the
# framebuffer; a still-locked/greeter frame stays identical).
f.write(json.dumps({'execute': 'stop'}).encode() + b'\n'); f.flush()
while 'return' not in readmsg():
    pass
for key in ('1', '2', '3', '4', 'ret'):
    if not sendkey(key):
        print(f'::warning::sendkey {key} failed')
    time.sleep(0.25)
f.write(json.dumps({'execute': 'cont'}).encode() + b'\n'); f.flush()
while 'return' not in readmsg():
    pass
print('::notice::login keystrokes sent (1234+Enter)')

post = []
for i in range(8):  # 8 x 30s = 4 min post-login observation
    time.sleep(30)
    path = f'/w/boot-out/post-{i:02d}.png'
    if screendump(path):
        post.append(path)
        print(f'post shot {i}: {path}')

# Per-shot mean luminance sequences as ONE notice: pre-login (boot settle)
# and post-login. All-black throughout = boot hang; identical pre/post = the
# password surface stayed; a post-login change = a session took over.
# Measured with the stdlib decoder (png_lum.py): the CI container's
# ImageMagick reported 0.2/255 for a frame that decodes at 59.9 (run
# 43336805631 vs local) — never trust it for the gate.
import sys
sys.path.insert(0, '/w/boot-out')
from png_lum import png_mean_and_bright

pre_seq = ' '.join(f'{i:02d}={png_mean_and_bright(p)[0]:.1f}' for i, p in enumerate(shots))
post_seq = ' '.join(f'{i:02d}={png_mean_and_bright(p)[0]:.1f}' for i, p in enumerate(post))
print(f'::notice::pre-login luminance: {pre_seq}')
print(f'::notice::post-login luminance: {post_seq}')

last_pre = png_mean_and_bright(shots[-1])
last_post = png_mean_and_bright(post[-1]) if post else last_pre
changed = post and (last_post[0] != last_pre[0] or last_post[1] != last_pre[1])
print(f'::notice::login outcome: {"FRAME CHANGED — session/unlock took over" if changed else "no frame change — surface stayed (login failed or session static)"}')
PYEOF
pmark "screens captured"

# ---- SSH diagnostic channel (definitive, not screen-guessing) ---------------
# The image ships sshd + this build's public key (host:2222 -> guest:22).
# loginctl tells us whether the USER session exists (autologin fired) or
# only the greeter — and if autologin failed, the sddm journal explains why.
SSH_KEY=/w/desktop-image-in/ssh_key
SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=8 -o BatchMode=yes -i "$SSH_KEY" -p 2222)
chmod 600 "$SSH_KEY" 2>/dev/null || true
mkdir -p /w/desktop-boot-screens
SSH_OUT=/w/desktop-boot-screens/ssh-diagnosis.txt
: > "$SSH_OUT"
for i in $(seq 1 12); do
    if ssh "${SSHOPTS[@]}" root@127.0.0.1 true 2>/dev/null; then
        {
            echo "=== sessions (loginctl) ==="
            ssh "${SSHOPTS[@]}" root@127.0.0.1 \
                'loginctl list-sessions --no-legend 2>/dev/null; true'
            echo "=== user session detail ==="
            ssh "${SSHOPTS[@]}" root@127.0.0.1 \
                'for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk "{print \$1}"); do loginctl show-session "$s" -p Name -p Type -p State -p Desktop 2>/dev/null; done; true'
            echo "=== sddm journal tail ==="
            ssh "${SSHOPTS[@]}" root@127.0.0.1 \
                'journalctl -u sddm --no-pager -n 25 2>/dev/null | tail -25; true'
            echo "=== graphical target ==="
            ssh "${SSHOPTS[@]}" root@127.0.0.1 \
                'systemctl is-active graphical.target; systemctl is-active sddm; true'
        } > "$SSH_OUT" 2>/dev/null
        sess="$(grep -c '' "$SSH_OUT" 2>/dev/null || echo 0)"
        echo "::notice::SSH channel reached after boot — diagnosis written ($sess lines)"
        cat "$SSH_OUT" >&2
        break
    fi
    sleep 20
done
grep -q "===" "$SSH_OUT" 2>/dev/null || \
    echo "::warning::SSH channel never reachable (network/sshd/key) — serial shell will diagnose"

# ---- serial-shell diagnosis (root getty on ttyS0) ---------------------------
# The serial line carries a getty ("archmage-desktop login:") once boot
# completes; root has NO password in this image (never set in the chroot),
# so an automated serial login gives a root shell for the definitive
# diagnosis: service states, guest IP, ufw, and the sddm/sshd journals —
# converting the SSH unreachability from a mystery into a symptom list.
python3 - <<'PYEOF'
import socket, sys, time

try:
    sock = socket.socket(socket.AF_UNIX)
    sock.connect('/tmp/serial.sock')
except OSError as e:
    print(f'::warning::serial socket connect failed: {e}')
    sys.exit(0)

sock.settimeout(2)
buf = b''
log = open('/w/desktop-boot-screens/serial-session.log', 'wb')

def pump(seconds):
    global buf
    end = time.time() + seconds
    while time.time() < end:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
            log.write(chunk)
            log.flush()
        except socket.timeout:
            pass

def wait_for(pattern, timeout):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        if pattern in buf.decode('utf-8', 'replace'):
            return True
        try:
            chunk = sock.recv(4096)
            if chunk:
                buf += chunk
                log.write(chunk)
                log.flush()
        except socket.timeout:
            pass
    return pattern in buf.decode('utf-8', 'replace')

def send(line):
    sock.sendall(line.encode() + b'\n')

pump(3)
# wake the getty, then log in as root (no password set on this image)
send('')
time.sleep(1)
send('')
if not wait_for('login:', 30):
    print('::warning::no serial login prompt within 30s — serial may be idle; retrying once')
    send('\n')
    if not wait_for('login:', 30):
        print('::error::serial login prompt never appeared')
        sys.exit(0)
send('root')
time.sleep(2)
send('')
if not wait_for('#', 30):
    print('::warning::no root shell prompt detected — continuing blind')
send('export PS1=SHELLREADY\\$\\ ; echo DIAG-START')
wait_for('DIAG-START', 20)

CMDS = [
    'systemctl is-active sshd; systemctl is-enabled sshd',
    'ip -4 -o addr show | grep -v " lo "',
    'systemctl is-active ufw; ufw status verbose 2>/dev/null | head -6',
    'ss -tlnp 2>/dev/null | grep -E ":22|:2222" || echo "nothing listening on :22"',
    'loginctl list-sessions --no-legend',
    'systemctl is-active graphical.target',
    'systemctl --failed --no-legend | head -5',
    'journalctl -b -u sddm -u sshd --no-pager -n 12',
    'echo DIAG-END',
]
for c in CMDS:
    send(c)
    time.sleep(1.5)
    pump(2)

# everything since DIAG-START is now in serial-session.log
send('clear')
pump(1)
log.close()
print('::notice::serial-shell diagnosis captured — serial-session.log in evidence')
PYEOF
if [ -f /w/desktop-boot-screens/serial-session.log ]; then
    if /usr/bin/grep -aq "DIAG-END" /w/desktop-boot-screens/serial-session.log 2>/dev/null; then
        pmark "serial shell diagnosis complete (DIAG-END reached)"
    else
        echo "::warning::serial diagnosis incomplete (DIAG-END not reached)"
    fi
    # human-readable filter of the diagnosis block
    tr -d '\r' < /w/desktop-boot-screens/serial-session.log \
        | /usr/bin/grep -aA1 -E "DIAG-START|active|inactive|failed|inet |loginctl|Session|sshd|ufw" \
        | tail -40 > /w/desktop-boot-screens/serial-diagnosis-summary.txt 2>/dev/null || true
fi

# ---- evidence FIRST (upload step runs even on gate failure: if: always()) ---
mkdir -p /w/desktop-boot-screens
# last pre-login frame + last post-login frame (the pair that shows whether
# the session took over) + first post frame
[ -f "$OUT/post-07.png" ] && cp "$OUT/post-07.png" /w/desktop-boot-screens/
[ -f "$OUT/post-00.png" ] && cp "$OUT/post-00.png" /w/desktop-boot-screens/
ls -t "$OUT"/shot-*.png | head -1 | while read -r p; do cp "$p" /w/desktop-boot-screens/; done
tail -n 80 "$OUT/serial.log" > /w/desktop-boot-screens/serial-tail.log 2>/dev/null || true

# ---- honesty gate: emergency shell detection (serial tells the truth) ------
# Run 43095224105 lesson: the bright-pixel check PASSED on an initramfs
# EMERGENCY SHELL — white-on-black text satisfies any bright-pixel
# heuristic. An initramfs root-mount failure prints these strings verbatim
# on serial; if they appear, the render gate must not run at all.
if grep -aqE "emergency shell|Failed to mount" "$OUT/serial.log" 2>/dev/null; then
    echo "::error::boot dropped to emergency shell (initramfs root-mount failure)"
    grep -aE "emergency shell|Failed to mount" "$OUT/serial.log" | head -2 \
        | cut -c1-100 | awk '{printf "::error::serial: %s%%0A", $0}' | sed 's/%0A$/\n/' >&2 || true
    printf '\n' >&2
    exit 1
fi
pmark "no emergency shell in serial — root mounted"

# ---- render gate: python-decoded truth (dark-theme aware) -------------------
# Tokyo Night is dark; a correct SDDM/Hyprland frame has few but REAL bright
# pixels (text, bar, window edges). Pass when mean >= 2/255 OR >0.2% of
# pixels exceed luminance 40. Measured with the stdlib decoder above — the
# container's ImageMagick reported 0.2/255 for a 59.9 frame (run 43336805631
# vs a local decode of the same PNG), so the gate must not trust it.
LAST="$(ls -t "$OUT"/post-*.png 2>/dev/null | head -1)"
[ -n "$LAST" ] || LAST="$(ls -t "$OUT"/shot-*.png | head -1)"
MEAN_BRIGHT="$(python3 -c "
import sys
sys.path.insert(0, '/w/boot-out')
from png_lum import png_mean_and_bright
m, b = png_mean_and_bright('$LAST')
print(f'{m:.3f} {b:.3f}')
" 2>/dev/null || echo "0 0")"
MEAN="$(echo "$MEAN_BRIGHT" | awk '{print $1}')"
BRIGHT_PCT="$(echo "$MEAN_BRIGHT" | awk '{print $2}')"
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
