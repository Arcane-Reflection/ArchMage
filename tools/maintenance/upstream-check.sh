#!/usr/bin/env bash
# upstream-check.sh — single entry point for MAINT-01 upstream tracking
# (04-01). Runs INSIDE an archlinux:base container (the repo's proven
# docker-battery methodology), one command end to end:
#
#   docker run --rm -v "$PWD":/work -w /work \
#     -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY -e GITHUB_TOKEN \
#     archlinux:base bash tools/maintenance/upstream-check.sh
#
# What it does (in order):
#   1. installs nvchecker + pyalpm + curl from the official signed repos
#      (pyalpm is nvchecker's OPTIONAL dep and the `alpm` source's hard
#      requirement — without it the ALARM/x86_64-extra entries all error);
#   2. refreshes BOTH alpm dbpaths every run (stale db silently reports
#      old versions — RESEARCH Pitfalls; T-04-05):
#        tools/nvchecker/alarm-db  via tools/nvchecker/alarm-pacman.conf
#        tools/nvchecker/arch-db   via the container's own repo config
#      (db sync only — no packages are ever installed from these dbs);
#   3. generates the runtime keyfile from GITHUB_TOKEN (or an empty [keys]
#      table without one — all 15 sources are safe at 60/h anonymous);
#      the keyfile is deleted on exit and is gitignored (T-04-02);
#   4. runs `nvchecker --logger json` (check.jsonl) and `nvcmp --json`
#      (nvcmp.json). nvchecker's exit code is captured but NEVER used to
#      judge the run (obs-auto-trigger precedent: discovery-vs-failure
#      cannot be told apart from the exit code) — the JSONL content is;
#   5. synthesizes drift-report.md: per-entry old→new (or in-sync) plus
#      the 04-RESEARCH Q2 action class (rebase-PR / rebase-plan / issue)
#      and the db sync timestamps (T-04-05 human-review evidence);
#   6. hard-fails (exit 1) on INFRASTRUCTURE errors only: any entry
#      erroring, any entry missing from the results, or nvcmp.json not
#      being a JSON array. Discovering updates is success, not failure
#      ("工作流红只留给基础设施错误").
#
# Artifacts land in test/results/upstream/<ts>/ with a `latest` symlink
# (same convention as test/lib/result.sh; gitignored) — created even when
# the zero-error contract fails, so failures stay inspectable.
#
# `--check` mode: container-side environment self-check (tools present,
# config parses, baseline + pacman conf in place). Docker availability and
# image presence are proven by the docker run itself, not in-container.

set -euo pipefail

MODE="${1:-run}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# nvchecker's alpm source needs ABSOLUTE dbpaths (pyalpm Handle), pinned to
# the container mount point /work in tools/nvchecker.toml — enforce the
# documented execution surface rather than failing deep inside libalpm.
# (log/die are defined right below — keep any early failure readable)
log() { printf '[upstream-check] %s\n' "$*"; }
die() { printf '[upstream-check] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "$(pwd -P)" != "/work" ]]; then
	die "this script runs inside archlinux:base with the repo mounted at /work: docker run --rm -v \"\$PWD\":/work -w /work archlinux:base bash tools/maintenance/upstream-check.sh"
fi

TOML="tools/nvchecker.toml"
OLDVER="tools/nvchecker/oldver.txt"
NEWVER="tools/nvchecker/newver.txt"
KEYFILE="tools/nvchecker/keyfile"
ALARM_CONF="tools/nvchecker/alarm-pacman.conf"
ALARM_DB="tools/nvchecker/alarm-db"
ARCH_DB="tools/nvchecker/arch-db"
EXPECTED_ENTRIES=15

install_tools() {
	log "installing nvchecker + pyalpm + curl (official signed repos)"
	pacman -Sy --noconfirm --needed nvchecker pyalpm curl >/dev/null 2>&1 \
		|| pacman -Sy --noconfirm --needed nvchecker pyalpm curl \
		|| die "pacman install failed (mirror/proxy problem — infra error)"
	command -v nvchecker >/dev/null || die "nvchecker missing after install"
	command -v nvcmp >/dev/null || die "nvcmp missing after install"
	command -v nvtake >/dev/null || die "nvtake missing after install"
	command -v curl >/dev/null || die "curl missing after install"
	python3 -c 'import pyalpm' >/dev/null 2>&1 || die "pyalpm not importable (alpm source hard-requires it)"
}

self_check() {
	install_tools
	log "self-check: validating $TOML against $OLDVER"
	python3 - "$TOML" "$OLDVER" "$ALARM_CONF" "$EXPECTED_ENTRIES" <<'PYEOF'
import os
import sys
import tomllib

toml_path, oldver_path, alarm_conf, expected = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]))

