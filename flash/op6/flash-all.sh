#!/usr/bin/env bash
# flash-all.sh — OP6 分层刷机编排器(20 → 30 → 40,拒刷门 + 层状态机)。
#
# 铁律的实现顺序(DEVICE-01/DEVICE-02,PITFALLS 3):
#   1. 首刷仪式检查:00-unlock 与 10-backup 是物理前置于刷写的人工仪式,
#      flash-all 不自动执行它们 —— 锁定 bootloader 无法 `fastboot boot`
#      TWRP,备份只能发生在解锁之后。00 层状态未记录 → 打印首刷仪式
#      指引并退 2。
#   2. require_backup 拒刷门:一切刷写之前,该序列号必须有通过校验的
#      五分区 manifest(无有效备份 → 零次 fastboot flash/erase,退 2)。
#   3. 镜像:默认 fetch_image 从 nightly Release 取像 + sha256 + gpg 双
#      校验;--images-dir 仅作为测试台/已预取旁路,但 sha256/gpg 校验
#      仍对目录内文件执行(真机流程强制走 fetch_image,见 README)。
#   4. 逐层 20/30/40:层状态记录于 backups/<serial>/.flash-state(每层
#      完成追加一行);重跑跳过已完成层并打印 SKIP;任一层非零退出即停,
#      "重跑 flash-all.sh 即从失败层继续"。
#
# 用法:
#   bash flash/op6/flash-all.sh [--backup-dir PATH] [--images-dir PATH]
#                               [--release TAG] [--yes] [-h|--help]
#   --yes  必需旗标:本链包含 30 层的 userdata 覆盖(用户数据全清),
#          破坏性意图必须一次性显式给出(与 30 层单独运行时的 --yes 同义)。
#
# 退出码:见 lib.sh 头部契约。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ROOT=$(archmage_flash::backup_root_default)
IMAGES_DIR=""
RELEASE=nightly
ASSUME_YES=no

usage() {
    cat <<'EOF'
flash-all.sh — OP6 分层刷机编排(备份门 → 镜像校验 → 20/30/40 层)

用法:
  bash flash/op6/flash-all.sh [选项]

选项:
  --backup-dir PATH  备份归档根(默认 flash/op6/backups/;与 10 层同参)
  --images-dir PATH  本地镜像目录(测试台/已预取旁路;仍须过 sha256+gpg
                     校验。真机流程不要用 —— 默认从 nightly Release 取像)
  --release TAG      Release 标签(默认 nightly)
  --yes              显式确认 userdata 覆盖(30 层;必需)
  -h, --help         本帮助

前置(人工仪式,flash-all 不会替你做):
  ① 00-unlock.sh --i-accept-data-wipe   ② fastboot boot twrp.img
  ③ 10-backup-persist.sh                ④ 重跑本脚本
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --backup-dir)
            [ $# -ge 2 ] || archmage_flash::die 1 "--backup-dir 需要 PATH 参数"
            BACKUP_ROOT=$2
            shift
            ;;
        --images-dir)
            [ $# -ge 2 ] || archmage_flash::die 1 "--images-dir 需要 PATH 参数"
            IMAGES_DIR=$2
            shift
            ;;
        --release)
            [ $# -ge 2 ] || archmage_flash::die 1 "--release 需要 TAG 参数"
            RELEASE=$2
            shift
            ;;
        --yes)
            ASSUME_YES=yes
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
archmage_flash::require_cmd xz "安装 xz(Arch: sudo pacman -S xz)"
archmage_flash::require_cmd sha256sum "安装 coreutils(Arch: sudo pacman -S coreutils)"
archmage_flash::require_cmd gpg "安装 gnupg(Arch: sudo pacman -S gnupg)"

# --- 设备 + 序列号(33 路径保持 stderr 首行 DEVICE_REQUIRED) ---------------
archmage_flash::require_device fastboot
SERIAL=$(archmage_flash::serial_fastboot)
STATE_FILE=$(archmage_flash::state_file "$SERIAL" "$BACKUP_ROOT")
archmage_flash::info "设备 %s,层状态文件 %s" "$SERIAL" "$STATE_FILE"

