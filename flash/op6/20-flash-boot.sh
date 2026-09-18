#!/usr/bin/env bash
# 20-flash-boot.sh — 刷写 boot 层(强制 erase dtbo 先于一切 flash;双 slot)。
#
# <reversibility rating="costly"> boot 分区半写可用重刷恢复,但失败即需
# 救援路径(rescue.sh / EDL)。顺序是规格(PITFALLS 3):
#   1. erase dtbo(当前 slot 名)+ dtbo_a + dtbo_b 两个显式 slot 名 ——
#      dtbo 未 erase 即刷 boot = 砖;此顺序由 mock 测试台 S7 场景锁定;
#   2. boot.img 写 boot_a 与 boot_b 双 slot(总留一个可启动 slot,T-02-10);
#   3. 镜像资产含 vbmeta.img 时以 --disable-verity --disable-verification
#      写入;不含则跳过并打印原因(解锁态 verity 本已关闭,README 记录
#      该前提)。
#
# 结构(与其他刷写层一致):require_device fastboot → serial →
# require_backup → assert_flash_target(每个 flash 目标)→ 干活 →
# 打印下一层指引。
#
# 用法:
#   bash flash/op6/20-flash-boot.sh --backup-dir PATH --images-dir PATH [-h]
# 退出码:见 lib.sh 头部契约。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ROOT=$(archmage_flash::backup_root_default)
IMAGES_DIR=""

usage() {
    cat <<'EOF'
20-flash-boot.sh — erase dtbo(三处)→ boot 双 slot →(可选)vbmeta

用法:
  bash flash/op6/20-flash-boot.sh --backup-dir PATH --images-dir PATH [-h|--help]

  --backup-dir PATH  备份归档根(默认 flash/op6/backups/;与 10 层/flash-all 同参)
  --images-dir PATH  已校验镜像目录(verify_images_dir 布局:boot.img[,vbmeta.img])

前置:00-unlock 状态在档 + 该序列号五分区备份过 require_backup 拒刷门。
失败重入:直接重跑本层(幂等);或经 flash-all.sh 从失败层继续。
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

[ -n "$IMAGES_DIR" ] || archmage_flash::die 1 "缺少 --images-dir(经 flash-all.sh 编排,或手工指向已校验镜像目录)"

# --- 设备门 + 备份门(33 路径保持 stderr 首行 DEVICE_REQUIRED) -------------
archmage_flash::require_device fastboot
SERIAL=$(archmage_flash::serial_fastboot)
archmage_flash::require_backup "$SERIAL" "$BACKUP_ROOT"
# 镜像再校验(纵深防御:即使被 flash-all 编排调用过,也在本层重验
# sha256+gpg 并确保 .img 已解压 —— 直接单独运行本层时这是唯一的一道)
archmage_flash::verify_images_dir "$IMAGES_DIR"

BOOT_IMG="$IMAGES_DIR/boot.img"
if [ ! -s "$BOOT_IMG" ]; then
    archmage_flash::die 4 "缺少已解压 boot.img(%s)—— 先经 flash-all.sh / fetch_image 完成取像校验与解压" "$IMAGES_DIR"
fi

# --- 顺序强制:erase dtbo 先于一切 flash(PITFALLS 3;S7 锁定) -------------
archmage_flash::info "erase dtbo(当前 slot 名 + dtbo_a/dtbo_b 显式 slot 名)"
fastboot erase dtbo
fastboot erase dtbo_a
fastboot erase dtbo_b

# --- boot 双 slot(每个 flash 目标先过分区拒绝断言) -------------------------
archmage_flash::assert_flash_target boot_a
fastboot flash boot_a "$BOOT_IMG"
archmage_flash::assert_flash_target boot_b
fastboot flash boot_b "$BOOT_IMG"

# --- vbmeta:有则带 verity 关闭旗标写入;无则跳过并说明 ----------------------
if [ -s "$IMAGES_DIR/vbmeta.img" ]; then
    archmage_flash::assert_flash_target vbmeta
    archmage_flash::info "写入 vbmeta(--disable-verity --disable-verification)"
    fastboot --disable-verity --disable-verification flash vbmeta "$IMAGES_DIR/vbmeta.img"
else
    archmage_flash::info "镜像目录无 vbmeta.img,跳过 vbmeta 写入(前提:解锁态 verity 本已关闭;若资产将来包含 vbmeta,flash-all 会自动带旗标写入 —— 见 README)"
fi

# --- 层状态留档(幂等) -------------------------------------------------------
STATE_FILE=$(archmage_flash::state_file "$SERIAL" "$BACKUP_ROOT")
if ! grep -q '^20-flash-boot done' "$STATE_FILE" 2>/dev/null; then
    printf '20-flash-boot done\n' >>"$STATE_FILE"
fi

printf '20 层完成:erase dtbo ×3 + boot_a/boot_b 双 slot%s。\n' \
    "$([ -s "$IMAGES_DIR/vbmeta.img" ] && printf ' + vbmeta(verity 关闭)')"
printf '下一层: bash flash/op6/30-flash-rootfs.sh --backup-dir <PATH> --images-dir <PATH> --yes\n'
printf '(或直接由 flash-all.sh 继续编排)\n'