with open(toml_path, "rb") as f:
    cfg = tomllib.load(f)
config_tables = [k for k in cfg if k.startswith("__config__")]
assert config_tables, "missing [__config__] table"
entries = [k for k in cfg if k not in config_tables]
assert len(entries) == expected, (
    f"expected {expected} entries, got {len(entries)}: {entries}")
for name, table in cfg.items():
    if name in config_tables:
        continue
    assert isinstance(table, dict) and "source" in table, (
        f"entry {name} lacks a source")
conf = cfg[config_tables[0]]
assert all(k in conf for k in ("oldver", "newver", "keyfile")), (
    "[__config__] must set oldver/newver/keyfile")
with open(oldver_path) as f:
    names = {line.split()[0] for line in f
             if line.strip() and not line.lstrip().startswith("#")}
assert len(names) == expected, (
    f"{oldver_path}: expected {expected} baseline names, got {len(names)}")
toml_names = set(entries)
assert toml_names == names, (
    f"toml/baseline name mismatch: only-toml={sorted(toml_names - names)} "
    f"only-oldver={sorted(names - toml_names)}")
assert os.path.isfile(alarm_conf), f"{alarm_conf} missing"
print(f"self-check OK: {len(entries)} entries, baseline aligned, "
      f"{alarm_conf} present")
PYEOF
	log "self-check passed"
}

ensure_dbpath() { # <dbpath> <pacman-conf-or-''> <label>
	local dbpath="$1" conf="$2" label="$3"
	mkdir -p "$dbpath"
	log "refreshing $label dbpath ($dbpath)"
	if [[ -n "$conf" ]]; then
		pacman -Sy --config "$conf" --dbpath "$dbpath" --noconfirm >/dev/null 2>&1 \
			|| pacman -Sy --config "$conf" --dbpath "$dbpath" --noconfirm \
			|| die "ALARM db sync failed (mirror unreachable? infra error)"
	else
		pacman -Sy --dbpath "$dbpath" --noconfirm >/dev/null 2>&1 \
			|| pacman -Sy --dbpath "$dbpath" --noconfirm \
			|| die "x86_64 extra db sync failed (mirror unreachable? infra error)"
	fi
	date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dbpath/.last-sync"
}

cleanup() {
	rm -f "$KEYFILE"
}
trap cleanup EXIT

write_keyfile() {
	# T-04-02: the keyfile exists only for the duration of the run,
	# never committed (gitignored), deleted on exit via the cleanup trap.
	if [[ -n "${GITHUB_TOKEN:-}" ]]; then
		printf '[keys]\ngithub = "%s"\n' "$GITHUB_TOKEN" > "$KEYFILE"
	else
		printf '[keys]\n' > "$KEYFILE"
	fi
}

run_check() {
	install_tools

	local ts out
	ts="$(date -u +%Y%m%dT%H%M%SZ)"
	out="test/results/upstream/$ts"
	mkdir -p "$out"

	ensure_dbpath "$ALARM_DB" "$ALARM_CONF" "ALARM aarch64"
	ensure_dbpath "$ARCH_DB" "" "x86_64 extra"
	local alarm_ts arch_ts
	alarm_ts="$(cat "$ALARM_DB/.last-sync")"
	arch_ts="$(cat "$ARCH_DB/.last-sync")"

	write_keyfile

	# Fresh check-result store: nvcmp compares the COMMITTED baseline
	# (oldver.txt) against this run's freshly checked versions.
	: > "$NEWVER"

	log "running nvchecker ($EXPECTED_ENTRIES sources; exit code captured, not judged)"
	local nvchecker_rc nvcmp_rc
	set +e
	nvchecker --logger json -c "$TOML" > "$out/check.jsonl" 2> "$out/nvchecker.stderr.log"
	nvchecker_rc=$?
	nvcmp -c "$TOML" --json > "$out/nvcmp.json" 2> "$out/nvcmp.stderr.log"
	nvcmp_rc=$?
	set -e
	log "raw exit codes: nvchecker=$nvchecker_rc nvcmp=$nvcmp_rc (content is authoritative)"

	set +e
	python3 - "$out" "$TOML" "$alarm_ts" "$arch_ts" <<'PYEOF'
import json
import os
import sys
import tomllib

out, toml_path, alarm_ts, arch_ts = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])

# 04-RESEARCH Q2 action column: what happens on drift for each entry.
ACTIONS = {
    "waydroid": "rebase-PR",
    "libglibutil": "rebase-PR",
    "libgbinder": "rebase-PR",
    "python-gbinder": "rebase-PR",
    "waydroid-upstream": "issue",
    "libgbinder-upstream": "issue",
    "libglibutil-upstream": "issue",
    "python-gbinder-upstream": "issue",
    "waydroid-alarm": "issue",
    "libglibutil-alarm": "issue",
    "libgbinder-alarm": "issue",
    "python-gbinder-alarm": "issue",
    "danctnix-release": "issue",
    "kupferbootstrap": "rebase-plan",
    "phosh-danctnix": "issue",
}

