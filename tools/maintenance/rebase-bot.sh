#!/usr/bin/env bash
# rebase-bot.sh — MAINT-01 drift triage (04-01 Task 2). Consumes the
# artifacts of upstream-check.sh (nvcmp.json) and takes the 04-RESEARCH
# Q2/Q3 actions. Runs INSIDE an archlinux:base container (same battery as
# upstream-check.sh):
#
#   docker run --rm -v "$PWD":/work -w /work \
#     -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY -e GITHUB_TOKEN \
#     archlinux:base bash tools/maintenance/rebase-bot.sh \
#       --results-dir test/results/upstream/latest [--weekly] \
#       [--existing-issues FILE] [--take]
#
# Three responsibilities (RESEARCH Q3), each with auditable artifacts:
#   1. vendored chain re-vendor PR artifacts (overlay/apps/{waydroid,
#      libglibutil,libgbinder,python-gbinder} — the ONLY legitimate PR
#      face, WINDOWS #33): per drifted package, a git WORKTREE (the
#      current checkout is never touched) on branch re-vendor/<pkg>-<new>,
#      mechanical pkgver/pkgrel (+ tag-commit pin where the PKGBUILD pins
#      one) edit, updpkgsums, clean-room makepkg build proof (packages.yml
#      battery: unprivileged builder user, deps pre-resolved leaf-first),
#      DIVERGENCE.md base-row sync, git format-patch bundle + PR body
#      text. Artifacts land under <results>/pr/. Actual GitHub PR creation
#      is CI-deferred (repo has no remote; merging stays a human gate —
#      STRATEGY §8).
#      kupferbootstrap drift (our fork target) gets a rebase-plan
#      artifact instead: tag old→new, diffstat between the tags, PR body
#      text — the fork repo is out of automation's reach here
#      (CI-deferred/user face, honestly classified).
#   2. non-fork dependency drift → issue TEXT ONLY (locez issue-not-PR
#      mode), title prefix `[nvchecker] <pkg>: old -> new`;
#      --existing-issues (a file of existing issue titles, fed by
#      `gh issue list` in CI) switches matching output to an
#      update-not-create instruction (T-04-04 dedup).
#   3. (--weekly) drop/rename detection: upstream package listings
#      (Codeberg danctnix-packages tree + kupfer pkgbuilds tree via
#      git ls-tree, ALARM aarch64 db via pacman -Sl) diffed against
#      tools/nvchecker/expected-deps.txt → "meta 依赖断链" issue text.
#      NEVER auto-forks upstream to compensate (STRATEGY §4 生死线 — the
#      issue text states this verbatim).
#
# --take: after CONFIRMED processing only — nvtake --all writes the taken
# state to tools/nvchecker/newver.txt, which becomes the new oldver.txt
# baseline (the caller, i.e. the workflow, commits it). Local runs never
# --take, so re-running keeps reporting the same drift. --take-only runs
# just that baseline update (the workflow's post-processing face — the
# triage already ran earlier in the job).
#
# The bot writes ONLY test/results/upstream/, git branches named
# re-vendor/* and their worktrees, and (with --take) the two nvchecker
# state files. Stable signing, key management and upstream social contact
# are never touched (STRATEGY §8; machine-checked by
# tools/checks/assert-gate-boundary.sh + tools/ai-rules/call-a-human.yaml).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ "$(pwd -P)" != "/work" ]]; then
	die "this script runs inside archlinux:base with the repo mounted at /work (see header)"
fi


RESULTS="test/results/upstream/latest"
EXISTING_ISSUES=""
WEEKLY=0
TAKE=0
TAKE_ONLY=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--results-dir)
		RESULTS="$2"
		shift 2
		;;
	--existing-issues)
		EXISTING_ISSUES="$2"
		shift 2
		;;
	--weekly)
		WEEKLY=1
		shift
		;;
	--take)
		TAKE=1
		shift
		;;
	--take-only)
		# The workflow's post-processing face: run ONLY do_take (the
		# triage already ran earlier in the job). Same baseline semantics.
		TAKE=1
		TAKE_ONLY=1
		shift
		;;
	*)
		echo "usage: rebase-bot.sh [--results-dir DIR] [--existing-issues FILE] [--weekly] [--take] [--take-only]" >&2
		exit 2
		;;
	esac
