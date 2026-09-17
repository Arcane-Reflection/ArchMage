#!/usr/bin/env bash
# aarch64-gap.sh — daily aarch64 package gap report (BUILD-03, plan 01-03).
#
# Compares the linuxphoneOS flavour seed set against Arch x86_64 and ALARM
# aarch64 repo databases and reports:
#   missing[]   — seed packages that exist on x86_64 but are absent from
#                 every aarch64 source (plus seeds no source knows, which
#                 are ALSO listed in not_found[] — a wrong seed list must
#                 alert, never silently drop)
#   stale[]     — seed packages where the best aarch64 version is older
#                 than x86_64 (compared with vercmp), with an OPTIONAL
#                 age estimate when the x86_64 version embeds a date
#                 (2024.07.30 / 20240730 / 2024-07-30 forms)
#   alert       — missing > GAP_MISSING_LIMIT (default 0)
#                 or not_found > 0
#                 or stale entries whose estimated age exceeds
#                 GAP_STALE_DAYS (default 14)
#                 => ::warning:: annotations AND a non-zero exit so the
#                 gap-report workflow turns visibly red.
#
# Repo DB naming: mirrors publish the pacman>=6 canonical extensionless
# `<repo>.db` (the bytes are gzip) plus the legacy `<repo>.db.tar.gz`;
# the literal `<repo>.db.tar.zst` does not exist on TUNA — both real
# names are tried in that order (verified 2026-09-17).
#
# Usage:
#   tools/reports/aarch64-gap.sh --out DIR [--seed FILE] [--repos ARCH=URL ...]
#
# Environment:
#   DANCTNIX_DB_URL   optional extra aarch64 repo DB URL (third source for
#                     the mobile stack, e.g. the danctnix repo)
#   GAP_MISSING_LIMIT alert threshold for missing[], default 0
#   GAP_STALE_DAYS    alert threshold (days) for date-estimable stale
#                     entries, default 14
#
# DBs are pure data: downloaded over https, parsed with bsdtar/awk only,
# nothing is executed from them (T-01-12). Outputs under --out DIR:
# gap-report.json, gap-report.md, cache/.

set -euo pipefail

usage() {
    cat <<'EOF'
aarch64-gap.sh — aarch64 vs x86_64 package gap report for the flavour seed set

Usage:
  tools/reports/aarch64-gap.sh --out DIR [--seed FILE] [--repos ARCH=URL ...]

Options:
  --out DIR         Output directory (gap-report.json, gap-report.md, cache/).
  --seed FILE       Seed package list, one name per line, '#' comments
                    (default: flavour-package-set.txt next to this script).
  --repos ARCH=URL  Repo DB URL with its arch, repeatable. Defaults (TUNA):
                    x86_64 Arch core/extra + aarch64 ALARM core/extra.
  -h, --help        Show this help.

Environment:
  DANCTNIX_DB_URL   extra aarch64 repo DB URL appended to the source set.
  GAP_MISSING_LIMIT missing[] alert threshold (default 0).
  GAP_STALE_DAYS    stale-overdue age threshold in days (default 14;
                    only stale entries whose x86_64 version carries a
                    parseable date can be age-estimated).

Exit status: 0 report produced, within thresholds; 1 report produced,
thresholds exceeded (visible alert); other non-zero on infrastructure
failure (download/parse).
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}
info() {
    printf '==> %s\n' "$*" >&2
}

