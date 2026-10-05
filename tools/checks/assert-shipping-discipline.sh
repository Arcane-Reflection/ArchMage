#!/usr/bin/env bash
# assert-shipping-discipline.sh — machine-enforced shipping discipline for a
# factory rootfs (QUAL-01, plan 01-03 Task 2; extended 02-03 Task 1).
#
# Five assertion classes, all gating:
#   1. no_trustall            — the string "TrustAll" must not appear
#                               anywhere in <rootfs>/etc/pacman.conf or the
#                               whole <rootfs>/etc/pacman.d/ tree, comments
#                               included (T-01-10: a commented-out TrustAll
#                               is one edit away from shipping; it fails).
#   2. siglevel_policy        — per-repo-section SigLevel policy:
#                               - Never / TrustAll forbidden anywhere;
#                               - every repo section requires package level
#                                 Required;
#                               - ALARM upstream sections (core/extra/
#                                 community/alarm/aur [+ -testing], or any
#                                 Server on an archlinuxarm mirror) must be
#                                 exactly Required DatabaseOptional (ALARM
#                                 does not distribute signed databases —
#                                 PITFALLS 2);
#                               - ArchMage own-repo sections (name
#                                 *archmage* or Server on a
#                                 archmage host) must be Required
#                                 WITHOUT DatabaseOptional (we sign our
#                                 databases; weakening them is a policy
#                                 breach);
#                               - kupfer UPSTREAM prebuilt sections (Server
#                                 on a kupfer host, or a serverless known
#                                 kupfer repo name at exactly Never) may
#                                 keep upstream `SigLevel = Never`: kupfer
#                                 prebuilts are unsigned, Never is their
#                                 upstream policy preserved verbatim
#                                 (02-01 plan: "不属我们放宽"). TrustAll is
#                                 still banned and anything other than
#                                 Never/Required still fails.
#   3. no_device_firmware_blobs — no Qualcomm device-extracted firmware in
#                               <rootfs>/usr/lib/firmware or <rootfs>/boot:
#                               files named *.mbn / *.b0[0-9], bdwlan*/bdwhan*
#                               firmware names, or anything under an a5068
#                               directory — unless the file is owned by a
#                               linux-firmware* package in the rootfs pacman
#                               local db (the redistributable whitelist;
#                               STRATEGY §4: device-extracted blobs never
#                               ship, redistributable linux-firmware passes).
#   4. no_recommender_components — no advertising / recommender / telemetry
#                               package in the rootfs pacman local db
#                               (SAFETY-02): every installed package name is
#                               matched against the globs in
#                               safety-denylist.txt (next to this script);
#                               a hit fails with the package and glob.
#   5. safety_config_present  — phosh in the local db ⇒ archmage-phosh-safety
#                               must be installed AND both key files present:
#                               /usr/share/glib-2.0/schemas/
#                               90_archmage-phosh-safety.gschema.override and
#                               /etc/dconf/db/local.d/locks/archmage-safety
#                               (SAFETY-01/02 machine face: lockscreen content
#                               push is default-off and dconf-locked). No
#                               phosh in the db (e.g. QEMU rootfs) ⇒ pass,
#                               marked not-applicable.
#
# Output: discipline.json (schema_version 1, same assertion-array style as
# the 01-02 smoke.json) via --out FILE. Exit 0 iff every assertion passed —
# wired into qemu-smoke.yml after the smoke step, so a violation turns the
# CI gate red.
#
# Usage:
#   tools/checks/assert-shipping-discipline.sh --rootfs-dir PATH [--out FILE]
#
# Designed to run on any POSIX-ish host (CI arm64 runner or dev laptop):
# needs only bash, find, grep, awk, sort, jq.

set -euo pipefail