# --- 门 1:首刷仪式(00-unlock 状态必须在档) -------------------------------
if ! grep -q '^00-unlock done' "$STATE_FILE" 2>/dev/null; then
    cat >&2 <<EOF
ERROR: 未记录 00-unlock 层状态($STATE_FILE 无 "00-unlock done" 行)—— 首刷仪式未完成,拒绝刷写。
首刷仪式(必须人工按顺序完成;flash-all 不自动执行):
  ① bash flash/op6/00-unlock.sh --i-accept-data-wipe
     # 解锁 bootloader(会清全部数据;设备侧音量键确认)
  ② fastboot boot twrp.img
     # 临时引导 TWRP(TWRP 获取:pmOS wiki oneplus-enchilada)
  ③ bash flash/op6/10-backup-persist.sh
     # 五分区备份:persist/modemst1/modemst2/fsc/fsg(DEVICE-02 铁律)
  ④ 重新执行: bash flash/op6/flash-all.sh --yes
     # 从备份门继续
EOF
    exit 2
fi

# --- 门 2:备份拒刷门(DEVICE-02;一切刷写之前) -----------------------------
archmage_flash::require_backup "$SERIAL" "$BACKUP_ROOT"

# --- 门 3:镜像获取 + 校验 ---------------------------------------------------
if [ -n "$IMAGES_DIR" ]; then
    archmage_flash::info "使用本地 images 目录(测试台/已预取路径,校验不豁免): %s" "$IMAGES_DIR"
    archmage_flash::verify_images_dir "$IMAGES_DIR"
else
    IMAGES_DIR="$SCRIPT_DIR/.work/images/$RELEASE"
    archmage_flash::fetch_image "$RELEASE" "$IMAGES_DIR"
fi

# --- 门 4:破坏性意图(--yes;30 层将覆盖 userdata) --------------------------
if [ "$ASSUME_YES" != yes ]; then
    cat >&2 <<'EOF'
ERROR: 本刷写链包含 30 层 —— fastboot flash userdata 会覆盖用户数据分区(全部用户数据丢失)。
修复: 确认后重跑,附加显式旗标: bash flash/op6/flash-all.sh --yes
(已完成层不受影响;重跑会从失败/未完成层继续)
EOF
    exit 5
fi

# --- 层调度(状态机:已完成层 SKIP,失败层停并指路) -------------------------
for layer in 20-flash-boot 30-flash-rootfs 40-set-slot; do
    if grep -q "^$layer done" "$STATE_FILE" 2>/dev/null; then
        printf 'SKIP %s(层状态已记录,从上次进度继续)\n' "$layer"
        continue
    fi
    script="$SCRIPT_DIR/$layer.sh"
    if [ ! -f "$script" ]; then
        printf 'ERROR: 层未实现: %s(按编号探测缺失;架构与状态机不变,由后续 task 填充)\n' "$script" >&2
        exit 6
    fi
    case "$layer" in
        20-flash-boot)    LAYER_ARGS=(--backup-dir "$BACKUP_ROOT" --images-dir "$IMAGES_DIR") ;;
        30-flash-rootfs)  LAYER_ARGS=(--backup-dir "$BACKUP_ROOT" --images-dir "$IMAGES_DIR" --yes) ;;
        40-set-slot)      LAYER_ARGS=(--backup-dir "$BACKUP_ROOT") ;;
    esac
    archmage_flash::info "执行层 %s" "$layer"
    set +e
    bash "$script" "${LAYER_ARGS[@]}"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        printf 'ERROR: 层 %s 失败(退出码 %d)。\n' "$layer" "$rc" >&2
        printf '从 %s 层恢复: 重跑 bash flash/op6/flash-all.sh --yes 即从失败层继续(已完成层会 SKIP)。\n' "$layer" >&2
        exit "$rc"
    fi
done

printf '全部刷写层完成:%s\n' "$STATE_FILE"
printf '后续:拔线观察首启日志;首验清单(02-03)与 EDL 演练要求见 flash/op6/README.md。\n'