done

log() { printf '[rebase-bot] %s\n' "$*"; }
die() { printf '[rebase-bot] ERROR: %s\n' "$*" >&2; exit 1; }

NVCHECKER_DIR="tools/nvchecker"
TOML="tools/nvchecker.toml"
ALARM_DB="$NVCHECKER_DIR/alarm-db"
ALARM_CONF="$NVCHECKER_DIR/alarm-pacman.conf"
EXPECTED_DEPS="$NVCHECKER_DIR/expected-deps.txt"

# Q2 vendored chain (rebase-PR face; leaf-first build order) and fork
# target (rebase-plan face); every other drifting entry is issue-only.
VENDORED_PKGS=(libglibutil libgbinder python-gbinder waydroid)
FORK_PKGS=(kupferbootstrap)

if [[ "$TAKE_ONLY" -eq 0 ]]; then
	for f in "$RESULTS/nvcmp.json" "$EXPECTED_DEPS"; do
		[[ -s "$f" ]] || die "missing $f — run upstream-check.sh first"
	done
fi
[[ -d "$ALARM_DB/sync" ]] || die "$ALARM_DB not synced — run upstream-check.sh first"

PR_DIR="$RESULTS/pr"
ISSUE_DIR="$RESULTS/issue"
WORKTREE_DIR="$PR_DIR/worktrees"
MIRROR_DIR="$RESULTS/upstream-mirrors"
mkdir -p "$PR_DIR" "$ISSUE_DIR" "$WORKTREE_DIR" "$MIRROR_DIR"

BOT_IDENTITY=(-c user.name="ArchMage rebase-bot" -c user.email="rebase-bot@archmage.local")

log "installing build/parse tooling (official signed repos)"
pacman -Sy --noconfirm --needed git pacman-contrib base-devel python nvchecker pyalpm >/dev/null 2>&1 \
	|| pacman -Sy --noconfirm --needed git pacman-contrib base-devel python nvchecker pyalpm \
	|| die "pacman install failed"

# The repo is bind-mounted from the host user while we run as container
# root — teach git (and any su-shelled subprocess) to trust it.
export GIT_CONFIG_GLOBAL=/tmp/rebase-bot.gitconfig
git config --global --add safe.directory '*'
# (throwaway container: the repo and the upstream mirror clones alternate
# between root and host-uid ownership depending on the repair step; the
# wildcard keeps git functional across that boundary and leaves the host
# untouched — GIT_CONFIG_GLOBAL points into the container's /tmp)

command -v git >/dev/null || die "git missing"
command -v python3 >/dev/null || die "python3 missing"
command -v nvtake >/dev/null || die "nvtake missing (install nvchecker)"
command -v updpkgsums >/dev/null || die "updpkgsums missing (install pacman-contrib)"

# ── helpers ────────────────────────────────────────────────────────────────

in_list() { # <needle> <array-name>
	local needle="$1" item
	shift
	for item in "$@"; do
		[[ "$item" == "$needle" ]] && return 0
	done
	return 1
}

is_vendored() { in_list "$1" "${VENDORED_PKGS[@]}"; }
is_fork() { in_list "$1" "${FORK_PKGS[@]}"; }

issue_title() { printf '[nvchecker] %s: %s -> %s' "$1" "$2" "$3"; }

title_exists() { # <pkg> — dedup by title prefix on the existing-issues file
	[[ -n "$EXISTING_ISSUES" && -f "$EXISTING_ISSUES" ]] || return 1
	grep -qF "$(printf '[nvchecker] %s: ' "$1")" "$EXISTING_ISSUES"
}