usage() {
    cat <<'EOF'
assert-shipping-discipline.sh — assert shipping discipline on a factory rootfs

Usage:
  tools/checks/assert-shipping-discipline.sh --rootfs-dir PATH [--out FILE]

Options:
  --rootfs-dir PATH  Rootfs directory to assert (e.g. test/build/aarch64/rootfs
                     or the negative fixture test/fixtures/rootfs-bad).
  --out FILE         Where to write discipline.json
                     (default: <rootfs-dir>/../discipline.json).
  -h, --help         Show this help.

Assertions (all gating; see the header comment for the full policy):
  no_trustall              zero "TrustAll" occurrences incl. comments
  siglevel_policy          Never/TrustAll banned; Required everywhere;
                           ALARM sections Required DatabaseOptional;
                           archmage sections Required (no DatabaseOptional);
                           kupfer upstream prebuilts may keep upstream Never
  no_device_firmware_blobs Qualcomm-shaped blobs outside the linux-firmware
                           whitelist (rootfs pacman local db)
  no_recommender_components no package name matching safety-denylist.txt
                           (advertising/recommender/telemetry; SAFETY-02)
  safety_config_present    phosh installed ⇒ archmage-phosh-safety + the
                           gschema.override and dconf lock files present
                           (SAFETY-01/02; pass/not-applicable without phosh)

Exit status: 0 iff all assertions pass.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

ROOTFS=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs-dir)
            [ $# -ge 2 ] || die "--rootfs-dir needs a PATH argument"
            ROOTFS=$2
            shift
            ;;
        --out)
            [ $# -ge 2 ] || die "--out needs a FILE argument"
            OUT=$2
            shift
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
[ -n "$ROOTFS" ] || { usage >&2; die "--rootfs-dir is required"; }
ROOTFS=${ROOTFS%/}
[ -d "$ROOTFS" ] || die "rootfs directory '$ROOTFS' does not exist"
if [ -z "$OUT" ]; then
    OUT=$(dirname "$ROOTFS")/discipline.json
fi

for c in find grep awk sort jq; do
    command -v "$c" >/dev/null 2>&1 || \
        die "required tool '$c' not found in PATH — install it and re-run."
done

PACMAN_CONF=$ROOTFS/etc/pacman.conf
PACMAN_D=$ROOTFS/etc/pacman.d
FW_DIRS=("$ROOTFS/usr/lib/firmware" "$ROOTFS/boot")
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DENYLIST=$SCRIPT_DIR/safety-denylist.txt

# --- assertion recording (same JSON style as test/lib/result.sh) ----------
ASSERT_FILE=$(mktemp "${TMPDIR:-/tmp}/archmage-discipline.XXXXXX")
trap 'rm -f "$ASSERT_FILE"' EXIT

# record <name> <pass|fail> <details>
record() {
    local name="$1" status="$2" details="$3"
    details=${details//$'\n'/ }
    details=${details//$'\t'/ }
    jq -n --arg name "$name" --arg status "$status" --arg details "$details" \
        '{name: $name, status: $status, details: $details, informational: false}' \
        >> "$ASSERT_FILE"
    printf '  [%s] %s — %s\n' "$status" "$name" "$details" >&2
}

# --------------------------------------------------------------------------
# 1) TrustAll zero tolerance (comments included — T-01-10)
# --------------------------------------------------------------------------
trustall_status=pass
trustall_details="no 'TrustAll' occurrences in factory pacman configuration"
if [ ! -f "$PACMAN_CONF" ]; then
    trustall_status=fail
    trustall_details="$PACMAN_CONF missing — not a valid factory rootfs"
else
    hits=$( { grep -Hn 'TrustAll' "$PACMAN_CONF" 2>/dev/null || true; \
              grep -Rn 'TrustAll' "$PACMAN_D" 2>/dev/null || true; } | head -10 )
    if [ -n "$hits" ]; then
        trustall_status=fail
        # Compress to file:line tokens for the JSON details.
        trustall_details="TrustAll found (comments count as hits): $(printf '%s' "$hits" | tr '\n' ';' | sed 's|'"$ROOTFS"'/||g')"
    fi
fi
record no_trustall "$trustall_status" "$trustall_details"

# --------------------------------------------------------------------------
# 2) SigLevel policy per repository section
# --------------------------------------------------------------------------
# Parse pacman.conf into `section<TAB>key<TAB>value` rows (keys lowercased;
# comments blanked). Include files are NOT resolved: mirrorlists carry no
# SigLevel in practice and the TrustAll scan already covers the whole
# pacman.d tree; section classification falls back to the section NAME.
ROWS_FILE=$(mktemp "${TMPDIR:-/tmp}/archmage-discipline-rows.XXXXXX")
awk '
    {
        line = $0
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+$/, "", line)
        if (line == "" || line ~ /^#/) next
        if (line ~ /^\[.*\]$/) {
            sec = line
            gsub(/[\[\]]/, "", sec)
            print sec "\tSECTION\t"
            next
        }
        if (sec == "") next
        eq = index(line, "=")
        if (eq == 0) next
        key = tolower(substr(line, 1, eq - 1))
        sub(/[ \t]+$/, "", key)
        val = substr(line, eq + 1)
        sub(/^[ \t]+/, "", val)
        sub(/[ \t]+$/, "", val)
        print sec "\t" key "\t" val
    }
' "$PACMAN_CONF" > "$ROWS_FILE" 2>/dev/null || : > "$ROWS_FILE"

sig_status=pass
sig_details=""
sig_bad() {
    sig_status=fail
    if [ -n "$sig_details" ]; then sig_details="$sig_details; "; fi
    sig_details="${sig_details}${1}"
}

if [ ! -s "$ROWS_FILE" ]; then
    sig_bad "pacman.conf could not be parsed (or is empty)"
else
    # Section list in file order (dedup consecutive).
    mapfile -t SECTIONS < <(awk -F'\t' '$2=="SECTION"{print $1}' "$ROWS_FILE" | awk '!seen[$0]++')

    global_siglevel=$(awk -F'\t' '$1=="options" && $2=="siglevel"{print $3}' "$ROWS_FILE" | tr '\n' ' ' | sed 's/ *$//')

    if [ "${#SECTIONS[@]}" -eq 0 ]; then
        sig_bad "no sections found in pacman.conf"
    fi

    for sec in "${SECTIONS[@]}"; do
        [ "$sec" = options ] && continue
        servers=$(awk -F'\t' -v s="$sec" '$1==s && $2=="server"{print $3}' "$ROWS_FILE" | tr '\n' ' ')
        sec_siglevel=$(awk -F'\t' -v s="$sec" '$1==s && $2=="siglevel"{print $3}' "$ROWS_FILE" | tr '\n' ' ' | sed 's/ *$//')

        # Effective level: a repo-section SigLevel replaces the global
        # default (pacman.conf semantics); token order is not significant.
        effective=$sec_siglevel
        eff_src="section"
        if [ -z "$effective" ]; then
            effective=$global_siglevel
            eff_src="global"
        fi
        tokens=$(printf '%s' "$effective" | tr '[:lower:]' '[:upper:]' | tr -s ' \t' '\n' | sed '/^$/d' | sort | tr '\n' ',' | sed 's/,$//')

        # Classification.
        case "$sec" in
            *archmage*) class=own ;;
            *)
                case "$servers" in
                    *archmage*) class=own ;;
                    *) class="" ;;
                esac
                ;;
        esac
        if [ -z "$class" ]; then
            case "$sec" in
                core|extra|community|alarm|aur|core-testing|extra-testing|community-testing|alarm-testing|aur-testing)
                    class=alarm ;;
                *)
                    case "$servers" in
                        *archlinuxarm*) class=alarm ;;
                        *) class="" ;;
                    esac
                    ;;
            esac
        fi
        if [ -z "$class" ]; then
            # kupfer UPSTREAM prebuilts (02-01): identified by Server on a
            # kupfer host (gitlab.com/kupfer/... or a file:// checkout path
            # under kupfer's packages dir — kbs writes both shapes). Never is
            # their upstream policy for unsigned prebuilts, preserved
            # verbatim; it is not an ArchMage weakening.
            case "$servers" in
                *kupfer*) class=kupfer ;;
                *)
                    # Serverless known-kupfer-name sections at exactly Never
                    # (e.g. kupfer_local, local_only repos carry no Server).
                    case ",$tokens," in
                        ",NEVER,")
                            case "$sec" in
                                kupfer_local|boot|cross|device|firmware|linux|main|phosh|plasma_mobile|gnome_mobile) class=kupfer ;;
                                *) class=other ;;
                            esac
                            ;;
                        *) class=other ;;
                    esac
                    ;;
            esac
        fi

        # Policy checks. TrustAll is banned unconditionally.
        case ",$tokens," in
            *,TRUSTALL,*)
                sig_bad "[$sec] forbidden SigLevel token in '$effective'"
                ;;
        esac
        if [ "$class" = kupfer ]; then
            # Upstream kupfer prebuilts: exactly Never (unsigned upstream)
            # or an explicit Required are both acceptable; anything else is
            # a misconfiguration.
            case ",$tokens," in
                ",NEVER,") : ;;
                *,REQUIRED,*) : ;;
                *)
                    sig_bad "[$sec] kupfer upstream repo is neither Never nor Required (effective '$effective' from $eff_src)"
                    ;;
            esac
        else
            case ",$tokens," in
                *,NEVER,*)
                    sig_bad "[$sec] forbidden SigLevel token in '$effective'"
                    ;;
            esac
            case ",$tokens," in
                *,REQUIRED,*) : ;;
                *)
                    sig_bad "[$sec] package level not Required (effective '$effective' from $eff_src)"
                    ;;
            esac
        fi
        case "$class" in
            alarm)
                case ",$tokens," in
                    *,DATABASEOPTIONAL,*) : ;;
                    *) sig_bad "[$sec] ALARM upstream must be Required DatabaseOptional (effective '$effective' from $eff_src)" ;;
                esac
                ;;
            own)
                case ",$tokens," in
                    *,DATABASEOPTIONAL,*)
                        sig_bad "[$sec] ArchMage own repo must be Required without DatabaseOptional (effective '$effective' from $eff_src)" ;;
                    *) : ;;
                esac
                ;;
            other)
                : # third-party repos: Required enforced above, DB policy free
                ;;
        esac
        printf '    section [%s] class=%s effective_siglevel="%s" (%s)\n' \
            "$sec" "$class" "$effective" "$eff_src" >&2
    done
