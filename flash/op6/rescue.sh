#!/usr/bin/env bash
# rescue.sh — OnePlus 6 EDL(QDLoader 9008)救援指引 + 从备份恢复 persist。
#
# 何时需要(PITFALLS 3):dtbo 未 erase 即刷、A/B slot 混淆、或误碰引导链
# 分区导致 fastboot 都进不去时,唯一入口是 EDL 9008。本脚本:
#   1. 检测:lsusb 是否出现 Qualcomm 05c6:9008(QDLoader 9008);
#   2. 检测不到时给入口指引(关机 → 按住 Vol+ & Vol− → 插 USB,震动/
#      白灯即入),并强调必须插 USB 2.0 口(USB 3.x 会 Sahara
#      Communication Failed);
#   3. 给分步 EDL 指引:bkerler/edl 安装、firehose/rawprogram 获取出处、
#      按序列号找备份目录;
#   4. --serial <SN>:先经 lib.sh 的 require_backup 校验该序列号的
#      manifest(坏备份绝不进入恢复流程),通过后才打印从
#      backups/<serial>/persist.tar.gz 恢复 persist/modemst 的命令序列。
#
# 硬拒绝(设计边界,不是功能缺口):本脚本不提供任何把引导链/基带分区
# (xbl/xbl_config/modem/abl/tz 一类)写入设备的指引 —— 那正是硬砖的
# 来源(MSM DownloadTool 的 wiping 行为 + 错版 xbl = 主板级损坏),
# PITFALLS 3 列为最高危路径。EDL 恢复只动 persist/modemst/fsc/fsg 与
# 用户分区;引导链交给带签名校验的官方 MSM 流程,并由人按
# pmOS wiki oneplus-enchilada/Unbricking 与 XDA 的 OP6 救援帖逐字核对。
#
# --check:无真机的环境自检(CI 冒烟用):python3/lsusb 必备(缺失退 1 =
# 环境缺陷);edl 可选(缺失仅提示);不做任何设备探测,无 9008 设备
# 时退出 0(33/DEVICE_REQUIRED 约定保留给 require_device 类设备探测,
# 本子命令不触发)。
#
# 用法:
#   bash flash/op6/rescue.sh                     # 检测 + 通用 EDL 指引
#   bash flash/op6/rescue.sh --serial <SN> [--backup-dir PATH]
#                                               # 校验备份后给恢复命令序列
#   bash flash/op6/rescue.sh --check             # 环境自检(CI)
# 退出码:0 正常;1 环境缺陷;2 备份门(--serial 路径)。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ROOT=$(archmage_flash::backup_root_default)
SERIAL=""
CHECK_ONLY=no

usage() {
    cat <<'EOF'
rescue.sh — OnePlus 6 EDL 9008 救援指引(检测 + 分步 + 备份恢复)

用法:
  bash flash/op6/rescue.sh [选项]

选项:
  --serial <SN>      给出设备序列号:校验 backups/<SN> 备份(五分区
                     manifest)通过后,打印 persist/modemst 恢复命令序列
  --backup-dir PATH  备份归档根(默认 flash/op6/backups/)
  --check            仅环境自检(python3/lsusb 必备,edl 可选;不做设备
                     探测,无 9008 时退 0 —— CI 冒烟安全)
  -h, --help         本帮助

边界:本脚本不提供对引导链/基带分区(xbl/xbl_config/modem/abl/tz 一类)
的任何写入指引 —— PITFALLS 3 把它列为硬砖路径;那类恢复只能走带签名
校验的官方 MSM 流程并逐字核对 pmOS wiki / XDA 的 OP6 救援文档。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --serial)
            [ $# -ge 2 ] || archmage_flash::die 1 "--serial 需要 <SN> 参数"
            SERIAL=$2
            shift
            ;;
        --backup-dir)
            [ $# -ge 2 ] || archmage_flash::die 1 "--backup-dir 需要 PATH 参数"
            BACKUP_ROOT=$2
            shift
            ;;
        --check)
            CHECK_ONLY=yes
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

# ---------------------------------------------------------------- --check 子命令
if [ "$CHECK_ONLY" = yes ]; then
    fail=0
    for c in python3 lsusb; do
        if command -v "$c" >/dev/null 2>&1; then
            printf 'ok: %s 在 PATH\n' "$c"
        else
            printf 'ERROR: %s 不在 PATH(CI/救援环境必备 —— Arch: sudo pacman -S python usbutils)\n' "$c" >&2
            fail=1
        fi
    done
    if command -v edl >/dev/null 2>&1; then
        printf 'ok: edl 在 PATH(%s)\n' "$(command -v edl)"
    else
        printf '提示: edl 未安装(可选 —— 需要实际执行 EDL 时再装:pipx install edl;来源 github.com/bkerler/edl)\n'
    fi
    [ "$fail" -eq 0 ] || exit 1
    printf '环境自检通过(--check 不做设备探测,无 9008 属预期)。\n'
    exit 0
fi

# ---------------------------------------------------------------- 9008 检测
archmage_flash::require_cmd lsusb "安装 usbutils(Arch: sudo pacman -S usbutils;Debian/Ubuntu: sudo apt install usbutils)"

