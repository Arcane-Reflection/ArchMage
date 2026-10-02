#!/usr/bin/env bash
# run-matrix.sh — six-way toolkit input matrix (03-01, IME-03; IM-03).
#
# Runs INSIDE the session VM, invoked by test/ime/ime-verify.sh. Six rows,
# exactly the 03-RESEARCH Q1 matrix; each row is an independent sub-case (one
# row's failure never blocks the rest), every row asserts its own commit
# ground truth (「你好」 in, raw pinyin never in the buffer):
#
#   gtk4-wayland   GTK_IM_MODULE unset, GDK_BACKEND=wayland (text-input-v3)
#   gtk3-wayland   same, Gtk 3.0 build of the capture app
#   gtk3-x11       GDK_BACKEND=x11 + GTK_IM_MODULE=fcitx + XMODIFIERS
#                  (Xwayland row; xwayland process presence recorded)
#   qt5            EXPLICIT QT_QPA_PLATFORM=xcb (Qt 5.15 wayland QPA needs
#                  compositor dmabuf — unavailable under the pixman renderer
#                  in QEMU; declared, not silent) + QT_IM_MODULE=fcitx
#   qt6            QT_IM_MODULES=wayland;fcitx;ibus (>= 6.7 semantics; Qt6
#                  wayland runs on wl_shm, no EGL needed — observed live)
#   chromium       ozone wayland + --enable-wayland-ime
#                  --wayland-text-input-version=3 (research pitfall 3: the
#                  flags are MANDATORY — without them chromium silently
#                  falls back to Xwayland and the matrix lies). Ground truth
#                  is read over CDP (--remote-debugging-port).
#
# PER-CASE FRESH SESSIONS (observed live 03-01): this phoc 0.57 + wlroots
# pairing segfaults whenever the input-method keyboard grab tears down —
# which happens on EVERY focus transition, on killing a focused capture app,
# even on a clean app exit. A single shared session therefore cannot survive
# six app lifecycles; each case instead runs in its own fresh phosh session
# (stop -> start -> wait for the Wayland socket -> fresh fcitx5). The crash
# during a wholesale teardown is irrelevant: nothing of the old session is
# reused. Within one session the only rule that matters is the one the
# tracer already follows: exactly one focus lifecycle, never kill a focused
# app while the session must live on.
#
# Heavy dependencies (chromium, both PyQt stacks, the wayland QPAs, the CDP
# websocket client) are installed IN-VM once, before the cases run — counted
# against the harness timeout budget, idempotent via --needed.
#
# Usage (in-VM):  run-matrix.sh <artifacts-dir>
# Output:         <artifacts-dir>/ime-matrix.json (same directory contract
#                 as ime.json; per-case logs/screenshots: matrix-*)
#
# All JSON assembly uses python3 (jq is deliberately not a VM dependency).

set -uo pipefail

R=${1:?artifacts dir required}
SRC=/root/ime
PYQT_PKGS="python-pyqt5 python-pyqt6 qt5-wayland qt6-wayland chromium python-websocket-client xdotool"

log() { printf '[matrix] %s\n' "$*" >&2; }

CASES_JSONL=$R/matrix-cases.jsonl
: > "$CASES_JSONL"

# --- 0) matrix dependencies (idempotent; TUNA + embedded archmage-testing) --
if ! pacman -Q $PYQT_PKGS >/dev/null 2>&1; then
    log "installing matrix dependencies: $PYQT_PKGS"
    pacman -Sy --noconfirm --needed $PYQT_PKGS > "$R/matrix-pacman.log" 2>&1 || \
        log "WARNING: matrix dependency install had failures — see matrix-pacman.log"
else
    log "matrix dependencies already present"
fi
pacman -Q $PYQT_PKGS > "$R/matrix-deps.list" 2>&1 || true

# --- helpers -----------------------------------------------------------------

kill_apps() {
    pkill -f 'entry-app.py' 2>/dev/null || true
    pkill -f 'chromium.*ime-matrix' 2>/dev/null || true
    # Wait the processes actually gone — the next case's fresh_session must
    # not race a dying app for the compositor/focus state (observed live
    # 03-01: a still-dying focused app holds the IM keyboard grab while the
    # next session comes up).
    local i
    for i in $(seq 1 10); do
        pgrep -f 'entry-app.py|chromium.*ime-matrix' >/dev/null 2>&1 || return 0
        sleep 1
    done
    pkill -9 -f 'entry-app.py|chromium.*ime-matrix' 2>/dev/null || true
    sleep 1
}