OUT=""
SEED=""
REPO_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            [ $# -ge 2 ] || die "--out needs a DIR argument"
            OUT=$2
            shift
            ;;
        --seed)
            [ $# -ge 2 ] || die "--seed needs a FILE argument"
            SEED=$2
            shift
            ;;
        --repos)
            [ $# -ge 2 ] || die "--repos needs an ARCH=URL argument"
            REPO_ARGS+=("$2")
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
[ -n "$OUT" ] || { usage >&2; die "--out is required"; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -z "$SEED" ]; then
    SEED=$SCRIPT_DIR/flavour-package-set.txt
fi
[ -f "$SEED" ] || die "seed file '$SEED' not found"

for c in curl bsdtar jq vercmp awk find sort comm date md5sum; do
    command -v "$c" >/dev/null 2>&1 || \
        die "required tool '$c' not found in PATH (Arch: pacman -S <pkg>; Ubuntu/CI: apt install pacman libarchive-tools jq) — install it and re-run."
done

GAP_MISSING_LIMIT=${GAP_MISSING_LIMIT:-0}
GAP_STALE_DAYS=${GAP_STALE_DAYS:-14}

mkdir -p "$OUT/cache"

# --- source set ------------------------------------------------------------
# Each source: "<arch>|<url>". Defaults per plan; DANCTNIX_DB_URL appends.
SOURCES=(
    "x86_64|https://mirrors.tuna.tsinghua.edu.cn/archlinux/core/os/x86_64/core.db"
    "x86_64|https://mirrors.tuna.tsinghua.edu.cn/archlinux/extra/os/x86_64/extra.db"
    "aarch64|https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/aarch64/core/core.db"
    "aarch64|https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/aarch64/extra/extra.db"
)
for extra in "${REPO_ARGS[@]}"; do
    case "$extra" in
        *=*) SOURCES+=("${extra%%=*}|${extra#*=}") ;;
        *) die "--repos expects ARCH=URL, got '$extra'" ;;
    esac
done
if [ -n "${DANCTNIX_DB_URL:-}" ]; then
    SOURCES+=("aarch64|${DANCTNIX_DB_URL}")
fi

