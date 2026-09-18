#!/usr/bin/env bash
# 10-backup-persist.sh — 首刷前强制备份仪式(DEVICE-02 铁律的实现)。
#
# 模式:adb(设备必须已临时引导进 TWRP/recovery —— 锁定 bootloader 拒绝
# `fastboot boot`,所以备份物理上只能发生在 00-unlock 之后)。
#
# 做什么(只读设备,绝不向设备写任何分区):
#   对五分区 persist / modemst1 / modemst2 / fsc / fsg 逐个
#   `adb exec-out dd if=/dev/block/by-name/<p>` 流式导出(二进制安全),
#   计算 sha256,打包 persist.tar.gz,并写 manifest.json
#   (schema_version=1, serial, created, tool, partitions[{name,size,sha256,file}])。
#   归档布局:backups/<serial>/{persist.img,…,persist.tar.gz,manifest.json}。
#
# 幂等:重跑覆盖同 serial 目录(以最新备份为准)。
#
# 为什么是命根子(PITFALLS 3):persist 丢失 = IMEI/相机校准不可恢复;
# MSM/EDL 恢复会 wiping persist/modemst1/2/fsc/fsg —— 没有这份备份,
# 一次 EDL 就能把设备变成"能开机但没基带的板子"。
#
# 用法:
#   bash flash/op6/10-backup-persist.sh [--backup-dir PATH] [-h|--help]
#   --backup-dir PATH  归档根目录覆盖(默认 flash/op6/backups/;
#                      mock 测试台与多设备归档共用此参数)
#
# 退出码:见 lib.sh 头部契约(33 = 设备缺席,记 WINDOWS.md 顺延)。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ROOT=$(archmage_flash::backup_root_default)

usage() {
    cat <<'EOF'
10-backup-persist.sh — 首刷前强制备份仪式(五分区,只读导出)

用法:
  bash flash/op6/10-backup-persist.sh [--backup-dir PATH] [-h|--help]

前置:设备已解锁(00-unlock.sh)并临时引导 TWRP/recovery:
  fastboot boot twrp.img   # TWRP 获取:pmOS wiki oneplus-enchilada(Installation)

产物: <backup-dir>/<serial>/{persist,modemst1,modemst2,fsc,fsg}.img
       + persist.tar.gz + manifest.json(五分区 sha256/大小/时间/工具版本)
提示: 打印归档路径后,请立即把 persist.tar.gz + manifest.json 复制到
       离线第二副本(另一台机器/加密盘)—— 本目录不在 git 内。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --backup-dir)
            [ $# -ge 2 ] || archmage_flash::die 1 "--backup-dir 需要 PATH 参数"
            BACKUP_ROOT=$2
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

archmage_flash::require_cmd jq "安装 jq(Arch: sudo pacman -S jq)"
archmage_flash::require_cmd tar "安装 tar(Arch: sudo pacman -S tar)"
archmage_flash::require_cmd sha256sum "安装 coreutils(Arch: sudo pacman -S coreutils)"
archmage_flash::require_cmd stat "安装 coreutils(Arch: sudo pacman -S coreutils)"

# --- 设备门(adb 模式;DEVICE_REQUIRED 保持 stderr 首行) --------------------
if ! command -v adb >/dev/null 2>&1; then
    printf 'DEVICE_REQUIRED: 宿主无 adb 工具 —— 安装 android-tools(Arch: sudo pacman -S android-tools)后,设备引导进 TWRP/recovery 重跑\n' >&2
    exit 33
fi
ADB_N=$(adb devices 2>/dev/null | \
    awk 'NR>1 && NF>=2 && ($2=="device"||$2=="recovery"){n++} END{print n+0}')
if [ "$ADB_N" -eq 0 ]; then
    if command -v fastboot >/dev/null 2>&1; then
        FB_N=$(fastboot devices 2>/dev/null | \
            awk 'NR>1 && NF>=2 && $2=="fastboot"{n++} END{print n+0}')
        if [ "$FB_N" -gt 0 ]; then
            printf 'ERROR: 设备在 fastboot 模式 —— 备份需要 TWRP/recovery 的 adb 环境。\n' >&2
            printf '修复(按顺序):\n' >&2
            printf '  1. 若尚未解锁: bash flash/op6/00-unlock.sh --i-accept-data-wipe\n' >&2
            printf '  2. fastboot boot twrp.img   # 临时引导 TWRP,不刷 recovery 分区\n' >&2
            printf '     TWRP 镜像获取: pmOS wiki oneplus-enchilada(Installation 页)\n' >&2
            printf '  3. 重跑本脚本\n' >&2
            exit 1
        fi
    fi
    printf 'DEVICE_REQUIRED: adb 模式下无设备 —— 设备须处于 TWRP/recovery(fastboot boot twrp.img 后 adbd 可用);接上设备重跑\n' >&2
    exit 33
fi

SERIAL=$(archmage_flash::serial_adb)
BACKUP_DIR=$(archmage_flash::backup_dir "$SERIAL" "$BACKUP_ROOT")
mkdir -p "$BACKUP_DIR"

archmage_flash::info "序列号 %s —— 开始五分区备份(只读导出)" "$SERIAL"

# --- 逐分区流式导出(exec-out 二进制安全;shell 会污染 CRLF) ---------------
ENTRIES_JSON=()
for p in $ARCHMAGE_FLASH_BACKUP_PARTITIONS; do
    img="$BACKUP_DIR/$p.img"
    adb exec-out dd "if=/dev/block/by-name/$p" >"$img"
    if [ ! -s "$img" ]; then
        archmage_flash::die 1 "导出 %s 得到空文件(dd 经 adb exec-out 失败?设备是否真的在 TWRP 且 /dev/block/by-name/%s 存在)" "$p" "$p"
    fi
    sha=$(sha256sum "$img" | cut -d' ' -f1)
    size=$(stat -c %s "$img")
    archmage_flash::info "  %s: %s 字节, sha256=%s" "$p" "$size" "$sha"
    ENTRIES_JSON+=("$(jq -cn --arg name "$p" --arg file "$p.img" --arg sha256 "$sha" \
        --argjson size "$size" '{name: $name, size: $size, sha256: $sha256, file: $file}')")
done

# --- 打包 + manifest ---------------------------------------------------------
tar -czf "$BACKUP_DIR/persist.tar.gz" \
    -C "$BACKUP_DIR" persist.img modemst1.img modemst2.img fsc.img fsg.img

PARTITIONS_JSON=$(printf '%s\n' "${ENTRIES_JSON[@]}" | jq -s '.')
jq -n \
    --arg serial "$SERIAL" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg tool "archmage-flash/$ARCHMAGE_FLASH_TOOL_VERSION 10-backup-persist.sh" \
    --argjson partitions "$PARTITIONS_JSON" \
    '{schema_version: 1, serial: $serial, created: $created, tool: $tool,
      partitions: $partitions}' >"$BACKUP_DIR/manifest.json"

# --- 自检:仪式产物必须能通过刷写层使用的同一道拒刷门 -----------------------
archmage_flash::require_backup "$SERIAL" "$BACKUP_ROOT"

printf '备份完成:%s\n' "$BACKUP_DIR"
printf '  归档(用于离线第二副本): %s\n' "$BACKUP_DIR/persist.tar.gz"
printf '  manifest: %s\n' "$BACKUP_DIR/manifest.json"
printf '提醒:请立即将 persist.tar.gz 与 manifest.json 复制到离线第二副本(另一台机器/加密盘)。\n'
printf '提醒:本脚本只读设备分区,不做任何写入;刷写动作由 20/30/40 层在备份门之后进行。\n'