# fresh_session <name> — tear the whole session down and bring a clean one
# up, with a fresh fcitx5 bound to it. Ordering matters (observed live): the
# old fcitx5 must be FULLY dead before the restart (SIGTERM is asynchronous —
# a still-dying instance owns the new bus's fcitx5 name for a moment and the
# new instance exits during addon load), and the new session bus must be
# detectably NEW (the env file persists across restarts, so sourcing it the
# moment the wayland socket appears can hand out the DEAD bus address from
# the previous session). Per-case fcitx5 log lands in the matrix-* pull set.
fresh_session() {
    local name=${1:?case name required}
    local i sock busaddr oldbus
    oldbus=$(grep -o 'unix:path=[^,]*' /run/user/0/phosh-session.env 2>/dev/null || true)
    pkill -x fcitx5 2>/dev/null || true
    for i in $(seq 1 10); do
        pgrep -x fcitx5 >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -9 -x fcitx5 2>/dev/null || true
    kill_apps
    systemctl stop phosh >/dev/null 2>&1 || true
    for i in $(seq 1 15); do
        systemctl is-active phosh >/dev/null 2>&1 || break
        sleep 1
    done
    systemctl reset-failed phosh >/dev/null 2>&1 || true
    systemctl start phosh >/dev/null 2>&1 || { log "fresh_session: systemctl start phosh failed"; return 1; }
    sock=""
    for i in $(seq 1 45); do
        sock=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | sort | tail -1)
        if [ -n "$sock" ] && [ -f /run/user/0/phosh-session.env ]; then
            # The env file must carry the NEW bus: a socket path that exists
            # now and differs from the pre-restart bus address.
            busaddr=$(grep -o 'unix:path=[^,]*' /run/user/0/phosh-session.env 2>/dev/null || true)
            if [ -n "$busaddr" ] && [ "$busaddr" != "$oldbus" ] && \
               [ -S "${busaddr#unix:path=}" ]; then
                break
            fi
        fi
        sock=""
        sleep 2
    done
    if [ -z "$sock" ]; then
        log "fresh_session: no Wayland socket with a fresh session bus within 90s"
        return 1
    fi
    set -a; . /run/user/0/phosh-session.env; set +a
    export XDG_RUNTIME_DIR=/run/user/0
    export WAYLAND_DISPLAY=$sock
    unset GTK_IM_MODULE
    setsid nohup fcitx5 -D > "$R/matrix-$name-fcitx5.log" 2>&1 < /dev/null &
    for i in $(seq 1 20); do
        fcitx5-remote >/dev/null 2>&1 && return 0
        sleep 1
    done
    log "fresh_session: fcitx5 not answering after 20s (see matrix-$name-fcitx5.log)"
    return 1
}

# buffer_texts <app-log> — ground truth: the BUFFER events only (preedit
# events never carry committed text; the raw-pinyin check below must judge
# the buffer, not the IM's preedit display).
buffer_texts() {
    python3 - "$1" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("event") in ("text-changed", "activate"):
                print(rec.get("text", ""))
except FileNotFoundError:
    pass
PYEOF
}

