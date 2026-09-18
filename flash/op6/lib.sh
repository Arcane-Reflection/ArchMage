# lib.sh — ArchMage OP6 刷机 harness 共享库(DEVICE-01/DEVICE-02 安全核心)。
#
# 被 flash/op6/*.sh source。调用方自带 shell 选项(它们以
# `set -euo pipefail` 运行);本库刻意不设置任何选项,source 不会改变
# 调用方行为(test/lib/common.sh 先例)。
#
# 提供(命名空间 archmage_flash::):
#   require_cmd <cmd> [repair_hint]    宿主工具探针,缺失退 1 并打印精确修复命令
#   require_device <fastboot|adb>      设备在场门:无工具/无设备退 33,
#                                      stderr 首行 DEVICE_REQUIRED(本 phase
#                                      的 device-deferred 统一约定)
#   serial_fastboot / serial_adb       序列号提取
#   backup_dir <serial> [root]         backups/<serial>/ 路径(stdout)
#   require_backup <serial> [root]     五分区 manifest 拒刷门,任一不符退 2
#   refuse_partitions                  分区拒绝清单(stdout,每行一个)
#   assert_flash_target <partition>    拒绝清单分区的 flash 目标直接退 3
#   expected_fingerprint <file>        从 FINGERPRINT.txt 提取 40 位指纹
#   gpg_verify_detached <sig> <target> <fingerprint.txt>
#                                      gpg 验签 + 指纹比对,失败退 4
#   fetch_image [release] [dest_dir]   nightly Release 取像 + 校验,失败退 4
#   verify_images_dir <dir>            对目录内 boot/rootfs(可选 vbmeta)
#                                      三件套做 sha256+gpg 校验并解压
#
# 退出码契约(所有层脚本共用,README 同步记录):
#   0   成功
#   1   宿主环境/用法错误
#   2   备份门:无该序列号的有效 manifest,或首刷仪式(00-unlock 状态)未记录
#   3   分区拒绝清单违规(assert_flash_target)
#   4   镜像获取/校验失败(下载 / sha256 / gpg)
#   5   缺破坏性动作的显式确认旗标(--i-accept-data-wipe / --yes)
#   6   编排错误(层脚本缺失、层状态不可写)
#   7   镜像超过 fastboot 传输上限
#   33  DEVICE_REQUIRED —— 设备(或 fastboot/adb 工具)缺席;记 WINDOWS.md
#       为 device-deferred 顺延,不是脚本缺陷
#
# PITFALLS 3 是本库的规格来源:dtbo 未 erase 即砖、A/B slot 混淆、
# xbl/modem 类分区碰一下就是硬砖、persist/modemst 丢失 = IMEI/相机校准
# 不可恢复。本库把"备份先行 + 拒绝清单"从铁律变成机器执行的事实。

ARCHMAGE_FLASH_TOOL_VERSION="0.1.0"

# 备份仪式固定导出的五分区(DEVICE-02;PITFALLS 3:MSM 会 wiping 它们)。
ARCHMAGE_FLASH_BACKUP_PARTITIONS="persist modemst1 modemst2 fsc fsg"

archmage_flash::die() {
    local code="$1"; shift
    printf 'ERROR: %s\n' "$(printf -- "$@")" >&2
    exit "$code"
}

archmage_flash::info() {
    printf '==> %s\n' "$(printf -- "$@")" >&2
}

archmage_flash::warn() {
    printf 'WARNING: %s\n' "$(printf -- "$@")" >&2
}

# require_cmd <cmd> [repair_hint]
# 宿主工具缺失 → 退 1,打印精确修复命令(01-02 输出风格)。
archmage_flash::require_cmd() {
    local cmd="$1" hint="${2:-}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf 'ERROR: 必需工具 %s 不在 PATH\n' "$cmd" >&2
        if [ -n "$hint" ]; then
            printf '修复: %s\n' "$hint" >&2
        fi
        exit 1
    fi
}

# backup_root_default — 默认备份归档根:flash/op6/backups/(lib.sh 所在目录)。
archmage_flash::backup_root_default() {
    printf '%s\n' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/backups"
}

# backup_dir <serial> [backup_root]
archmage_flash::backup_dir() {
    local serial="${1:?serial required}"
    local root="${2:-$(archmage_flash::backup_root_default)}"
    printf '%s/%s\n' "${root%/}" "$serial"
}

# 层状态文件:每层完成追加一行 "<脚本名> done"(幂等,见各层脚本)。
# flash-all 据此跳过已完成层 —— "任意失败层可恢复"(DEVICE-01)。
archmage_flash::state_file() {
    local serial="${1:?serial required}"
    local root="${2:-$(archmage_flash::backup_root_default)}"
    printf '%s/.flash-state\n' "$(archmage_flash::backup_dir "$serial" "$root")"
}