# --- download (with cache) + parse into per-source indexes -----------------
# Index format: lines of "name<TAB>version". Duplicate names within one
# source keep the highest version (vercmp).
download_db() {
    # download_db <url> <cache-file>
    local url="$1" cache="$2" base
    base=${url%/*}
    if [ -s "$cache" ] && [ -z "$(find "$cache" -mmin +720 2>/dev/null)" ]; then
        info "cache hit: $(basename "$cache")"
        return 0
    fi
    info "downloading $url"
    if ! curl --fail --location --retry 3 --silent --show-error --max-time 300 \
             --output "$cache" "$url"; then
        rm -f "$cache"
        # Legacy name fallback (mirrors keep both spellings).
        case "$url" in
            *.db)
                legacy="${base}/$(basename "$url").tar.gz"
                ;;
            *)
                legacy=""
                ;;
        esac
        if [ -n "$legacy" ]; then
            info "primary name failed, trying legacy $legacy"
            curl --fail --location --retry 3 --silent --show-error --max-time 300 \
                 --output "$cache" "$legacy" || { rm -f "$cache"; return 1; }
        else
            return 1
        fi
    fi
    return 0
}

index_source() {
    # index_source <db-file>  -> emits "name<TAB>version" (best per name)
    local db="$1" tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/lpos-gap.XXXXXX")
    if ! bsdtar -xf "$db" -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"
        return 1
    fi
    # desc blocks carry %NAME% and %VERSION%; DB entry dirs are
    # <name>-<version>, so the FIELDS are authoritative. FNR==1 flushes the
    # previous file (POSIX awk: no ENDFILE).
    find "$tmp" -name desc -type f -print0 \
      | xargs -0 -r awk '
            FNR == 1 { if (n != "") print n "\t" v; n = ""; v = "" }
            /^%NAME%$/    { getline; n = $0 }
            /^%VERSION%$/ { getline; v = $0 }
            END { if (n != "") print n "\t" v }
        ' | sort -u
    rm -rf "$tmp"
}

best_version() {
    # best_version <existing> <candidate> — echoes the winner via vercmp
    if vercmp "$2" "$1" >/dev/null 2>&1 && [ "$(vercmp "$2" "$1")" -gt 0 ]; then
        printf '%s' "$2"
    else
        printf '%s' "$1"
    fi
}

declare -A XVER
declare -A AVER
SOURCE_META=()
for src in "${SOURCES[@]}"; do
    arch=${src%%|*}
    url=${src#*|}
    name=$(basename "$url")
    # Cache key must be unique per SOURCE, not per basename: Arch x86_64
    # core.db and ALARM aarch64 core.db would otherwise collide and the
    # aarch64 index would silently reuse x86_64 bytes (caught during the
    # 2026-09-17 live verification run).
    cache="$OUT/cache/${arch}-${name}-$(printf '%s' "$url" | md5sum | cut -c1-8)"
    if ! download_db "$url" "$cache"; then
        die "could not download repo DB: $url"
    fi
    idx=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-idx.XXXXXX")
    if ! index_source "$cache" > "$idx"; then
        rm -f "$idx"
        die "could not parse repo DB: $url"
    fi
    count=$(wc -l < "$idx" | tr -d ' ')
    info "indexed $name ($arch): $count packages"
    SOURCE_META+=("$(printf '%s|%s|%s' "$name" "$arch" "$url")")
    while IFS=$'\t' read -r pkg ver; do
        [ -n "$pkg" ] || continue
        case "$arch" in
            x86_64)
                if [ -n "${XVER[$pkg]:-}" ]; then XVER[$pkg]=$(best_version "${XVER[$pkg]}" "$ver"); else XVER[$pkg]=$ver; fi
                ;;
            aarch64)
                if [ -n "${AVER[$pkg]:-}" ]; then AVER[$pkg]=$(best_version "${AVER[$pkg]}" "$ver"); else AVER[$pkg]=$ver; fi
                ;;
        esac
    done < "$idx"
    rm -f "$idx"
done

# --- classify the seed set ---------------------------------------------------
mapfile -t SEEDS < <(grep -vE '^[[:space:]]*(#|$)' "$SEED" | sed 's/[[:space:]]*$//' | awk '!seen[$0]++')
[ "${#SEEDS[@]}" -gt 0 ] || die "seed file '$SEED' contains no package names"

MISSING_FILE=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-missing.XXXXXX")
NOTFOUND_FILE=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-notfound.XXXXXX")
STALE_FILE=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-stale.XXXXXX")
trap 'rm -f "$MISSING_FILE" "$NOTFOUND_FILE" "$STALE_FILE"' EXIT

# estimate_age_days <version> — "" when no parseable date; else days old.
estimate_age_days() {
    local v="$1" m y mo d then now
    m=$(printf '%s' "$v" | grep -oE '20[0-9]{2}[.-][0-9]{1,2}[.-][0-9]{1,2}|20[0-9]{6}' | head -1)
    [ -n "$m" ] || return 0
    case "$m" in
        20[0-9][0-9][0-9][0-9][0-9][0-9])
            y=${m:0:4}; mo=${m:4:2}; d=${m:6:2}
            ;;
        *)
            rest=${m//[.-]/ }
            read -r y mo d <<<"$rest"
            ;;
    esac
    mo=$(printf '%02d' "$((10#$mo))")
    d=$(printf '%02d' "$((10#$d))")
    then=$(date -d "$y-$mo-$d" +%s 2>/dev/null) || return 0
    now=$(date +%s)
    printf '%s' "$(( (now - then) / 86400 ))"
}

for pkg in "${SEEDS[@]}"; do
    xv=${XVER[$pkg]:-}
    av=${AVER[$pkg]:-}
    if [ -z "$xv" ] && [ -z "$av" ]; then
        # Wrong seed: alert, never skip silently.
        printf '%s\n' "$pkg" >> "$NOTFOUND_FILE"
        printf '%s\t%s\n' "$pkg" "not_found_in_any_source" >> "$MISSING_FILE"
        continue
    fi
    if [ -n "$xv" ] && [ -z "$av" ]; then
        printf '%s\t%s\n' "$pkg" "x86_64_only" >> "$MISSING_FILE"
        continue
    fi
    if [ -n "$xv" ] && [ -n "$av" ]; then
        if [ "$(vercmp "$xv" "$av")" -gt 0 ]; then
            age=$(estimate_age_days "$xv")
            [ -n "$age" ] || age=""
            printf '%s\t%s\t%s\t%s\n' "$pkg" "$xv" "$av" "${age:-NA}" >> "$STALE_FILE"
        fi
    fi
    # present on aarch64 only (or equal): healthy direction, nothing to report
done

missing_count=$(wc -l < "$MISSING_FILE" | tr -d ' ')
notfound_count=$(wc -l < "$NOTFOUND_FILE" | tr -d ' ')
stale_count=$(wc -l < "$STALE_FILE" | tr -d ' ')

# --- thresholds --------------------------------------------------------------
stale_overdue=0
if [ "$stale_count" -gt 0 ]; then
    while IFS=$'\t' read -r _ _ _ age; do
        if [ "$age" != NA ] && [ "$age" -gt "$GAP_STALE_DAYS" ]; then
            stale_overdue=$((stale_overdue + 1))
        fi
    done < "$STALE_FILE"
fi

reasons=()
alert=no
if [ "$missing_count" -gt "$GAP_MISSING_LIMIT" ]; then
    alert=yes
    reasons+=("missing=${missing_count} exceeds GAP_MISSING_LIMIT=${GAP_MISSING_LIMIT}")
fi
if [ "$notfound_count" -gt 0 ]; then
    alert=yes
    reasons+=("not_found=${notfound_count} (seed list references packages no source carries)")
fi
if [ "$stale_overdue" -gt 0 ]; then
    alert=yes
    reasons+=("stale overdue (age > GAP_STALE_DAYS=${GAP_STALE_DAYS}): ${stale_overdue}")
fi

# --- reports ------------------------------------------------------------------
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# JSONL fragments -> arrays.
missing_json=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-mj.XXXXXX")
if [ "$missing_count" -gt 0 ]; then
    while IFS=$'\t' read -r pkg reason; do
        jq -cn --arg n "$pkg" --arg r "$reason" '{name: $n, reason: $r}' >> "$missing_json"
    done < "$MISSING_FILE"
fi
notfound_json=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-nj.XXXXXX")
if [ "$notfound_count" -gt 0 ]; then
    while read -r pkg; do
        jq -cn --arg n "$pkg" '{name: $n}' >> "$notfound_json"
    done < "$NOTFOUND_FILE"
fi
stale_json=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-sj.XXXXXX")
if [ "$stale_count" -gt 0 ]; then
    while IFS=$'\t' read -r pkg xv av age; do
        if [ "$age" = NA ]; then agejson=null; else agejson=$age; fi
        jq -cn --arg n "$pkg" --arg x "$xv" --arg a "$av" --argjson age "$agejson" \
            '{name: $n, x86_64_version: $x, aarch64_version: $a, age_estimate_days: $age}' >> "$stale_json"
    done < "$STALE_FILE"
fi
sources_json=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-srcj.XXXXXX")
for m in "${SOURCE_META[@]}"; do
    IFS='|' read -r nm arch url <<<"$m"
    jq -cn --arg n "$nm" --arg a "$arch" --arg u "$url" '{name: $n, arch: $a, url: $u}' >> "$sources_json"
done
reasons_json=$(mktemp "${TMPDIR:-/tmp}/lpos-gap-rj.XXXXXX")
for r in ${reasons[@]+"${reasons[@]}"}; do
    jq -cn --arg r "$r" '$r' >> "$reasons_json"
done

jq -n \
    --arg generated_at "$GENERATED_AT" \
    --arg seed "$SEED" \
    --argjson missing_limit "$GAP_MISSING_LIMIT" \
    --argjson stale_days "$GAP_STALE_DAYS" \
    --slurpfile sources "$sources_json" \
    --slurpfile missing "$missing_json" \
    --slurpfile not_found "$notfound_json" \
    --slurpfile stale "$stale_json" \
    --slurpfile reasons "$reasons_json" \
    --argjson alert "$([ "$alert" = yes ] && echo true || echo false)" \
    '{schema_version: 1,
      generated_at: $generated_at,
      seed: $seed,
      sources: $sources,
      missing: $missing,
      not_found: $not_found,
      stale: $stale,
      alert: {triggered: $alert,
              missing_count: ($missing | length),
              missing_limit: $missing_limit,
              not_found_count: ($not_found | length),
              stale_count: ($stale | length),
              stale_overdue_count: ([$stale[] | select(.age_estimate_days != null and .age_estimate_days > $stale_days)] | length),
              stale_days_limit: $stale_days,
              reasons: $reasons}}' \
    > "$OUT/gap-report.json"

# Human-readable markdown.
{
    printf '# aarch64 gap report\n\n'
    printf 'Generated: %s\n\n' "$GENERATED_AT"
    printf 'Seed: `%s`\n\n' "$SEED"
    printf '## Sources\n\n'
    printf '| repo | arch | url |\n|---|---|---|\n'
    for m in "${SOURCE_META[@]}"; do
        IFS='|' read -r nm arch url <<<"$m"
        printf '| %s | %s | %s |\n' "$nm" "$arch" "$url"
    done
    printf '\n## missing (%d, limit %d)\n\n' "$missing_count" "$GAP_MISSING_LIMIT"
    if [ "$missing_count" -gt 0 ]; then
        printf '| package | reason |\n|---|---|\n'
        while IFS=$'\t' read -r pkg reason; do
            printf '| %s | %s |\n' "$pkg" "$reason"
        done < "$MISSING_FILE"
    else
        printf 'None — every seed package is available on aarch64.\n'
    fi
    printf '\n## not_found (%d)\n\n' "$notfound_count"
    if [ "$notfound_count" -gt 0 ]; then
        printf 'Seed entries no source carries (seed-list errors — must alert, never skip):\n\n'
        while read -r pkg; do
            printf -- '- %s\n' "$pkg"
        done < "$NOTFOUND_FILE"
    else
        printf 'None — the seed list is consistent with the sources.\n'
    fi
    printf '\n## stale (%d, overdue threshold %d days)\n\n' "$stale_count" "$GAP_STALE_DAYS"
    if [ "$stale_count" -gt 0 ]; then
        printf '| package | x86_64 | aarch64 | est. days behind |\n|---|---|---|---|\n'
        while IFS=$'\t' read -r pkg xv av age; do
            printf '| %s | %s | %s | %s |\n' "$pkg" "$xv" "$av" "${age:-—}"
        done < "$STALE_FILE"
    else
        printf 'None — aarch64 is at parity for every seed package.\n'
    fi
    printf '\n## alert\n\n'
    if [ "$alert" = yes ]; then
        printf '**TRIGGERED**\n\n'
        for r in ${reasons[@]+"${reasons[@]}"}; do printf -- '- %s\n' "$r"; done
    else
        printf 'OK — within thresholds.\n'
    fi
} > "$OUT/gap-report.md"

rm -f "$missing_json" "$notfound_json" "$stale_json" "$sources_json" "$reasons_json"

info "reports: $OUT/gap-report.json $OUT/gap-report.md"
info "missing=$missing_count (limit $GAP_MISSING_LIMIT) not_found=$notfound_count stale=$stale_count (overdue > ${GAP_STALE_DAYS}d: $stale_overdue)"

if [ "$alert" = yes ]; then
    # Visible annotation for the Actions UI on top of the red workflow.
    joined=$(printf '%s; ' ${reasons[@]+"${reasons[@]}"} | sed 's/; $//')
    printf '::warning::aarch64 gap alert: %s\n' "$joined"
    printf '::warning::full report: gap-report.json / gap-report.md artifacts\n'
    exit 1
fi
exit 0