write_issue() { # <pkg> <old> <new> — issue text with locez dedup semantics
	local pkg="$1" old="$2" new="$3"
	local file="$ISSUE_DIR/$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9._-' '_').md"
	{
		printf '# Title: %s\n\n' "$(issue_title "$pkg" "$old" "$new")"
		if title_exists "$pkg"; then
			log "issue for $pkg: existing issue found — UPDATE, not create"
			printf '**Action: UPDATE the existing open issue** (dedup by title prefix `[nvchecker] %s: `) — do not create a new one.\n\n' "$pkg"
		else
			printf '**Action: CREATE a new issue** (no existing open issue carries this title prefix).\n\n'
		fi
		cat <<BODY
Upstream drift detected by \`tools/maintenance/upstream-check.sh\` (nvchecker).

- **Package**: \`$pkg\`
- **Version drift**: \`$old\` -> \`$new\`
- **Tracking entry**: \`tools/nvchecker.toml\` (04-RESEARCH Q2; action: issue)

## Suggested action

This is a NON-fork dependency: per STRATEGY §4 (一切非 CN 差异永远跟上游,
不 fork 出自己的版本) there is no in-repo diff to rebase — the honest
automated action is this issue, not a PR. Evaluate the bump (ABI/soname,
packaging changes) and let the official repos / vendored fallback line
absorb it. If an upstream drop or rename breaks an ArchMage meta
dependency, the weekly drop/rename check opens a separate "meta 依赖断链"
issue instead — upstream is **never** forked automatically to compensate
(STRATEGY §4 生死线).

_Generated by tools/maintenance/rebase-bot.sh (local artifact; GitHub
posting is CI-deferred — the repo has no remote yet)._
BODY
	} > "$file"
	log "issue text: $file"
}

commit_pin_for_tag() { # <git-url> <tag> → commit sha (data-only lookup)
	local url="$1" tag="$2" sha
	sha="$(git ls-remote "$url" "refs/tags/$tag^{}" 2>/dev/null | awk '{print $1}' | head -1)"
	[[ -n "$sha" ]] || sha="$(git ls-remote "$url" "refs/tags/$tag" 2>/dev/null | awk '{print $1}' | head -1)"
	printf '%s' "$sha"
}

edit_pkgbuild_version() { # <worktree-pkgdir> <oldver-full> <newver-without-rel>
	local dir="$1" oldfull="$2" newver="$3"
	local pkbuild="$dir/PKGBUILD" url sha
	sed -i -E "s/^(pkgver=).*/pkgver=$newver/" "$pkbuild"
	sed -i -E "s/^(pkgrel=).*/pkgrel=1/" "$pkbuild"
	# Git-pinned sources: move the #commit pin to the new tag's commit.
	# Data-only lookup via git ls-remote (T-04-01: upstream content is
	# parsed, never executed).
	url="$(grep -oE 'git\+https://[^"#]+' "$pkbuild" | head -1 | sed 's/^git+//')" || true
	if [[ -n "${url:-}" ]] && grep -q '^_commit=' "$pkbuild"; then
		sha="$(commit_pin_for_tag "$url" "$newver")"
		[[ -n "$sha" ]] || return 1
		sed -i -E "s/^(_commit=).*/_commit=\"$sha\" # tags\/$newver/" "$pkbuild"
	fi
	# Package-name-scoped base-row refresh in DIVERGENCE.md: only the
	# package's own table row(s) and the "Vendored"/"Base pkgver-pkgrel"
	# ledger cells move; historical prose stays for human review (the PR
	# body says so explicitly).
	local div="$dir/DIVERGENCE.md"
	if [[ -f "$div" ]]; then
		local oldbase="${oldfull%%-*}"
		local esc_new="$newver" esc_old
		esc_old="$(printf '%s' "$oldbase" | sed 's/\./\\./g')"
		sed -i "/^| $pkg /s/$esc_old/$esc_new/g" "$div"
		sed -i "s@^| Base pkgver-pkgrel | .*@| Base pkgver-pkgrel | \`$newver-1\` (rebase-bot re-vendor pass; previous base in git history) |@" "$div" || true
		sed -i "s@^| Vendored | .*@| Vendored | $(date -u +%F) (rebase-bot re-vendor pass) |@" "$div" || true
	fi
}

pkg_deps() { # <pkgdir> → space-separated depends+makedepends+checkdepends
	# makepkg (even --printsrcinfo) refuses root — run as builder.
	su -s /bin/bash builder -c "cd '$1' && makepkg --printsrcinfo" \
		| sed -n 's/^\s*\(depends\|makedepends\|checkdepends\)\s*=\s*//p' | tr '\n' ' '
}

build_worktree_pkg() { # <worktree-pkgdir> <log-file> → 0 on build success
	local dir="$1" logfile="$2"
	# Absolute, OUTSIDE the worktree: makepkg resolves SRCDEST/PKGDEST
	# relative to its own cwd, and the su subshell cwd is the package dir.
	local srcdest pkgdest
	srcdest="/work/${PR_DIR}/makepkg/src"
	pkgdest="/work/${PR_DIR}/makepkg/pkg"
	mkdir -p "$srcdest" "$pkgdest"
	# makepkg refuses to run as root (packages.yml battery) — ALL makepkg
	# invocations (printsrcinfo, updpkgsums, makepkg) run as the
	# unprivileged builder user; root pre-resolves the dependency set so
	# no --syncdeps root escalation is needed.
	id builder >/dev/null 2>&1 || useradd -m builder
	chown -R builder:builder "$dir" "$srcdest" "$pkgdest"
	local deps
	deps="$(pkg_deps "$dir")"
	log "installing build deps: ${deps:-none}"
	if [[ -n "${deps// /}" ]]; then
		# shellcheck disable=SC2086
		pacman -S --noconfirm --needed $deps >/dev/null 2>&1 \
			|| pacman -S --noconfirm --needed $deps \
			|| return 1
	fi
	sudo_run_as_builder() {
		local cmd="$1"
		su -s /bin/bash builder -c "cd '$dir' && export SRCDEST='$srcdest' PKGDEST='$pkgdest' HOME=/home/builder && $cmd"
	}
	log "updpkgsums ($(basename "$dir"))"
	sudo_run_as_builder "updpkgsums" >> "$logfile" 2>&1 || return 1
	log "makepkg ($(basename "$dir"))"
	# Deps were pre-installed by root above (makepkg -s would try pacman
	# as the builder user and fail); -f forces the rebuild.
	sudo_run_as_builder "makepkg -f --noconfirm" >> "$logfile" 2>&1 || return 1
	# Leaf-first: install the fresh package so later chain builds resolve
	# against it (packages.yml pattern).
	local pkgfile
	pkgfile="$(ls -t "$pkgdest" 2>/dev/null | grep -E "^$(basename "$dir")-[0-9][^-]*-" | head -1 || true)"
	pkgfile="${pkgfile:+$pkgdest/$pkgfile}"
	if [[ -n "$pkgfile" ]]; then
		pacman -U --noconfirm "$pkgfile" >/dev/null 2>&1 || true
		printf 'built: %s\n' "$pkgfile" >> "$logfile"
	fi
	return 0
}

re_vendor_pkg() { # <pkg> <old> <new(verbatim nvcmp newver, e.g. 1.6.3-1)>
	local pkg="$1" old="$2" new="$3"
	local newver="${new%%-*}" # pkgver without pkgrel
	local branch="re-vendor/$pkg-$new"
	local wt="$WORKTREE_DIR/$pkg"
	local outdir="$PR_DIR/re-vendor-$pkg-$new"
	log "re-vendor: $pkg $old -> $new (branch $branch)"

	# Idempotent re-run: the bot only ever resets branches it itself
	# created (exact re-vendor/<pkg>-<ver> name) — never foreign refs.
	if git show-ref --verify --quiet "refs/heads/$branch"; then
		git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
		git branch -D "$branch" >/dev/null 2>&1 || true
	fi
	git worktree add -b "$branch" "$wt" HEAD >/dev/null

	local logfile="$outdir.build.log"
	local pkgdir="$wt/overlay/apps/$pkg"
	mkdir -p "$outdir"
	if ! edit_pkgbuild_version "$pkgdir" "$old" "$newver"; then
		printf 're-vendor %s FAILED: could not resolve the tag commit pin for %s\n' "$pkg" "$newver" > "$outdir/FAILED.md"
		git worktree remove --force "$wt"
		return 1
	fi
	if ! build_worktree_pkg "$pkgdir" "$logfile"; then
		printf 're-vendor %s FAILED: updpkgsums/makepkg did not succeed (see %s)\nThe worktree was discarded; the %s branch is removed.\nNeeds-human: evaluate manually — never force this (STRATEGY §8).\n' "$pkg" "$logfile" "$branch" > "$outdir/FAILED.md"
		cp "$logfile" "$outdir/build.log"
		git worktree remove --force "$wt"
		git branch -D "$branch" >/dev/null 2>&1 || true
		log "re-vendor $pkg: BUILD FAILED — needs-human artifact written"
		return 1
	fi
	cp "$logfile" "$outdir/build.log"

	( # commit inside the worktree
		cd "$wt"
		git "${BOT_IDENTITY[@]}" add -A overlay/apps/"$pkg"
		git "${BOT_IDENTITY[@]}" commit -q -m "re-vendor: $pkg $old -> $new (nvchecker 04-01 rebase-bot)" || true
	)
	git format-patch -1 "$branch" --output-directory="$outdir" >/dev/null
	# The patch bundle + branch are the artifacts; the worktree checkout
	# is transient scaffolding.
	git worktree remove --force "$wt"
	git worktree prune
	# This run succeeded — drop stale needs-human notes from earlier runs
	# and the transient build-log location.
	rm -f "$outdir/FAILED.md" "$logfile"

	local prbody="$outdir/PR-BODY.md"
	{
		cat <<BODY
# re-vendor: $pkg $old -> $new

Mechanical re-vendor of the vendored \`overlay/apps/$pkg\` package to the
maintained packaging base \`$new\`, produced by \`tools/maintenance/rebase-bot.sh\`
(plan 04-01, MAINT-01; WINDOWS #33). Branch: \`$branch\` (local-only).

- **Provenance**: \`overlay/apps/$pkg/DIVERGENCE.md\` (base row synced in this
  branch; the vendored-chain discipline and any deltas remain on record there)
- **Mechanical edits**: \`pkgver\`/\`pkgrel\` (+ tag-commit pin where the
  PKGBUILD pins one), \`updpkgsums\`, DIVERGENCE.md base row. The vendor
  header comment block may still cite the old base version — human review
  fixes the prose; the build is the machine-checked part.
- **Build evidence**: clean-room \`makepkg -sf\` in archlinux:base as an
  unprivileged user (same battery as packages.yml) — see \`build.log\`
  next to this file. Exit status 0.
- **Merge gate**: HUMAN review, then CI (staging) — this artifact is
  PR-ready text, never auto-merged and never auto-posted (CI-deferred:
  the repo has no remote yet). Stable signing stays a separate human
  ceremony (STRATEGY §8).
BODY
	} > "$prbody"
	log "re-vendor $pkg: patch + PR body under $outdir"
}

rebase_plan_kupfer() { # <old> <new>
	local old="$1" new="$2"
	local outdir="$PR_DIR/rebase-plan-kupferbootstrap-$new"
	local bare="$MIRROR_DIR/kupferbootstrap.git"
	mkdir -p "$outdir"
	log "rebase-plan: kupferbootstrap $old -> $new"
	if [[ ! -d "$bare" ]]; then
		git clone --bare --quiet https://gitlab.com/kupfer/kupferbootstrap.git "$bare" \
			|| die "kupferbootstrap mirror clone failed"
	fi
	local diffstat
	diffstat="$(git -C "$bare" diff --stat "$old" "$new" | tail -1)" || diffstat="(tags $old/$new not fetchable — see raw log)"
	{
		cat <<BODY
# Rebase plan: kupferbootstrap $old -> $new

Upstream (gitlab.com/kupfer/kupferbootstrap) moved $old -> $new. We fork
kupferbootstrap (STRATEGY M0), so this is a legit REBASE surface — but the
fork repository itself is outside this repo's automation reach, so the
action is this plan, not an in-repo PR (CI-deferred / user face).

- **Upstream tags**: $old -> $new
- **Upstream diffstat** (git diff --stat between the tags): $diffstat
- **Suggested rebase steps**:
  1. update the fork's upstream remote and fetch $new
  2. \`git rebase $old\` the fork's patch-carrying branch
  3. resolve conflicts (check config format changes first — kbs configs
     in this repo pin the kupfer upstream segment verbatim, see
     docs/REPO-CHANNELS.md and 02-01 discipline notes)
  4. run the image build battery before proposing the fork update
- **Merge gate**: HUMAN — fork pushes are upstream social contact
  (STRATEGY §8: patches go out under a human name, never the bot's).

_Generated by tools/maintenance/rebase-bot.sh (local artifact)._
BODY
	} > "$outdir/PR-BODY.md"
	log "rebase-plan artifact: $outdir/PR-BODY.md"
}

weekly_drop_rename_check() {
	local broken_file="$ISSUE_DIR/meta-dependency-break.md"
	log "weekly drop/rename check (expected-deps vs upstream pools)"
	# Pool 1: Codeberg danctnix-packages package dirs (category/<pkg>).
	local danctnix="$MIRROR_DIR/danctnix-packages"
	if [[ ! -d "$danctnix/.git" ]]; then
		git clone --quiet --depth 1 https://codeberg.org/DanctNIX/danctnix-packages.git "$danctnix" \
			|| die "danctnix-packages mirror clone failed"
	fi
	# Pool 2: kupfer pkgbuilds tree (qbootctl and friends).
	local kupfer="$MIRROR_DIR/kupferbootstrap"
	if [[ ! -d "$kupfer/.git" ]]; then
		git clone --quiet --depth 1 https://gitlab.com/kupfer/kupferbootstrap.git "$kupfer" \
			|| die "kupferbootstrap mirror clone failed"
	fi
	# Pool 3: ALARM aarch64 db (already synced by upstream-check.sh).
	python3 - "$danctnix" "$kupfer" "$ALARM_DB" "$ALARM_CONF" "$EXPECTED_DEPS" "$broken_file" <<'PYEOF'
import os
import subprocess
import sys

danctnix, kupfer, alarm_db, alarm_conf, expected_path, out_path = sys.argv[1:7]

def git_ls_dirs(repo):
    """Package directories visible in the upstream tree (data only)."""
    out = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", "HEAD"],
                         capture_output=True, text=True, check=True).stdout
    names = set()
    for path in out.splitlines():
        if path.endswith("/PKGBUILD"):
            names.add(path.split("/")[-2])
    return names

danctnix_names = git_ls_dirs(danctnix)
kupfer_names = git_ls_dirs(kupfer)
alarm = subprocess.run(
    ["pacman", "-Sl", "--config", alarm_conf, "--dbpath", alarm_db],
    capture_output=True, text=True, check=True).stdout
alarm_names = {line.split()[1] for line in alarm.splitlines() if line.strip()}

expected = [line.strip() for line in open(expected_path)
            if line.strip() and not line.lstrip().startswith("#")]

pools = {"danctnix-packages": danctnix_names,
         "kupfer pkgbuilds": kupfer_names,
         "ALARM aarch64 db": alarm_names}
missing = [n for n in expected if not any(n in p for p in pools.values())]

lines = []
if missing:
    lines.append(f"# Title: [nvchecker] meta 依赖断链: {len(missing)} expected upstream package(s) missing\n")
    lines.append("**Action: CREATE or UPDATE the standing broken-link issue "
                 "(dedup by title prefix).**\n")
    lines.append("The weekly drop/rename check (rebase-bot.sh --weekly) diffed "
                 "`tools/nvchecker/expected-deps.txt` against the upstream "
                 "package pools and found names present in NONE of them:\n")
    for name in missing:
        lines.append(f"- `{name}` — missing from danctnix-packages tree, "
                     "kupfer pkgbuilds tree AND the ALARM aarch64 db")
    lines.append("")
    lines.append("## Why this matters")
    lines.append("")
    lines.append("A missing upstream name means an ArchMage meta/vendored "
                 "dependency chain is broken at the source: the vendored "
                 "copies under overlay/apps/ are the fallback line "
                 "(DIVERGENCE.md), and any bump now has to come from those "
                 "copies alone.")
    lines.append("")
    lines.append("**Upstream is NEVER forked automatically to compensate "
                 "(STRATEGY §4 生死线).** Remediation is a human decision: "
                 "pick up packaging, switch the dependency, or drop the "
                 "feature — all of them direction-level calls.")
    lines.append("")
    lines.append("Known-standing example at calibration (2026-10-03): "
                 "`dbus-python` is absent from ALARM aarch64 repos while the "
                 "rest of the waydroid dep chain is present — a real supply "
                 "gap for the device line, exactly the class this check "
                 "exists to surface.")
else:
    lines.append("# Title: [nvchecker] weekly drop/rename check: no breakage\n")
    lines.append("All expected-deps names resolved in at least one upstream "
                 "pool (danctnix-packages tree, kupfer pkgbuilds tree, ALARM "
                 "aarch64 db). No broken links this week.\n")
lines.append("\n_Generated by tools/maintenance/rebase-bot.sh --weekly "
             "(local artifact; GitHub posting is CI-deferred)._\n")

with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"[rebase-bot] weekly check: {len(missing)} missing of {len(expected)} expected")
PYEOF
	log "weekly check artifact: $broken_file"
}

do_take() {
	log "--take: nvtake --all, then promote newver.txt to the oldver.txt baseline"
	nvtake -c "$TOML" --all
	cp "$NVCHECKER_DIR/newver.txt" "$NVCHECKER_DIR/oldver.txt"
	: > "$NVCHECKER_DIR/newver.txt"
	log "baseline updated — the workflow commits tools/nvchecker/oldver.txt (human-confirmed processing only)"
}

# ── main ───────────────────────────────────────────────────────────────────

if [[ "$TAKE_ONLY" -eq 1 ]]; then
	do_take
	log "take-only run complete"
	exit 0
fi

# Drift list from nvcmp.json: name<TAB>old<TAB>new (nvcmp re-verifies
# against the baseline; "added" deltas carry oldver null).
mapfile -t DRIFTS < <(python3 - "$RESULTS/nvcmp.json" <<'PYEOF'
import json
import sys

for d in json.load(open(sys.argv[1])):
    old = d.get("oldver") or d.get("old_version") or "(not in baseline)"
    print(f"{d['name']}\t{old}\t{d['newver']}")
PYEOF
)

	log "drift entries from nvcmp.json: ${#DRIFTS[@]}"
	NEEDS_HUMAN=()
	for row in "${DRIFTS[@]}"; do
		IFS=$'\t' read -r pkg old new <<< "$row"
		if is_vendored "$pkg"; then
			# A failed mechanical re-vendor is a classified outcome
			# (needs-human artifact), not an infra error — the run
			# continues and stays exit-0; only hard failures die.
			re_vendor_pkg "$pkg" "$old" "$new" || NEEDS_HUMAN+=("$pkg")
		elif is_fork "$pkg"; then
			rebase_plan_kupfer "$old" "$new"
		else
			write_issue "$pkg" "$old" "$new"
		fi
	done

if [[ "$WEEKLY" -eq 1 ]]; then
	weekly_drop_rename_check
fi

if [[ "$TAKE" -eq 1 ]]; then
	do_take
fi

# Summary artifact: one audit entry per classified drift.
{
	printf '# rebase-bot run summary\n\n'
	printf -- '- results dir: %s\n' "$RESULTS"
	printf -- '- drifts classified: %s\n' "${#DRIFTS[@]}"
printf -- '- weekly drop/rename check: %s\n' "$([[ $WEEKLY -eq 1 ]] && echo run || echo skipped)"
printf -- '- take: %s\n' "$([[ $TAKE -eq 1 ]] && echo done || echo skipped)"
if [[ "${#NEEDS_HUMAN[@]}" -gt 0 ]]; then
	printf '\nNeeds-human (mechanical re-vendor failed; FAILED.md + build.log in pr/):\n'
	for pkg in "${NEEDS_HUMAN[@]}"; do
		printf -- '- %s\n' "$pkg"
	done
fi
	printf '\nActions per drift:\n\n'
	for row in "${DRIFTS[@]}"; do
		IFS=$'\t' read -r pkg old new <<< "$row"
		if is_vendored "$pkg"; then
			printf -- '- %s %s -> %s: rebase-PR artifact (pr/)\n' "$pkg" "$old" "$new"
		elif is_fork "$pkg"; then
			printf -- '- %s %s -> %s: rebase-plan artifact (pr/)\n' "$pkg" "$old" "$new"
		else
			printf -- '- %s %s -> %s: issue text (issue/)\n' "$pkg" "$old" "$new"
		fi
	done
} > "$RESULTS/bot-summary.md"
log "summary: $RESULTS/bot-summary.md"

exit 0