# require_device <fastboot|adb>
# 无工具或无设备 → 退 33,且 DEVICE_REQUIRED 必须是 stderr 首行(调用方
# 需保证在此之前没有其他 stderr 输出)。多台设备且未设 ANDROID_SERIAL
# → 退 1(歧义是环境错误,不是设备缺席)。
archmage_flash::require_device() {
    local mode="$1" tool count
    case "$mode" in
        fastboot) tool=fastboot ;;
        adb)      tool=adb ;;
        *) archmage_flash::die 1 "require_device: 未知模式 '$mode'(应为 fastboot|adb)" ;;
    esac
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'DEVICE_REQUIRED: 宿主无 %s 工具 —— 安装 android-tools(Arch: sudo pacman -S android-tools;Debian/Ubuntu: sudo apt install android-tools)后带设备重跑\n' "$tool" >&2
        exit 33
    fi
    count=$("$tool" devices 2>/dev/null | \
        awk 'NR>1 && NF>=2 && ($2=="fastboot"||$2=="device"||$2=="recovery"){n++} END{print n+0}')
    if [ "$count" -eq 0 ]; then
        if [ "$mode" = "adb" ]; then
            printf 'DEVICE_REQUIRED: adb 模式下无设备 —— 备份需要设备处于 TWRP/recovery(锁屏解开后 adbd 可用);接上设备重跑\n' >&2
        else
            printf 'DEVICE_REQUIRED: fastboot 模式下无设备 —— 关机后按住 音量+ 与 音量− 接 USB 进入 bootloader/fastboot,再重跑\n' >&2
        fi
        exit 33
    fi
    if [ "$count" -gt 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then
        archmage_flash::die 1 "$mode 模式下发现 $count 台设备 —— export ANDROID_SERIAL=<目标序列号> 后重跑"
    fi
    return 0
}

# serial_fastboot — 从 `fastboot getvar serialno` 输出提取序列号。
archmage_flash::serial_fastboot() {
    local serial
    serial=$(fastboot getvar serialno 2>&1 | awk '/\(bootloader\)/{print $2; exit}')
    if [ -z "$serial" ]; then
        archmage_flash::die 1 "无法经 fastboot getvar serialno 读取序列号(设备是否还在 fastboot 模式?)"
    fi
    printf '%s\n' "$serial"
}

# serial_adb — `adb get-serialno` 提取序列号(ANDROID_SERIAL 优先)。
archmage_flash::serial_adb() {
    local serial
    if [ -n "${ANDROID_SERIAL:-}" ]; then
        printf '%s\n' "$ANDROID_SERIAL"
        return 0
    fi
    serial=$(adb get-serialno 2>/dev/null | head -n1 | tr -d '[:space:]')
    if [ -z "$serial" ] || [ "$serial" = "unknown" ]; then
        archmage_flash::die 1 "无法经 adb get-serialno 读取序列号(设备是否还在 recovery 模式?)"
    fi
    printf '%s\n' "$serial"
}

