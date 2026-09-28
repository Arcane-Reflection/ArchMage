#!/usr/bin/env bash
# export-keyring.sh — 把本机 GNUPGHOME 里的 stable 签名公钥导出为
# archmage-keyring 包的输入(03-03 Task 3,UPDATE-03 的人工门禁物理落点)。
#
# 这一步属于人工签名仪式(docs/REPO-CHANNELS.md),在维护者宿主机上执行:
#
#     tools/repo/export-keyring.sh <STABLE_KEY_FPR>
#
# 做两件事:
#   1. gpg --export <fpr>  ->  overlay/core/archmage-keyring/archmage.gpg
#      (纯公钥导出;私钥永远只留在本机 GNUPGHOME,本脚本不读取、不
#      备份、不传输任何秘密钥材料)
#   2. 把指纹写入 overlay/core/archmage-keyring/archmage-trusted
#      (pacman-key --populate archmage 的信任输入,随 keyring 包分发)
#
# 产物落位后:删除 overlay/core/archmage-keyring/.ci-defer 并提交,CI 即
# 可把 keyring 包打进 staging(详见 docs/REPO-CHANNELS.md 的 keyring 自
# 更新路径)。仓库提交态在仪式前不含 archmage.gpg —— 这不是桩,是「密钥
# 不进自动化」的机械表达(.gitignore 同步锁定)。
#
# Usage:
#   tools/repo/export-keyring.sh <40-hex-fingerprint>
#
# Exit codes: 0 ok; 1 usage/validation failure; 2 HUMAN_GATE_REQUIRED (CI).

set -euo pipefail

# 密钥导出是仪式动作:CI 里同样拒绝(与 promote-staging 同一守卫语义)。
if [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI:-}" ]; then
    printf 'HUMAN_GATE: export-keyring.sh only runs on the maintainer host ceremony (docs/REPO-CHANNELS.md).\n' >&2
    exit 2
fi

FPR=${1:-}
if [ -z "$FPR" ] || ! printf '%s' "$FPR" | grep -Eq '^[0-9A-Fa-f]{40}$'; then
    printf 'Usage: %s <40-hex-fingerprint>\n' "$(basename "$0")" >&2
    printf '  the fingerprint of the stable signing key in the LOCAL GNUPGHOME\n' >&2
    exit 1
fi

export GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"
[ -d "$GNUPGHOME" ] || { printf 'ERROR: GNUPGHOME %s does not exist\n' "$GNUPGHOME" >&2; exit 1; }
gpg --batch --list-secret-keys "$FPR" >/dev/null 2>&1 ||
    { printf 'ERROR: no secret key for %s in %s — run the ceremony on the maintainer host that holds the stable key (docs/REPO-CHANNELS.md)\n' "$FPR" "$GNUPGHOME" >&2; exit 1; }

REPO_ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
KEYRING_DIR=$REPO_ROOT/overlay/core/archmage-keyring
mkdir -p "$KEYRING_DIR"

# 1) Public half only. --export never touches secret key material.
gpg --batch --export "$FPR" > "$KEYRING_DIR/archmage.gpg"
[ -s "$KEYRING_DIR/archmage.gpg" ] ||
    { printf 'ERROR: exported keyring is empty\n' >&2; exit 1; }

# 2) Trust input for pacman-key --populate archmage.
cat > "$KEYRING_DIR/archmage-trusted" <<EOF
# ArchMage stable channel signing key(s) — produced by tools/repo/export-keyring.sh
# during the offline key ceremony (docs/REPO-CHANNELS.md). pacman-key --populate
# archmage marks these fingerprints ultimately trusted.
$FPR
EOF

printf 'exported: %s (public half only)\n' "$KEYRING_DIR/archmage.gpg"
printf 'trusted:  %s -> %s\n' "$FPR" "$KEYRING_DIR/archmage-trusted"
printf 'next: remove %s/.ci-defer, commit, and let CI publish the keyring package (docs/REPO-CHANNELS.md §keyring 自更新)\n' "$KEYRING_DIR"
