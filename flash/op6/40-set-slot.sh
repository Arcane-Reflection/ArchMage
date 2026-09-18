#!/usr/bin/env bash
# 40-set-slot.sh — 收尾层:把非当前 slot 设为 active,重启观察启动。
#
# 结构:require_device fastboot → serial → require_backup(收尾层同样挂
# 备份门)→ set_active(参数 --slot a|b,默认自动取反当前 slot)→
# 打印"拔线观察启动日志"提示 → fastboot reboot → 层状态 done。
#
# 用法:
#   bash flash/op6/40-set-slot.sh [--backup-dir PATH] [--slot a|b] [-h]
# 退出码:见 lib.sh 头部契约。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ROOT=$(archmage_flash::backup_root_default)
SLOT_OPT=""

usage() {
    cat <<'EOF'
40-set-slot.sh — 把非当前 slot 设为 active 并重启(全链收尾)

用法:
  bash flash/op6/40-set-slot.sh [--backup-dir PATH] [--slot a|b] [-h|--help]

  --backup-dir PATH  备份归档根(默认 flash/op6/backups/)
  --slot a|b         显式目标 slot(默认:自动取反当前 slot)

前置:00-unlock 状态在档 + 五分区备份过 require_backup 拒刷门
     (20/30 层已把新系统写进两个 slot,本层只改引导目标)。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --backup-dir)
            [ $# -ge 2 ] || archmage_flash::die 1 "--backup-dir 需要 PATH 参数"
            BACKUP_ROOT=$2
            shift
            ;;
        --slot)
            [ $# -ge 2 ] || archmage_flash::die 1 "--slot 需要 a|b 参数"
            case "$2" in
                a|b) SLOT_OPT=$2 ;;
                *) archmage_flash::die 1 "--slot 只接受 a 或 b,得到 '$2'" ;;
            esac
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            archmage_flash::die 1 "未知参数: $1"
            ;;
    esac
    shift
done

# --- 设备门 + 备份门 ---------------------------------------------------------
archmage_flash::require_device fastboot
SERIAL=$(archmage_flash::serial_fastboot)
archmage_flash::require_backup "$SERIAL" "$BACKUP_ROOT"

CURRENT=$(fastboot getvar current-slot 2>&1 | awk '/\(bootloader\)/{print $2; exit}')
case "$CURRENT" in
    a|b) ;;
    *) archmage_flash::die 1 "无法读取 current-slot(得到 '%s')—— 设备是否还在 fastboot 模式?" "${CURRENT:-<空>}" ;;
esac

if [ -n "$SLOT_OPT" ]; then
    TARGET=$SLOT_OPT
else
    case "$CURRENT" in
        a) TARGET=b ;;
        b) TARGET=a ;;
    esac
fi

archmage_flash::info "当前 slot %s → set_active %s" "$CURRENT" "$TARGET"
fastboot set_active "$TARGET"

printf '提示:fastboot reboot 前请拔掉数据线、准备好观察首启日志(首屏/串口);\n'
printf '启动异常时:重进 fastboot(音量+ & 音量− + USB)用 --slot 切回另一 slot。\n'
fastboot reboot

# --- 层状态留档(幂等) -------------------------------------------------------
STATE_FILE=$(archmage_flash::state_file "$SERIAL" "$BACKUP_ROOT")
if ! grep -q '^40-set-slot done' "$STATE_FILE" 2>/dev/null; then
    printf '40-set-slot done active=%s\n' "$TARGET" >>"$STATE_FILE"
fi

printf '40 层完成:active slot = %s(层状态: %s)。\n' "$TARGET" "$STATE_FILE"
printf '全链完成。后续:首验清单(02-03)与 EDL 演练要求见 flash/op6/README.md。\n'