# require_backup <serial> [backup_root]
# 拒刷门(DEVICE-02 铁律的机器执行形态):无 manifest / schema 不对 /
# 五分区不全 / 任一 sha256 与磁盘文件不符 / tar 包损坏或缺成员 → 退 2。
# 通过 = 该序列号具备可恢复的五分区备份,刷写层才被允许继续。
archmage_flash::require_backup() {
    local serial="${1:?serial required}"
    local root="${2:-$(archmage_flash::backup_root_default)}"
    local dir manifest p f want got
    dir=$(archmage_flash::backup_dir "$serial" "$root")
    manifest="$dir/manifest.json"

    if [ ! -f "$manifest" ]; then
        printf 'ERROR: 序列号 %s 没有备份 manifest(%s)\n' "$serial" "$manifest" >&2
        printf 'DEVICE-02 铁律:没有按序列号归档的五分区备份(persist/modemst1/modemst2/fsc/fsg)之前,任何刷写一律拒绝。\n' >&2
        printf '修复:设备进入 TWRP/recovery 后执行 —— bash flash/op6/10-backup-persist.sh --backup-dir %s\n' "$root" >&2
        exit 2
    fi

    if ! jq -e '
        .schema_version == 1 and
        (.serial | type == "string") and
        (.partitions | type == "array") and
        ([.partitions[].name] | sort) == (["fsc","fsg","modemst1","modemst2","persist"] | sort) and
        ([.partitions[].sha256] | length) == 5 and
        all(.partitions[]; (.name|type=="string") and (.size|type=="number") and (.sha256|type=="string") and (.file|type=="string"))
    ' "$manifest" >/dev/null 2>&1; then
        printf 'ERROR: %s schema 校验失败(需要 schema_version=1 且 partitions 恰为 fsc/fsg/modemst1/modemst2/persist 五条,各含 name/size/sha256/file)\n' "$manifest" >&2
        printf '修复:重跑 bash flash/op6/10-backup-persist.sh --backup-dir %s 重新生成完整备份\n' "$root" >&2
        exit 2
    fi

    while IFS=$'\t' read -r p f want; do
        if [ ! -f "$dir/$f" ]; then
            printf 'ERROR: 备份不完整:manifest 列出 %s 的文件 %s 在磁盘上不存在(%s)\n' "$p" "$f" "$dir" >&2
            printf '修复:重跑 bash flash/op6/10-backup-persist.sh --backup-dir %s\n' "$root" >&2
            exit 2
        fi
        got=$(sha256sum "$dir/$f" | cut -d' ' -f1)
        if [ "$got" != "$want" ]; then
            printf 'ERROR: 备份校验失败:%s 的 sha256 与 manifest 不一致(磁盘 %s ≠ manifest %s)\n' "$p" "$got" "$want" >&2
            printf '修复:重跑 bash flash/op6/10-backup-persist.sh --backup-dir %s 重建该序列号备份\n' "$root" >&2
            exit 2
        fi
    done < <(jq -r '.partitions[] | [.name, .file, .sha256] | @tsv' "$manifest")

    if [ ! -f "$dir/persist.tar.gz" ]; then
        printf 'ERROR: 备份归档缺失:%s(离线第二副本的搬运载体)\n' "$dir/persist.tar.gz" >&2
        printf '修复:重跑 bash flash/op6/10-backup-persist.sh --backup-dir %s\n' "$root" >&2
        exit 2
    fi
    if ! tar -tzf "$dir/persist.tar.gz" >/dev/null 2>&1; then
        printf 'ERROR: 备份归档损坏(无法列出成员):%s\n' "$dir/persist.tar.gz" >&2
        printf '修复:重跑 bash flash/op6/10-backup-persist.sh --backup-dir %s\n' "$root" >&2
        exit 2
    fi
    local missing=""
    while read -r f; do
        if ! tar -tzf "$dir/persist.tar.gz" 2>/dev/null | grep -qx "$f"; then
            missing="$missing $f"
        fi
    done < <(jq -r '.partitions[].file' "$manifest")
    if [ -n "$missing" ]; then
        printf 'ERROR: 备份归档缺成员:%s\n' "$missing" >&2
        printf '修复:重跑 bash flash/op6/10-backup-persist.sh --backup-dir %s\n' "$root" >&2
        exit 2
    fi

    printf '备份校验通过:%s(五分区 sha256 与磁盘一致)\n' "$manifest" >&2
    return 0
}

# refuse_partitions — 分区拒绝清单(xbl/xbl_config/modem/modemst1/modemst2/
# abl/tz/hyp/rpm/keymaster/devinfo/persist/fsc/fsg/dtbo)。
# PITFALLS 3:对这些分区的任何 fastboot flash 都是硬砖/校准不可恢复路径。
# dtbo 在清单内:OP6 主线流程只 erase dtbo、绝不 flash 它(verify S10)。
archmage_flash::refuse_partitions() {
    printf '%s\n' \
        xbl xbl_config modem modemst1 modemst2 abl tz hyp rpm \
        keymaster devinfo persist fsc fsg dtbo
}

# assert_flash_target <partition>
# 所有刷写层在每次 fastboot flash 之前调用;目标(去掉 _a/_b 后缀)落在
# 拒绝清单内 → 退 3。erase dtbo 不是 flash,不受此断言约束(顺序强制
# 由 20-flash-boot.sh 保证:erase 先于 flash)。
archmage_flash::assert_flash_target() {
    local target="${1:?partition required}" base
    base=$target
    case "$base" in
        *_a|*_b) base=${base%_[ab]} ;;
    esac
    if archmage_flash::refuse_partitions | grep -qx "$base"; then
        printf 'ERROR: 拒绝刷写分区 %s:它在分区拒绝清单上(xbl/modem/abl/tz/persist 等属引导链/校准分区,误写即硬砖或 IMEI/相机校准不可恢复;dtbo 只允许 erase,不允许 flash —— PITFALLS 3)。\n' "$target" >&2
        printf '若你确实需要动这些分区,请走 rescue.sh 的 EDL 路径并阅读 pmOS wiki oneplus-enchilada/Unbricking;本 harness 不提供该操作。\n' >&2
        exit 3
    fi
    return 0
}