# wait_focus <app-log> <timeout-sec>
wait_focus() {
    local logf=$1 t=${2:-30} i=0
    while [ "$i" -lt "$t" ]; do
        grep -q entry-focus-in "$logf" 2>/dev/null && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# wait_truth_gtkqt <app-log> <timeout-sec> — prints the buffer texts once
# 你好 committed (or on timeout); exit 0 iff committed.
wait_truth_gtkqt() {
    local logf=$1 t=${2:-30} i=0 texts
    while [ "$i" -lt "$t" ]; do
        texts=$(buffer_texts "$logf")
        if printf '%s' "$texts" | grep -q '你好'; then
            printf '%s\n' "$texts"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    printf '%s\n' "$(buffer_texts "$logf")"
    return 1
}

# type_x <text...> — XTEST typing for the Xwayland rows. The compositor's
# virtual-keyboard → Xwayland keycode path mistranslates wtype-typed letters
# (observed live 03-01: `wtype abc` lands as 「12」 in a QLineEdit with no
# fcitx5 running at all), so X rows type through XTEST instead: the keys are
# injected at the X server and reach the app's fcitx input module directly
# (app → DBus → fcitx5 → commit — the exact access path this row asserts).
type_x() {
    local winid
    winid=$(xdotool search --name 'archmage-ime' | tail -1) || return 1
    xdotool windowactivate --sync "$winid" 2>/dev/null || true
    xdotool type --delay 90 "$@"
}

# type_round <shot> — switch to pinyin, type nihao, screenshot the candidate
# window during preedit, select the first candidate with space.
type_round() {
    local shot=$1
    fcitx5-remote -s keyboard-us 2>/dev/null || true
    fcitx5-remote -s pinyin || return 1
    sleep 0.5
    wtype nihao || return 1
    sleep 1.5
    grim "$shot" 2>/dev/null || true
    wtype -k space || return 1
    return 0
}

# type_round_x <shot> — Xwayland twin of type_round (xdotool/XTEST).
type_round_x() {
    local shot=$1
    fcitx5-remote -s keyboard-us 2>/dev/null || true
    fcitx5-remote -s pinyin || return 1
    sleep 0.5
    type_x nihao || return 1
    sleep 1.5
    grim "$shot" 2>/dev/null || true
    xdotool key space || return 1
    return 0
}

append_case() {  # append_case <name> <kind> <version> <status> <dur> <details>
    python3 - "$@" <<'PYEOF' >> "$CASES_JSONL"
import json, sys
name, kind, version, status, dur, details = sys.argv[1:7]
print(json.dumps({"name": name, "toolkit": kind, "version": version,
                  "status": status, "duration_seconds": int(dur),
                  "details": details}, ensure_ascii=False))
PYEOF
}

# gtkqt_case <name> <kind> <version> <typing: w|x> <cmd with env assignments...>
# typing "w" = wtype (Wayland-native rows; keys flow through the compositor
# seat and fcitx5's waylandim grab); typing "x" = xdotool/XTEST (Xwayland
# rows — the compositor's virtual-keyboard → X keycode path mistranslates
# wtype-typed letters, observed live 03-01; XTEST injects at the X server so
# the app's fcitx input module → DBus → fcitx5 path — the access path these
# rows assert — stays intact).
gtkqt_case() {
    local name=$1 kind=$2 version=$3 typing=$4
    shift 4
    local logf=$R/matrix-$name-app.log errf=$R/matrix-$name-app.err
    local shot=$R/matrix-$name-candidate.png nofocus=$R/matrix-$name-nofocus.png
    local t0 t1 focus=missing commit=missing texts="" details="" truth_ok=no
    : > "$logf"
    : > "$errf"
    t0=$SECONDS
    if ! fresh_session "$name"; then
        commit=session-failed
    else
        setsid nohup env -u GTK_IM_MODULE ARCHMAGE_IME_APP_LOG="$logf" \
            "$@" > /dev/null 2> "$errf" < /dev/null &
        if wait_focus "$logf" 30; then
            focus=ok
        else
            # Diagnostic evidence for the no-focus shape: what is on screen
            # and what did the app print (pulled via the matrix-* glob).
            grim "$nofocus" 2>/dev/null || true
        fi
        local typed=no
        if [ "$typing" = x ]; then
            [ "$focus" = ok ] && type_round_x "$shot" && typed=yes
        else
            [ "$focus" = ok ] && type_round "$shot" && typed=yes
        fi
        if [ "$typed" = yes ]; then
            if texts=$(wait_truth_gtkqt "$logf" 30); then
                commit=ok
            else
                commit=no-commit
            fi
        else
            commit=skipped
        fi
    fi
    t1=$SECONDS
    if [ "$commit" = ok ]; then
        if printf '%s' "$texts" | grep -q 'nihao'; then
            details="raw pinyin leaked into the buffer: $(printf '%s' "$texts" | tr '\n' ';' | head -c 120)"
        else
            truth_ok=yes
            details="committed 「$(printf '%s' "$texts" | grep '你好' | tail -1)」"
        fi
    else
        details="focus=$focus commit=$commit"
        [ -s "$errf" ] && details="$details app-stderr:$(tr '\n' ';' < "$errf" | head -c 160)"
    fi
    local status=fail
    [ "$truth_ok" = yes ] && status=pass
    append_case "$name" "$kind" "$version" "$status" "$((t1 - t0))" "$details"
    log "$name: $status ($details)"
}

# --- the five gtk/qt rows ----------------------------------------------------
# NOTE the env assignments are part of the command; env resolves -u first,
# so gtk3's GTK_IM_MODULE=fcitx survives the unconditional -u.
# gtk3 rows carry GSK_RENDERER=cairo: GDK Wayland/X11 presentation needs EGL
# (or GLX) for the window buffer, which the pixman renderer cannot provide
# (no dmabuf under QEMU without virgl) — observed live 03-01: the window maps
# but never presents its content. Cairo is the toolkit's own software path;
# the row's IM variable (GTK_IM_MODULE) is untouched.
gtkqt_case gtk4-wayland gtk 4 w GDK_BACKEND=wayland \
    python3 "$SRC/apps/gtk-entry-app.py" --gtk 4
gtkqt_case gtk3-wayland gtk 3 w GDK_BACKEND=wayland GSK_RENDERER=cairo \
    python3 "$SRC/apps/gtk-entry-app.py" --gtk 3
gtkqt_case gtk3-x11 gtk 3 x GDK_BACKEND=x11 DISPLAY=:0 GSK_RENDERER=cairo \
    GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx \
    python3 "$SRC/apps/gtk-entry-app.py" --gtk 3

XWAYLAND_PRESENT=no
pgrep -x Xwayland >/dev/null 2>&1 && XWAYLAND_PRESENT=yes

# Qt5 over EXPLICIT Xwayland (observed live 03-01): Qt 5.15's wayland client
# buffer integration requires compositor-side linux-dmabuf, which the pixman
# renderer does not advertise (no GBM device under QEMU without virgl), and
# the app aborts at EGL init. The row's VARIABLE is the IM access path
# (QT_IM_MODULE=fcitx, the factory default from environment.d) — identical
# over xcb — so the platform is made explicit here instead of silently
# falling back (T-03-13: a silent platform fallback would be the fake-green
# shape; this one is declared and recorded in the case JSON).
gtkqt_case qt5 qt 5 x QT_QPA_PLATFORM=xcb DISPLAY=:0 QT_IM_MODULE=fcitx \
    XMODIFIERS=@im=fcitx \
    python3 "$SRC/apps/qt-entry-app.py" --qt 5
gtkqt_case qt6 qt 6 w QT_IM_MODULES='wayland;fcitx;ibus' \
    python3 "$SRC/apps/qt-entry-app.py" --qt 6

# --- the chromium row (CDP ground truth) -------------------------------------
CHROME_LOG=$R/matrix-chromium-app.log
CHROME_SHOT=$R/matrix-chromium-candidate.png
CHROME_PORT=9222
: > "$CHROME_LOG"
t0=$SECONDS
CHROME_UP=no
CHROMIUM_VALUE=""
CHROMIUM_COMMIT=session-failed
if fresh_session chromium; then
    CHROMIUM_COMMIT=missing
    cat > "$SRC/matrix.html" <<'HTMLEOF'
<!doctype html>
<html><head><meta charset="utf-8"><title>ime-matrix</title></head>
<body><textarea id="t" rows="4" cols="40" autofocus></textarea>
<script>document.getElementById("t").focus();</script>
</body></html>
HTMLEOF
    # --no-sandbox is mandatory: the session runs as root and chromium
    # refuses to start without it (exits before binding the CDP port).
    setsid nohup chromium \
        --ozone-platform=wayland \
        --enable-wayland-ime \
        --wayland-text-input-version=3 \
        --no-sandbox \
        --remote-allow-origins='*' \
        "--remote-debugging-port=$CHROME_PORT" \
        --no-first-run --no-default-browser-check --disable-gpu \
        --user-data-dir=/root/ime/chromium-profile \
        'file:///root/ime/matrix.html' > "$CHROME_LOG" 2>&1 < /dev/null &

    for _ in $(seq 1 90); do
        if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$CHROME_PORT/json/version', timeout=2)" >/dev/null 2>&1; then
            CHROME_UP=yes
            break
        fi
        sleep 1
    done

    read_cdp_value() {
        python3 - "$CHROME_PORT" 2>>"$R/matrix-chromium-cdp.err" || return 1 <<'PYEOF'
import json, sys, urllib.request
from websocket import create_connection  # python-websocket-client
targets = json.load(urllib.request.urlopen(
    f"http://127.0.0.1:{sys.argv[1]}/json", timeout=5))
# Pick the matrix page itself — the first "page" target is not necessarily
# ours, and an evaluate against the wrong target silently reads as "".
page = next((t for t in targets
             if t.get("type") == "page" and "matrix.html" in t.get("url", "")), None)
if page is None:
    print("NO-MATRIX-TARGET")
    sys.exit(0)
ws = create_connection(page["webSocketDebuggerUrl"], timeout=5)
ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                    "params": {"expression": "document.getElementById('t') ? document.getElementById('t').value : 'NO-ELEMENT'",
                               "returnByValue": True}}))
