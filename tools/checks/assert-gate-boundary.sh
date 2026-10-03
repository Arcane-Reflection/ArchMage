#!/usr/bin/env bash
# assert-gate-boundary.sh — MAINT-02 boundary assertion (04-01 Task 3).
# Statically asserts that NO GitHub workflow touches a BLOCK gate of
# tools/ai-rules/call-a-human.yaml: every token in
# tools/checks/block-gate-tokens.txt (one per line, #-comments and blanks
# ignored) is searched as a FIXED STRING across the scan objects; the first
# hit fails the assertion (exit 1).
#
# The token list and call-a-human.yaml's block-gate triggers correspond
# one-to-one in semantics and cross-reference each other in their headers
# (stable channel signing/publishing + repo signing-chain key operations;
# the image-signing automation-key face is deliberately out of scope — see
# the token file header).
#
# Usage: assert-gate-boundary.sh [--workflows-dir DIR-OR-FILE]
#   --workflows-dir accepts a DIRECTORY (default .github/workflows) or a
#   SINGLE FILE (treated as the only scan object — the negative-test path,
#   e.g. tools/checks/fixtures/rogue-workflow.yml must FAIL this scan).
#
# Runtime: bash + grep -F only (01-03 detector precedent: delivered only
# after positive AND negative two-way validation).

set -euo pipefail

TOKENS="tools/checks/block-gate-tokens.txt"
TARGET=".github/workflows"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--workflows-dir)
		TARGET="$2"
		shift 2
		;;
	*)
		echo "usage: assert-gate-boundary.sh [--workflows-dir DIR-OR-FILE]" >&2
		exit 2
		;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$TOKENS" ]] || TOKENS="$SCRIPT_DIR/$(basename "$TOKENS")"

[[ -e "$TARGET" ]] || {
	echo "boundary ERROR: scan target $TARGET does not exist" >&2
	exit 1
}

mapfile -t token_list < <(grep -v '^#' "$TOKENS" | grep .)
if [[ "${#token_list[@]}" -lt 4 ]]; then
	echo "boundary ERROR: token list must carry at least 4 tokens (got ${#token_list[@]})" >&2
	exit 1
fi

hits=0
for token in "${token_list[@]}"; do
	# Fixed-string scan of the token inside the scan objects. A single
	# file target is the only object; a directory target is recursive.
	if [[ -f "$TARGET" ]]; then
		if grep -qiF -- "$token" "$TARGET"; then
			echo "boundary VIOLATION: '$token' found in $TARGET" >&2
			hits=$((hits + 1))
		fi
	else
		if grep -rqiF -- "$token" "$TARGET"; then
			echo "boundary VIOLATION: '$token' found under $TARGET" >&2
			hits=$((hits + 1))
		fi
	fi
done

if [[ "$hits" -gt 0 ]]; then
	echo "boundary FAILED: $hits block-gate token(s) inside workflows —" \
		"see tools/ai-rules/call-a-human.yaml (these gates are human-only)" >&2
	exit 1
fi

echo "boundary OK: ${#token_list[@]} block-gate tokens, zero hits in $TARGET"
