#!/usr/bin/env bash
# 00-unlock.sh — 解锁 bootloader(唯一不挂备份门的层;可回锁但有代价)。
#
# <reversibility rating="costly"> 解锁是 one-way 门之一:会清全部用户数据。
# 这一步由人在真机上走(设备侧音量键确认),agent 只交付脚本;真正的
# 执行发生在 02-03 的设备清单仪式。一次性后果由 --i-accept-data-wipe
# 显式旗标拦下(无旗标退 5)。
#
# 为什么不挂 require_backup 门(设计上的唯一例外,防死锁):
#   锁定的 bootloader 拒绝 `fastboot boot`,TWRP 备份物理上只能发生在
#   解锁之后 —— 若 00 也要求备份,首刷永远无法过门。替代闸:
#   ① --i-accept-data-wipe 显式旗标;② 解锁成功后立即执行
#   10-backup-persist.sh 的强指引(S6 场景锁定此顺序,防回归成死锁)。
#
# 用法:
#   bash flash/op6/00-unlock.sh [--backup-dir PATH] [--i-accept-data-wipe] [-h]
#
# 退出码:见 lib.sh 头部契约(无旗标 = 5;get_unlock_ability=0 = 1)。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ROOT=$(archmage_flash::backup_root_default)
ACCEPT_WIPE=no

usage() {
    cat <<'EOF'
00-unlock.sh — 解锁 OnePlus 6 bootloader(清数据,one-way 门)

用法:
  bash flash/op6/00-unlock.sh --i-accept-data-wipe [--backup-dir PATH] [-h|--help]

前置:设备在 fastboot/bootloader 模式(关机后按住 音量+ 与 音量− 接 USB);
     手机上先开启 开发者选项 → OEM 解锁(flashing get_unlock_ability 须为 1)。

后果(必须理解):
  - 解锁会清除全部用户数据(不可恢复,故需显式旗标);
  - persist/modemst 分区不受解锁动作影响,但备份必须解锁后经 TWRP 立即补上;
  - 之后可 `fastboot flashing lock` 回锁,但回锁有变砖风险(自行权衡)。

完成后的铁律下一步:
  fastboot boot twrp.img && bash flash/op6/10-backup-persist.sh
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --backup-dir)
            [ $# -ge 2 ] || archmage_flash::die 1 "--backup-dir 需要 PATH 参数"
            BACKUP_ROOT=$2
            shift
            ;;
        --i-accept-data-wipe)
            ACCEPT_WIPE=yes
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

# --- 设备门(先于一切输出,保住 33 路径的 stderr 首行) ---------------------
archmage_flash::require_device fastboot
SERIAL=$(archmage_flash::serial_fastboot)

# 本层不挂 require_backup(见头部说明)—— 这是物理顺序的唯一例外。

if [ "$ACCEPT_WIPE" != yes ]; then
    cat >&2 <<'EOF'
ERROR: 解锁 bootloader 会清除全部用户数据,需要显式确认旗标。
警告(中文,务必理解):
  1. 解锁 = 用户数据全清(照片/应用/设置,不可恢复);
  2. persist/modemst 不受解锁影响,但备份必须在解锁后立即经 TWRP 补上
     (fastboot boot twrp.img → 10-backup-persist.sh),否则后续任何 EDL
     都可能让 IMEI/相机校准不可恢复;
  3. 可回锁(fastboot flashing lock),但回锁有变砖风险。
修复: 确认后重跑: bash flash/op6/00-unlock.sh --i-accept-data-wipe
EOF
    exit 5
fi

ABILITY=$(fastboot flashing get_unlock_ability 2>&1 | awk '/\(bootloader\)/{print $2; exit}')
if [ "$ABILITY" != "1" ]; then
    archmage_flash::die 1 "flashing get_unlock_ability 返回 '%s'(须为 1)—— 手机上开启 设置 → 开发者选项 → OEM 解锁 后重跑" "${ABILITY:-<空>}"
fi

archmage_flash::info "设备 %s:get_unlock_ability=1,发起解锁(脚本只发送命令并等待;请在设备侧用音量键选择 UNLOCK 确认)" "$SERIAL"
fastboot flashing unlock

# --- 层状态留档(幂等:已记录则不重复追加) ---------------------------------
STATE_FILE=$(archmage_flash::state_file "$SERIAL" "$BACKUP_ROOT")
mkdir -p "$(dirname "$STATE_FILE")"
if ! grep -q '^00-unlock done' "$STATE_FILE" 2>/dev/null; then
    printf '00-unlock done unlock_ability=%s\n' "$ABILITY" >>"$STATE_FILE"
fi

printf '解锁完成(状态已留档: %s)。\n' "$STATE_FILE"
printf '下一步(铁律,立即执行):\n'
printf '  1. fastboot boot twrp.img\n'
printf '     # TWRP 获取: pmOS wiki oneplus-enchilada(Installation 页)\n'
printf '  2. bash flash/op6/10-backup-persist.sh\n'
printf '     # 五分区备份 persist/modemst1/modemst2/fsc/fsg —— 没有它,后面所有刷写都会被拒\n'
printf '  3. 备份完成后: bash flash/op6/flash-all.sh --yes\n'