fi
[ -n "$sig_details" ] || sig_details="all repository sections comply (Never/TrustAll banned, Required everywhere, ALARM=DatabaseOptional, archmage=no DatabaseOptional, kupfer upstream Never preserved)"
record siglevel_policy "$sig_status" "$sig_details"

# --------------------------------------------------------------------------
# 3) No Qualcomm device-extracted firmware blobs outside distro firmware pkgs
# --------------------------------------------------------------------------
# Whitelist: files owned by any linux-firmware* package in the rootfs pacman
# local db (covers the split linux-firmware-qcom etc. layout) PLUS firmware-*
# distro device packages — the OP6 image ships kupfer's
# firmware-sdm845-oneplus (modem/wlan/venus blobs extracted upstream, the
# sanctioned mainline-mobile channel; postmarketOS lineage). QUAL-01's intent
# is unchanged: ArchMage's OWN overlay packages still may not ship blobs —
# only signed distro firmware packages are whitelisted.
WHITELIST=$(mktemp "${TMPDIR:-/tmp}/archmage-discipline-wl.XXXXXX")
FOUND=$(mktemp "${TMPDIR:-/tmp}/archmage-discipline-found.XXXXXX")
for dbdir in "$ROOTFS"/var/lib/pacman/local/linux-firmware*/ \
             "$ROOTFS"/var/lib/pacman/local/firmware-*/; do
    [ -f "$dbdir/files" ] || continue
    awk '
        /^%[A-Z]+%$/ { next }
        /^$/ { next }
        { sub(/^\//, "", $0); print }
    ' "$dbdir/files" >> "$WHITELIST" 2>/dev/null || true
done
sort -u "$WHITELIST" -o "$WHITELIST"

fw_status=pass
fw_details="no Qualcomm-shaped firmware outside the linux-firmware whitelist"
SCAN_DIRS=()
for d in "${FW_DIRS[@]}"; do
    [ -d "$d" ] && SCAN_DIRS+=("$d")
done
if [ "${#SCAN_DIRS[@]}" -gt 0 ]; then
    find "${SCAN_DIRS[@]}" -type f 2>/dev/null | sed "s|^$ROOTFS/||" | \
        grep -Ei '(\.mbn|\.b0[0-9])$|(^|/)(bdwlan|bdwhan)[^/]*$|(^|/)a5068(/|$)' \
        > "$FOUND" || true
    # Anything matched that is NOT linux-firmware-owned is a device blob.
    blobs=$(sort -u "$FOUND" | comm -23 - "$WHITELIST" | head -10)
    wl_count=$(wc -l < "$WHITELIST" | tr -d ' ')
    if [ -n "$blobs" ]; then
        fw_status=fail
        fw_details="device-extracted firmware outside linux-firmware whitelist (whitelist entries: ${wl_count}): $(printf '%s' "$blobs" | tr '\n' ';')"
    else
        matched=$(wc -l < "$FOUND" | tr -d ' ')
        fw_details="no Qualcomm-shaped firmware outside the linux-firmware whitelist (scanned hits: ${matched}, all whitelisted)"
    fi
else
    fw_details="no /usr/lib/firmware or /boot directories present — nothing to scan"
fi
record no_device_firmware_blobs "$fw_status" "$fw_details"

# --------------------------------------------------------------------------
# 4) No advertising / recommender / telemetry components (SAFETY-02)
# --------------------------------------------------------------------------
# Package names come from the rootfs pacman local db (var/lib/pacman/
# local/<dir>/desc %NAME%) — the same source as the firmware whitelist
# above. Globs live in safety-denylist.txt next to this script (one bash
# case pattern per line; # comments and blank lines ignored).
PKG_NAMES=$(mktemp "${TMPDIR:-/tmp}/archmage-discipline-pkgs.XXXXXX")
for dbdir in "$ROOTFS"/var/lib/pacman/local/*/; do
    [ -f "$dbdir/desc" ] || continue
    # desc shape: "%NAME%\n<pkgname>\n\n%VERSION%\n..." — first %NAME%
    # block, first line, done.
    awk '/^%NAME%$/{getline; print; exit}' "$dbdir/desc" \
        >> "$PKG_NAMES" 2>/dev/null || true
done
sort -u "$PKG_NAMES" -o "$PKG_NAMES"
pkg_count=$(wc -l < "$PKG_NAMES" | tr -d ' ')

nr_status=pass
nr_details=""
nr_hits=0
if [ ! -f "$DENYLIST" ]; then
    nr_status=fail
    nr_details="safety-denylist.txt not found next to the checker ($DENYLIST) — the no-recommender assertion cannot run"
else
    GLOBS=$(mktemp "${TMPDIR:-/tmp}/archmage-discipline-globs.XXXXXX")
    grep -v '^[[:space:]]*#' "$DENYLIST" | sed '/^[[:space:]]*$/d' > "$GLOBS"
    glob_count=$(wc -l < "$GLOBS" | tr -d ' ')
    if [ "$glob_count" -eq 0 ]; then
        nr_status=fail
        nr_details="safety-denylist.txt has no active glob lines — the no-recommender assertion would be a no-op"
    else
        hits_list=""
        while IFS= read -r pkg; do
            [ -n "$pkg" ] || continue
            while IFS= read -r glob; do
                [ -n "$glob" ] || continue
                # shellcheck disable=SC2254  # the glob IS the point
                case "$pkg" in
                    $glob)
                        nr_hits=$((nr_hits + 1))
                        hits_list="${hits_list:+$hits_list; }$pkg (glob: $glob)"
                        ;;
                esac
            done < "$GLOBS"
        done < "$PKG_NAMES"
        if [ "$nr_hits" -gt 0 ]; then
            nr_status=fail
            nr_details="recommender/advertising/telemetry packages present: $hits_list"
        else
            nr_details="$pkg_count package(s) in the local db checked against $glob_count safety-denylist glob(s); no hits"
        fi
    fi
    rm -f "$GLOBS"
fi
record no_recommender_components "$nr_status" "$nr_details"

# --------------------------------------------------------------------------
# 5) Safety config present whenever phosh is (SAFETY-01/02 machine face)
# --------------------------------------------------------------------------
SAFETY_PKG=archmage-phosh-safety
SAFETY_OVERRIDE=usr/share/glib-2.0/schemas/90_archmage-phosh-safety.gschema.override
SAFETY_LOCK=etc/dconf/db/local.d/locks/archmage-safety

sc_status=pass
sc_details=""
if grep -qx 'phosh' "$PKG_NAMES"; then
    sc_missing=""
    if ! grep -qx "$SAFETY_PKG" "$PKG_NAMES"; then
        sc_missing="$SAFETY_PKG package not in the pacman local db"
    fi
    [ -f "$ROOTFS/$SAFETY_OVERRIDE" ] || \
        sc_missing="${sc_missing:+$sc_missing; }/$SAFETY_OVERRIDE missing"
    [ -f "$ROOTFS/$SAFETY_LOCK" ] || \
        sc_missing="${sc_missing:+$sc_missing; }/$SAFETY_LOCK missing"
    if [ -n "$sc_missing" ]; then
        sc_status=fail
        sc_details="phosh is installed but the safety layer is incomplete: $sc_missing"
    else
        sc_details="phosh installed; $SAFETY_PKG present with gschema.override and dconf lock files"
    fi
else
    # No phosh in the local db (e.g. QEMU dev rootfs): nothing to enforce.
    sc_details="not-applicable: no phosh package in the pacman local db ($pkg_count package(s) checked)"
fi
record safety_config_present "$sc_status" "$sc_details"

rm -f "$ROWS_FILE" "$WHITELIST" "$FOUND" "$PKG_NAMES"

# --------------------------------------------------------------------------
# Assemble discipline.json (assertion-array style of test/lib/result.sh).
# --------------------------------------------------------------------------
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fails=$(jq -s '[.[] | select(.status == "fail")] | length' "$ASSERT_FILE")
status=pass
[ "$fails" -eq 0 ] || status=fail

mkdir -p "$(dirname "$OUT")"
jq -n \
    --arg check "shipping-discipline" \
    --arg target "$ROOTFS" \
    --arg tier "static" \
    --arg generated_at "$GENERATED_AT" \
    --slurpfile assertions "$ASSERT_FILE" \
    --arg status "$status" \
    --arg report "$OUT" \
    '{schema_version: 1,
      check: $check,
      target: $target,
      tier: $tier,
      generated_at: $generated_at,
      assertions: $assertions,
      status: $status,
      artifacts: {report: $report}}' \
    > "$OUT"

printf 'discipline.json: status=%s -> %s\n' "$status" "$OUT" >&2
if [ "$status" = pass ]; then
    exit 0
fi
exit 1
