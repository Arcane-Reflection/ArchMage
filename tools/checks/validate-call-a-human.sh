#!/usr/bin/env bash
# validate-call-a-human.sh — MAINT-02 validator (04-01 Task 3).
# Asserts tools/ai-rules/call-a-human.yaml is machine-readable AND exactly
# encodes the six STRATEGY §8 gates:
#   version == 1; gates a non-empty list; every gate carries
#   id/trigger/action/source; action ∈ {block, open_issue, require_human};
#   the id set is EXACTLY {stable_signing, key_ops, direction_change,
#   overlay_size, upstream_break, device_ops} (extra or missing gates are
#   rejected — the gate set is the §8 contract, not a suggestion).
#
# Usage: validate-call-a-human.sh [--file PATH]
#   --file feeds a fixture for the negative test (exit 1 expected on
#   tools/checks/fixtures/call-a-human-broken.yaml).
#
# Runtime: bash + python3 + PyYAML (preinstalled on GitHub ubuntu runners;
# in containers install python-yaml). No yq dependency (01-03 detector
# precedent: two-way validated before delivery).

set -euo pipefail

FILE="tools/ai-rules/call-a-human.yaml"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--file)
		FILE="$2"
		shift 2
		;;
	*)
		echo "usage: validate-call-a-human.sh [--file PATH]" >&2
		exit 2
		;;
	esac
done

[[ -f "$FILE" ]] || {
	echo "validator ERROR: $FILE not found" >&2
	exit 1
}

python3 - "$FILE" <<'PYEOF'
import sys

import yaml

path = sys.argv[1]
EXPECTED_GATES = {
    "stable_signing",
    "key_ops",
    "direction_change",
    "overlay_size",
    "upstream_break",
    "device_ops",
}
ALLOWED_ACTIONS = {"block", "open_issue", "require_human"}
REQUIRED_FIELDS = {"id", "trigger", "action", "source"}

with open(path) as f:
    doc = yaml.safe_load(f)

assert isinstance(doc, dict), "top level must be a mapping"
assert doc.get("version") == 1, f"version must be 1, got {doc.get('version')!r}"
gates = doc.get("gates")
assert isinstance(gates, list) and gates, "gates must be a non-empty list"

ids = set()
for gate in gates:
    assert isinstance(gate, dict), "each gate must be a mapping"
    missing = REQUIRED_FIELDS - set(gate)
    assert not missing, f"gate missing fields {missing}: {gate}"
    gid = gate["id"]
    assert isinstance(gid, str) and gid, f"gate id must be a non-empty string: {gid!r}"
    assert gid not in ids, f"duplicate gate id: {gid}"
    ids.add(gid)
    assert gate["action"] in ALLOWED_ACTIONS, (
        f"gate {gid}: action {gate['action']!r} not in {sorted(ALLOWED_ACTIONS)}")
    assert isinstance(gate["trigger"], str) and gate["trigger"].strip(), (
        f"gate {gid}: trigger must be a non-empty string")
    assert gate["source"] == "STRATEGY §8", (
        f"gate {gid}: source must be 'STRATEGY §8', got {gate['source']!r}")

extra = ids - EXPECTED_GATES
missing = EXPECTED_GATES - ids
assert not extra, f"unexpected gate(s): {sorted(extra)} (the §8 gate set is exact)"
assert not missing, f"missing gate(s): {sorted(missing)}"

print(f"validate OK: {path} — version 1, {len(gates)} gates, exact §8 set, "
      f"actions within {sorted(ALLOWED_ACTIONS)}")
PYEOF