EDL_DETECTED=no
if lsusb 2>/dev/null | grep -qi '05c6:9008'; then
    EDL_DETECTED=yes
    printf '已进入 EDL:lsusb 检测到 Qualcomm QDLoader 9008(05c6:9008)。\n\n'
else
    printf '未检测到 9008 设备。进入 EDL 的入口操作:\n'
    printf '  1. 设备完全关机;\n'
    printf '  2. 同时按住 音量+ 与 音量−(不要松手),插入 USB 数据线;\n'
    printf '  3. 感到震动/看到白色指示灯即已进入 EDL(此时屏幕黑屏是正常的);\n'
    printf '  4. 在本机执行 lsusb 确认出现 "Qualcomm ... 9008"。\n\n'
    printf '重要:必须插 USB 2.0 口(或 USB 2.0 延长线/HUB)—— USB 3.x 口会\n'
    printf 'Sahara Communication Failed(PITFALLS 3 与社区一致结论)。\n\n'
fi

# ---------------------------------------------------------------- 分步指引
cat <<'EOF'
== EDL 救援分步指引(OnePlus 6 / enchilada)==

第 1 步 · 安装 bkerler/edl(来源标注:github.com/bkerler/edl):
    pipx install edl          # 或 pip install --user edl;python3 >= 3.8
    edl --help                # 能打印帮助即安装成功

第 2 步 · 找到该设备的备份目录(首刷前 10-backup-persist.sh 的产物):
    backups/<序列号>/persist.tar.gz + manifest.json
    (序列号见备份目录名,或 fastboot 时代记录的 .flash-state)

第 3 步 · firehose 与 rawprogram XML 的获取路径(出处标注):
    - pmOS wiki: oneplus-enchilada/Unbricking 页(postmarketOS 官方 OP6 救援文档)
    - XDA: OnePlus 6 "Unbrick / MSM DownloadTool" 救援帖(MSM 工具仅 Windows,
      Linux 路线用 edl + prog_ufs_firehose_8998_ddr.elf + rawprogram*.xml)
    ⚠ 只从上述出处获取 firehose/rawprogram;第三方网盘的 loader 有被篡改风险。

第 4 步 · 恢复分区(只动 persist/modemst/fsc/fsg 与用户分区):
    先用本脚本校验备份: bash flash/op6/rescue.sh --serial <SN>
    校验通过后按其打印的命令序列执行(坏备份不会进入恢复流程)。

第 5 步 · 引导链(xbl/xbl_config/modem/abl/tz 一类):
    本 harness 硬拒绝提供该类写入指引 —— 那是硬砖来源(PITFALLS 3)。
    引导链恢复只能走带签名校验的官方 MSM 流程(Windows)并逐字核对
    pmOS wiki / XDA 文档;动它之前确认你有该机型精确氧OS版本的 MSM 包。

演练要求(STRATEGY §7 / PITFALLS "Looks Done But Isn't"):
    每批设备至少完整演练一次 EDL 恢复并留档 —— 文档写了不等于恢复过。
EOF

# ---------------------------------------------------------------- --serial 恢复序列
if [ -n "$SERIAL" ]; then
    printf '\n== 备份校验与恢复命令序列(序列号 %s)==\n\n' "$SERIAL"
    # 坏备份绝不进入恢复流程:manifest 校验失败会退 2 并给出重备份指引
    archmage_flash::require_backup "$SERIAL" "$BACKUP_ROOT"
    BK=$(archmage_flash::backup_dir "$SERIAL" "$BACKUP_ROOT")
    cat <<EOF
备份校验通过。恢复序列(按顺序,逐条复制执行):

  # 0) 解出分区镜像
  tmp=\$(mktemp -d) && tar -xzf $BK/persist.tar.gz -C "\$tmp"

  # 1) 设备在 EDL(9008)时,经 edl 写回(来源:github.com/bkerler/edl):
  edl w persist   \$tmp/persist.img
  edl w modemst1  \$tmp/modemst1.img
  edl w modemst2  \$tmp/modemst2.img
  edl w fsc       \$tmp/fsc.img
  edl w fsg       \$tmp/fsg.img

  # 2) 设备能进 recovery/TWRP(adb)时的等价 dd 序列:
  adb push \$tmp/persist.img /sdcard/ && \\
  adb shell "dd if=/sdcard/persist.img of=/dev/block/by-name/persist"

  # 3) 完成后:edl reset(或拔线重启),验证系统能起、基带/IMEI 在
  #    (设置 → 关于手机 → 状态信息;*#06# 亦可)

  # 4) 把恢复结果(manifest sha256、时间、设备表现)记入设备档案
EOF
    printf '\n再次提醒:引导链分区(xbl/xbl_config/modem/abl/tz 一类)不在本序列内 —— 见上方第 5 步的硬拒绝说明。\n'
    exit 0
fi

printf '\n下一步:确认 9008 已检测到 → 按上面第 1-5 步执行;需要恢复命令序列时带 --serial <SN> 重跑本脚本。\n'
exit 0