# expected_fingerprint <FINGERPRINT.txt> — 提取第一个 40 位十六进制指纹。
archmage_flash::expected_fingerprint() {
    grep -oE '[0-9A-Fa-f]{40}' "$1" 2>/dev/null | head -n1 | tr 'a-f' 'A-F'
}

# gpg_verify_detached <sig> <target> <FINGERPRINT.txt>
# gpg 验签且签名者指纹必须等于 FINGERPRINT.txt 声明的指纹(防止"有签名
# 但不是发布密钥"的绕过)。失败退 4(T-02-06)。EPHEMERAL 密钥按 02-01
# 契约给显著警告但不阻断(与 01-02 ephemeral staging key 决策一致)。
archmage_flash::gpg_verify_detached() {
    local sig="$1" target="$2" fprfile="$3"
    local want have out
    want=$(archmage_flash::expected_fingerprint "$fprfile")
    if [ -z "$want" ]; then
        archmage_flash::die 4 "无法从 %s 解析出 40 位指纹" "$fprfile"
    fi
    if grep -qi '^EPHEMERAL: *true' "$fprfile" 2>/dev/null; then
        archmage_flash::warn "FINGERPRINT.txt 标记 EPHEMERAL —— 该签名仅证明本次 CI 运行自身的完整性,不是 ArchMage 来源证明;操作者自行确认后再继续"
    fi
    out=$(gpg --status-fd 1 --verify "$sig" "$target" 2>/dev/null || true)
    have=$(printf '%s\n' "$out" | awk '/^\[GNUPG:\] VALIDSIG/{print $3; exit}' | tr 'a-f' 'A-F')
    if [ -z "$have" ]; then
        printf 'ERROR: gpg 验签失败(无有效签名,或发布公钥未导入本机 keyring):%s\n' "$sig" >&2
        printf '修复:按 %s 的指纹与项目公示指纹核对后导入发布公钥,再重跑\n' "$fprfile" >&2
        exit 4
    fi
    if [ "$have" != "$want" ]; then
        archmage_flash::die 4 "签名指纹 %s ≠ FINGERPRINT.txt 期望的 %s —— 镜像可能被替换,拒绝继续" "$have" "$want"
    fi
    return 0
}

# verify_images_dir <dir>
# 目录契约(02-01 资产契约的本地形态,fetch_image 归一化后的布局):
#   boot.img.xz / rootfs.img.xz [+ 可选 vbmeta.img.xz]
#   每个伴随 <name>.img.xz.sha256(对 .xz 的 sha256)与 <name>.img.xz.sig
#   FINGERPRINT.txt
# 校验通过后解压出 <name>.img(xz -dk,幂等)。任一失败退 4。
archmage_flash::verify_images_dir() {
    local dir="${1:?images dir required}"
    local fprfile="$dir/FINGERPRINT.txt"
    local kind xz have_vbmeta=0

    if [ ! -f "$fprfile" ]; then
        archmage_flash::die 4 "images 目录缺 FINGERPRINT.txt:%s" "$dir"
    fi
    [ -f "$dir/vbmeta.img.xz" ] && have_vbmeta=1

    for kind in boot rootfs; do
        xz="$dir/$kind.img.xz"
        if [ ! -f "$xz" ] || [ ! -f "$xz.sha256" ] || [ ! -f "$xz.sig" ]; then
            archmage_flash::die 4 "images 目录缺 %s.img.xz/.sha256/.sig 三件套(目录:%s)" "$kind" "$dir"
        fi
        if ! (cd "$dir" && sha256sum -c "$kind.img.xz.sha256" >/dev/null); then
            archmage_flash::die 4 "sha256 校验失败:%s(镜像损坏或被篡改,T-02-06)" "$xz.sha256"
        fi
        archmage_flash::gpg_verify_detached "$xz.sig" "$xz" "$fprfile"
        if [ ! -f "$dir/$kind.img" ]; then
            xz -dk "$xz" || archmage_flash::die 4 "解压失败:%s" "$xz"
        fi
    done

    if [ "$have_vbmeta" = 1 ]; then
        xz="$dir/vbmeta.img.xz"
        if [ ! -f "$xz.sha256" ] || [ ! -f "$xz.sig" ]; then
            archmage_flash::die 4 "vbmeta.img.xz 存在但缺 .sha256/.sig(目录:%s)" "$dir"
        fi
        if ! (cd "$dir" && sha256sum -c "vbmeta.img.xz.sha256" >/dev/null); then
            archmage_flash::die 4 "sha256 校验失败:%s" "$dir/vbmeta.img.xz.sha256"
        fi
        archmage_flash::gpg_verify_detached "$xz.sig" "$xz" "$fprfile"
        if [ ! -f "$dir/vbmeta.img" ]; then
            xz -dk "$xz" || archmage_flash::die 4 "解压失败:%s" "$xz"
        fi
    fi

    printf '镜像校验通过:%s(sha256 + gpg;boot/rootfs%s 已解压就绪)\n' "$dir" "$([ "$have_vbmeta" = 1 ] && printf ' + vbmeta')" >&2
    return 0
}