while True:
    msg = json.loads(ws.recv())
    if msg.get("id") == 1:
        res = msg["result"]["result"]
        # An evaluate exception carries no value — surface it instead of
        # letting it masquerade as an empty textarea (observed live 03-01).
        print(res.get("value", f"EVAL-ERROR:{res.get('description', '')[:120]}"))
        break
ws.close()
PYEOF
    }

    if [ "$CHROME_UP" = yes ]; then
        # Let the textarea settle: the first key after page load was observed
        # to be swallowed by the focus transition (observed live 03-01 —
        # CDP read back 'bc' for an 'abc' typing). A bare modifier tap is a
        # no-op for the text buffer.
        sleep 3
        wtype -k shift 2>/dev/null || true
        sleep 1
    fi
    if [ "$CHROME_UP" = yes ] && type_round "$CHROME_SHOT"; then
        # A second space is harmless once committed (a trailing space before
        # 你好's assertions still pass) and re-fires candidate selection if
        # the first one was swallowed by the focus transition.
        sleep 1
        wtype -k space 2>/dev/null || true
        for _ in $(seq 1 30); do
            CHROMIUM_VALUE=$(read_cdp_value || true)
            if printf '%s' "$CHROMIUM_VALUE" | grep -q '你好'; then
                CHROMIUM_COMMIT=ok
                break
            fi
            sleep 1
        done
        [ "$CHROMIUM_COMMIT" = ok ] || CHROMIUM_COMMIT=no-commit
    else
        CHROMIUM_COMMIT=skipped
    fi