with open(toml_path, "rb") as f:
    entries = [k for k in tomllib.load(f) if not k.startswith("__config__")]

versions, errors = {}, {}
with open(os.path.join(out, "check.jsonl")) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        name = rec.get("name")
        if not name:
            continue
        if rec.get("version"):
            versions[name] = rec["version"]
        if rec.get("error"):
            errors.setdefault(name, rec["error"])

try:
    with open(os.path.join(out, "nvcmp.json")) as f:
        nvcmp = json.load(f)
except (json.JSONDecodeError, ValueError):
    # nvcmp crashed before emitting JSON — infra failure with evidence.
    err = (open(os.path.join(out, "nvcmp.stderr.log")).read()
           or "nvcmp produced no output and no stderr\n")
    with open(os.path.join(out, "drift-report.md"), "w") as f:
        f.write("# Upstream drift report\n\n"
                "## Errors (infrastructure — this run failed)\n\n"
                "nvcmp.json is missing or not valid JSON:\n\n```\n"
                + err + "\n```\n")
    print(err, file=sys.stderr)
    sys.exit(1)
assert isinstance(nvcmp, list), "nvcmp.json is not a JSON array"
drift = {d["name"]: d for d in nvcmp}

rows, drifted = [], []
for name in entries:
    action = ACTIONS[name]
    if name in errors:
        rows.append((name, "ERROR", errors[name], action, False))
        continue
    ver = versions.get(name)
    assert ver, f"entry {name} produced no version and no error — unexpected"
    if name in drift:
        if drift[name].get("delta") == "added":
            old = "(not in baseline)"
        else:
            old = drift[name].get("oldver") or drift[name].get("old_version") or ver
        rows.append((name, old, drift[name]["newver"], action, True))
        drifted.append(name)
    else:
        rows.append((name, ver, ver, action, False))

failed = [r for r in rows if r[1] == "ERROR"]
lines = []
lines.append("# Upstream drift report")
lines.append("")
lines.append("Generated by tools/maintenance/upstream-check.sh "
             "(nvchecker 2.x + nvcmp, archlinux:base container).")
lines.append(f"- ALARM aarch64 dbpath synced: {alarm_ts}")
lines.append(f"- x86_64 extra dbpath synced: {arch_ts}")
lines.append(f"- Entries checked: {len(entries)}; drifting: {len(drifted)}; "
             f"errors: {len(failed)}")
lines.append("- Action classes (04-RESEARCH Q2): rebase-PR = vendored chain "
             "re-vendor PR artifact; rebase-plan = kupferbootstrap fork "
             "rebase artifact; issue = deduped issue text. GitHub posting is "
             "CI-deferred (repo has no remote).")
lines.append("")
lines.append("| entry | baseline | new | drift | action |")
lines.append("|---|---|---|---|---|")
for name, old, new, action, is_drift in rows:
    if not is_drift:
        lines.append(f"| {name} | {old} | (in-sync) | – | {action} |")
    else:
        lines.append(f"| {name} | {old} | {new} | **{old} -> {new}** | {action} |")
lines.append("")
if drifted:
    lines.append("## Drift summary")
    lines.append("")
    for name in drifted:
        d = drift[name]
        lines.append(f"- **{name}**: {d.get('oldver')} -> {d['newver']} "
                     f"(action: {ACTIONS[name]})")
    lines.append("")
if failed:
    lines.append("## Errors (infrastructure — this run failed)")
    lines.append("")
    for name, _, err, _, _ in failed:
        lines.append(f"- **{name}**: {err}")
    lines.append("")

report = "\n".join(lines) + "\n"
with open(os.path.join(out, "drift-report.md"), "w") as f:
    f.write(report)
print(report)

if failed:
    sys.exit(1)  # infra/config error — workflow-red semantics, per plan
PYEOF
	synth_rc=$?
	set -e

	# Artifacts are always inspectable via latest/ (even on failure),
	# then the zero-error contract decides the exit code.
	ln -sfn "$ts" test/results/upstream/latest
	if [[ "$synth_rc" -ne 0 ]]; then
		die "zero-error contract violated — see test/results/upstream/latest/drift-report.md"
	fi
	log "done: test/results/upstream/latest/{check.jsonl,nvcmp.json,drift-report.md}"
}

case "$MODE" in
--check) self_check ;;
run) run_check ;;
*)
	die "usage: upstream-check.sh [--check]"
	;;
esac
