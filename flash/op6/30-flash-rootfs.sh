#!/usr/bin/env bash
# 30-flash-rootfs.sh — 刷写 rootfs 层(rootfs.img → userdata,覆盖即清数据)。
#
# <reversibility rating="costly"> userdata 覆盖 = 用户数据全清,恢复 = 重刷。
# 防线:
#   - require_backup 拒刷门(与其他刷写层一致);
#   - assert_flash_target userdata(分区拒绝断言);
#   - 写入前打印将覆盖的分区与镜像大小,要求确认旗标 --yes(缺旗标退 5,
#     S8 场景锁定;flash-all 编排时由 flash-all 的 --yes 传递);
#   - 镜像大于 fastboot 传输上限时:只给上游指引并退非零,绝不自行发明
#     分块/切分协议(上限可用 ARCHMAGE_FLASH_MAX_TRANSFER_MB 覆盖,默认
#     512 MiB —— OP6 时代 fastboot download 常见上限)。
#
# 用法:
#   bash flash/op6/30-flash-rootfs.sh --backup-dir PATH --images-dir PATH [--yes] [-h]
# 退出码:见 lib.sh 头部契约(7 = 超传输上限)。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKUP_ROOT=$(archmage_flash::backup_root_default)
IMAGES_DIR=""
ASSUME_YES=no

usage() {
    cat <<'EOF'
30-flash-rootfs.sh — rootfs.img 写入 userdata 分区(覆盖用户数据)

用法:
  bash flash/op6/30-flash-rootfs.sh --backup-dir PATH --images-dir PATH --yes [-h|--help]

  --backup-dir PATH  备份归档根(默认 flash/op6/backups/)
  --images-dir PATH  已校验镜像目录(verify_images_dir 布局:rootfs.img)
  --yes              显式确认覆盖 userdata(必需)
  ARCHMAGE_FLASH_MAX_TRANSFER_MB=<MiB>  覆盖 fastboot 传输上限检查(默认 512)

前置:00-unlock 状态在档 + 五分区备份过 require_backup 拒刷门。
失败重入:直接重跑本层;或经 flash-all.sh 从失败层继续。
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

[ -n "$IMAGES_DIR" ] || archmage_flash::die 1 "缺少 --images-dir(经 flash-all.sh 编排,或手工指向已校验镜像目录)"

# --- 设备门 + 备份门 ---------------------------------------------------------
archmage_flash::require_device fastboot
SERIAL=$(archmage_flash::serial_fastboot)
archmage_flash::require_backup "$SERIAL" "$BACKUP_ROOT"
# 镜像再校验(纵深防御:sha256+gpg 重验 + 确保 rootfs.img 已解压)
archmage_flash::verify_images_dir "$IMAGES_DIR"

ROOTFS_IMG="$IMAGES_DIR/rootfs.img"
if [ ! -s "$ROOTFS_IMG" ]; then
    archmage_flash::die 4 "缺少已解压 rootfs.img(%s)—— 先经 flash-all.sh / fetch_image 完成取像校验与解压" "$IMAGES_DIR"
fi

# --- 破坏性动作预告(先打印,再要旗标/做上限检查) ---------------------------
SIZE_BYTES=$(stat -c %s "$ROOTFS_IMG")
LIMIT_MB=${ARCHMAGE_FLASH_MAX_TRANSFER_MB:-512}
SIZE_MB=$(( (SIZE_BYTES + 1048575) / 1048576 ))
printf '将覆盖分区: userdata(全部用户数据丢失)\n'
printf '镜像: %s(%s 字节,约 %s MiB;传输上限检查 %s MiB)\n' "$ROOTFS_IMG" "$SIZE_BYTES" "$SIZE_MB" "$LIMIT_MB"

if [ "$SIZE_MB" -gt "$LIMIT_MB" ]; then
    cat >&2 <<EOF
ERROR: 镜像(约 ${SIZE_MB} MiB)超过 fastboot 传输上限(当前检查值 ${LIMIT_MB} MiB)—— fastboot download 会失败或半写。
上游指引(本 harness 不自行发明分块协议):
  1. 参阅 pmOS wiki oneplus-enchilada 安装页对大镜像 fastboot 传输的说明;
  2. 优先方案:压缩传输/分卷由发布侧(image.yml)处理,或改用 dd 到
     userdata 的 recovery 侧路径(TWRP 内 dd of=/dev/block/by-name/userdata);
  3. 确认上限真实值: fastboot getvar max-download-size(以设备报告为准)。
EOF
    exit 7
fi

if [ "$ASSUME_YES" != yes ]; then
    cat >&2 <<'EOF'
ERROR: 覆盖 userdata 是破坏性动作,需要显式确认旗标。
修复: 确认后重跑,附加: --yes
EOF
    exit 5
fi

# --- 写入(先过分区拒绝断言) -------------------------------------------------
archmage_flash::assert_flash_target userdata
fastboot flash userdata "$ROOTFS_IMG"

# --- 层状态留档(幂等) -------------------------------------------------------
STATE_FILE=$(archmage_flash::state_file "$SERIAL" "$BACKUP_ROOT")
if ! grep -q '^30-flash-rootfs done' "$STATE_FILE" 2>/dev/null; then
    printf '30-flash-rootfs done\n' >>"$STATE_FILE"
fi

printf '30 层完成:userdata ← rootfs.img(%s 字节)。\n' "$SIZE_BYTES"
printf '下一层: bash flash/op6/40-set-slot.sh --backup-dir <PATH> [--slot a|b]\n'
printf '(或直接由 flash-all.sh 继续编排)\n'