fi
t1=$SECONDS
CHROMIUM_STATUS=fail
CHROMIUM_DETAILS="cdp=$CHROME_UP commit=$CHROMIUM_COMMIT value=「$(printf '%s' "$CHROMIUM_VALUE" | tr -d '\n' | head -c 60)」"
if [ "$CHROME_UP" = yes ] && [ "$CHROMIUM_COMMIT" = ok ] && \
   ! printf '%s' "$CHROMIUM_VALUE" | grep -q 'nihao'; then
    CHROMIUM_STATUS=pass
    CHROMIUM_DETAILS="committed via wayland-ime; CDP textarea value 「$(printf '%s' "$CHROMIUM_VALUE" | tr -d '\n')」"
elif printf '%s' "$CHROMIUM_VALUE" | grep -q 'nihao'; then
    CHROMIUM_DETAILS="raw pinyin leaked into the textarea: $CHROMIUM_VALUE (silent Xwayland/direct-input fallback?)"
fi
append_case chromium-wayland chromium ozone-wayland "$CHROMIUM_STATUS" \
    "$((t1 - t0))" "$CHROMIUM_DETAILS"
log "chromium-wayland: $CHROMIUM_STATUS"

# --- assemble ime-matrix.json -------------------------------------------------
MATRIX_STATUS=$(python3 - "$R" "$XWAYLAND_PRESENT" <<'PYEOF'
import json, sys, os
r, xwayland = sys.argv[1], sys.argv[2]
cases = []
with open(os.path.join(r, "matrix-cases.jsonl"), encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if line:
            cases.append(json.loads(line))
status = "pass" if (len(cases) == 6 and all(c["status"] == "pass" for c in cases)) else "fail"
out = {
    "schema_version": 1,
    "check": "archmage-ime-input-matrix",
    "arch": "x86_64",
    "tier": "qemu-kvm",
    "cases": cases,
    "xwayland_present": xwayland == "yes",
    "status": status,
}
with open(os.path.join(r, "ime-matrix.json"), "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print(status)
PYEOF
)
printf 'ime-matrix.json: status=%s\n' "$MATRIX_STATUS" >&2

kill_apps

if [ "$MATRIX_STATUS" != pass ]; then
    exit 1
fi
exit 0