# fetch_image [release=nightly] [dest_dir]
# 经官方 gh CLI 按 02-01 资产契约取 archmage-op6-phosh-* 镜像三件套 +
# FINGERPRINT.txt,先按原始(dated)文件名做 sha256 + gpg 双校验,再归一化
# 为 boot.img.xz / rootfs.img.xz 布局,最后经 verify_images_dir 复验并解压。
# 任何失败退 4(不触碰 fastboot —— T-02-06:校验失败不触设备)。
archmage_flash::fetch_image() {
    local release="${1:-nightly}"
    local dest="${2:?dest dir required}"
    local repo="${ARCHMAGE_GH_REPO:-}" f kind

    if [ -z "$repo" ]; then
        repo=$(git -C "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)" \
            remote get-url origin 2>/dev/null | \
            sed -n 's#.*github\.com[:/]\(.*\)\.git$#\1#p' | head -n1)
    fi
    if [ -z "$repo" ]; then
        archmage_flash::die 4 "无法确定 GitHub 仓库(ARCHMAGE_GH_REPO 未设置且无 origin remote)—— export ARCHMAGE_GH_REPO=owner/repo 后重跑"
    fi

    archmage_flash::require_cmd gh "安装 gh(Arch: sudo pacman -S github-cli)并 gh auth login"
    archmage_flash::require_cmd jq "安装 jq(Arch: sudo pacman -S jq)"
    archmage_flash::require_cmd xz "安装 xz(Arch: sudo pacman -S xz)"
    archmage_flash::require_cmd gpg "安装 gnupg(Arch: sudo pacman -S gnupg)"

    mkdir -p "$dest"
    archmage_flash::info "下载 nightly 资产(%s release: %s)…" "$repo" "$release"
    if ! (cd "$dest" && gh release download "$release" -R "$repo" --clobber \
        -p 'archmage-op6-phosh-*-boot.img.xz' \
        -p 'archmage-op6-phosh-*-boot.img.xz.sha256' \
        -p 'archmage-op6-phosh-*-boot.img.xz.sig' \
        -p 'archmage-op6-phosh-*-rootfs.img.xz' \
        -p 'archmage-op6-phosh-*-rootfs.img.xz.sha256' \
        -p 'archmage-op6-phosh-*-rootfs.img.xz.sig' \
        -p 'FINGERPRINT.txt'); then
        archmage_flash::die 4 "gh release download %s(%s)失败 —— 检查 release 是否存在、gh auth 状态" "$release" "$repo"
    fi

    for kind in boot rootfs; do
        f=$(ls "$dest"/archmage-op6-phosh-*-"$kind".img.xz 2>/dev/null | sort | tail -n1)
        if [ -z "$f" ]; then
            archmage_flash::die 4 "release %s 没有 archmage-op6-phosh-*-%s.img.xz 资产" "$release" "$kind"
        fi
        # 先按 dated 原名校验(sha256 文件内容指向原名),再归一化。
        if ! (cd "$dest" && sha256sum -c "$(basename "$f").sha256" >/dev/null); then
            archmage_flash::die 4 "sha256 校验失败:%s" "$(basename "$f")"
        fi
        archmage_flash::gpg_verify_detached "$dest/$(basename "$f").sig" "$f" "$dest/FINGERPRINT.txt"
        rm -f "$dest/$kind.img.xz" "$dest/$kind.img.xz.sha256" "$dest/$kind.img.xz.sig" "$dest/$kind.img"
        mv "$f" "$dest/$kind.img.xz"
        mv "$dest/$(basename "$f").sha256" "$dest/$kind.img.xz.sha256"
        mv "$dest/$(basename "$f").sig" "$dest/$kind.img.xz.sig"
        (cd "$dest" && sha256sum "$kind.img.xz" > "$kind.img.xz.sha256")
    done

    archmage_flash::verify_images_dir "$dest"
    return 0
}
