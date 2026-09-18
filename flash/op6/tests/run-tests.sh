#!/usr/bin/env bash
# run-tests.sh — OP6 刷机 harness 的 mock 测试台(S1–S10 场景矩阵)。
#
# 纯 bash + mock-fastboot/mock-adb(symlink 进临时 bin 前置 PATH;T-02-09:
# mock 只存在于此目录,且仅由本脚本接线)。每个场景独立 tmpdir,断言:
#   - 退出码(2=备份门/仪式、3=分区拒绝、4=镜像校验、5=确认旗标、
#     6=层未实现、33=DEVICE_REQUIRED)
#   - mock 日志中的调用顺序与次数(零 flash / erase-before-flash / 双 slot)
#   - manifest/层状态文件内容
# 镜像三件套由 ephemeral gpg 密钥现场签出(gpg 验签路径真实执行)。
#
# 结果(含每个场景的 mock 日志与 stdout/stderr)落在
# flash/op6/tests/.results/<ts>/(已 gitignore;CI 失败时上传为 artifact)。
#
# 用法: bash flash/op6/tests/run-tests.sh
# 退出码 0 = 全绿;非零 = 场景矩阵有红。

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OP6_DIR=$(cd -- "$TESTS_DIR/.." && pwd)
RESULTS_ROOT=${ARCHMAGE_FLASH_TEST_RESULTS:-$TESTS_DIR/.results}
RUN_ID=$(date +%Y%m%d-%H%M%S)
RESULTS=$RESULTS_ROOT/$RUN_ID
mkdir -p "$RESULTS"

ORIG_PATH=$PATH
PASS=0
FAIL=0
FAILED=()

# ---------------------------------------------------------------- 计数与断言
note()  { printf '%s\n' "$*" | tee -a "$RESULTS/summary.log"; }
ok()    { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  FAIL %s\n' "$1"; }

scenario() { printf '\n=== %s ===\n' "$1" | tee -a "$RESULTS/summary.log"; }

assert_rc() { # desc expected actual
    [ "$3" = "$2" ] && ok "$1 (rc=$3)" || bad "$1: 期望 rc=$2, 实得 rc=$3"
}
assert_rc_nonzero() { # desc actual
    [ "$2" -ne 0 ] && ok "$1 (rc=$2)" || bad "$1: 期望非零, 实得 rc=0"
}
assert_contains() { # desc file needle
    grep -qF -- "$3" "$2" 2>/dev/null && ok "$1" || bad "$1: 「$3」未出现在 $(basename "$2")"
}
assert_not_contains() { # desc file needle
    ! grep -qF -- "$3" "$2" 2>/dev/null && ok "$1" || bad "$1: 不应出现的「$3」出现在 $(basename "$2")"
}
assert_eq() { # desc expected actual
    [ "$3" = "$2" ] && ok "$1" || bad "$1: 期望「$2」, 实得「$3」"
}
assert_first_line_prefix() { # desc file prefix
    local first
    first=$(head -n1 "$2" 2>/dev/null)
    case "$first" in
        "$3"*) ok "$1 (首行: ${first%%$'\n'*})" ;;
        *) bad "$1: stderr 首行应是 $3 开头, 实得「$first」" ;;
    esac
}
assert_file() { # desc path
    [ -s "$2" ] && ok "$1 ($2)" || bad "$1: 文件缺失或为空: $2"
}

run_cmd() { # tmpdir cmd [args...] → RUN_RC, $tmp/last.{out,err}
    local tmp=$1; shift
    "$@" >"$tmp/last.out" 2>"$tmp/last.err" && RUN_RC=0 || RUN_RC=$?
}
mock_log_count() { # egrep-pattern → 次数(当前 MOCK_LOG)
    grep -cE -- "$1" "${MOCK_LOG:-/nonexistent}" 2>/dev/null || true
}

# ---------------------------------------------------------------- 测试台装配
# tests/fastboot 与 tests/adb 是指向 mock 的符号链接(T-02-09:mock 仅存于
# tests/ 且仅当 tests/ 被前置 PATH 时生效 —— 与计划 verify 的
# PATH="$PWD/flash/op6/tests:$PATH" 接线一致)
setup_bin() {
    export PATH="$TESTS_DIR:$ORIG_PATH"
}

setup_gpg() {
    TEST_GNUPGHOME=$RESULTS/gnupg
    mkdir -p "$TEST_GNUPGHOME"
    chmod 700 "$TEST_GNUPGHOME"
    gpg --homedir "$TEST_GNUPGHOME" --batch --passphrase '' \
        --quick-generate-key archmage-flash-test ed25519 sign 0 >/dev/null 2>&1
    TEST_FPR=$(gpg --homedir "$TEST_GNUPGHOME" --list-keys --with-colons 2>/dev/null |
        awk -F: '/^fpr/{print $10; exit}')
    [ -n "$TEST_FPR" ] || { note "FATAL: ephemeral 测试密钥生成失败"; exit 1; }
    # 被测脚本调用裸 gpg:以 GNUPGHOME 模拟"操作者已导入发布公钥"
    export GNUPGHOME=$TEST_GNUPGHOME
}

sign_detach() {
    gpg --homedir "$TEST_GNUPGHOME" --batch --pinentry-mode loopback \
        --passphrase '' --detach-sign "$1" >/dev/null 2>&1
}

# mk_images_dir <dir> [with_vbmeta] [rootfs_bytes] — 现场签出的合法三件套
# (02-01 契约布局;rootfs_bytes 供 S8 传输上限场景放大镜像)
mk_images_dir() {
    local d=$1 withvb=${2:-no} rootfs_bytes=${3:-65536} kind f
    mkdir -p "$d"
    head -c 65536 /dev/urandom >"$d/boot.img"
    xz -0 -c "$d/boot.img" >"$d/boot.img.xz"
    rm -f "$d/boot.img"
    head -c "$rootfs_bytes" /dev/urandom >"$d/rootfs.img"
    xz -0 -c "$d/rootfs.img" >"$d/rootfs.img.xz"
    rm -f "$d/rootfs.img"
    if [ "$withvb" = yes ]; then
        head -c 4096 /dev/urandom >"$d/vbmeta.img"
        xz -0 -c "$d/vbmeta.img" >"$d/vbmeta.img.xz"
        rm -f "$d/vbmeta.img"
    fi
    for f in "$d"/*.img.xz; do
        (cd "$d" && sha256sum "$(basename "$f")" >"$(basename "$f").sha256")
        sign_detach "$f"
    done
    printf 'ArchMage flash-test assets\nFINGERPRINT: %s\nEPHEMERAL: false\n' \
        "$TEST_FPR" >"$d/FINGERPRINT.txt"
}

# make_backup <tmpdir> <serial> — 用 mock adb 跑真的 10-backup-persist.sh,
# rc 落在 <tmpdir>/backup.rc,产物在 <tmpdir>/bk/<serial>/
make_backup() {
    local tmp=$1 sn=$2
    (
        export MOCK_LOG="$tmp/backup-mock.log" MOCK_SERIAL="$sn"
        if bash "$OP6_DIR/10-backup-persist.sh" --backup-dir "$tmp/bk" \
            >"$tmp/backup.out" 2>"$tmp/backup.err"; then
            echo 0 >"$tmp/backup.rc"
        else
            echo $? >"$tmp/backup.rc"
        fi
    )
}

prime_00_state() { # <bk-root> <serial>
    mkdir -p "$1/$2"
    printf '00-unlock done unlock_ability=1\n' >"$1/$2/.flash-state"
}

# ---------------------------------------------------------------- 语法门
for f in "$OP6_DIR"/*.sh "$TESTS_DIR"/*.sh; do
    if ! bash -n "$f"; then
        note "FATAL: bash -n 失败: $f"
        exit 1
    fi
done

setup_bin
setup_gpg
IMAGES=$RESULTS/images
mk_images_dir "$IMAGES"
note "测试台就绪: results=$RESULTS  fingerprint=${TEST_FPR:0:16}…"

# ================================================================ S1
s1() {
    scenario "S1 无 00 层状态且无备份 → flash-all 退 2,首刷仪式指引,零次 flash/erase"
    local tmp=$RESULTS/S1
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN1
    : >"$MOCK_LOG"
    run_cmd "$tmp" bash "$OP6_DIR/flash-all.sh" --backup-dir "$tmp/bk" --images-dir "$IMAGES"
    assert_rc "S1 flash-all 退 2(仪式未记录)" 2 "$RUN_RC"
    assert_contains "S1 stderr 含首刷仪式指引" "$tmp/last.err" "首刷仪式"
    assert_contains "S1 stderr 指向 00-unlock" "$tmp/last.err" "00-unlock.sh --i-accept-data-wipe"
    assert_contains "S1 stderr 指向 10-backup" "$tmp/last.err" "10-backup-persist.sh"
    assert_eq "S1 零次 fastboot flash/erase 调用" "0" "$(mock_log_count ' (flash|erase) ')"
}

# ================================================================ S1b
s1b() {
    scenario "S1b 00 层状态在档但备份缺失 → 同样退 2,零次 flash/erase"
    local tmp=$RESULTS/S1b
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN1B
    : >"$MOCK_LOG"
    prime_00_state "$tmp/bk" SN1B
    run_cmd "$tmp" bash "$OP6_DIR/flash-all.sh" --backup-dir "$tmp/bk" --images-dir "$IMAGES"
    assert_rc "S1b flash-all 退 2(无有效备份)" 2 "$RUN_RC"
    assert_contains "S1b stderr 指向 10-backup-persist.sh" "$tmp/last.err" "10-backup-persist.sh"
    assert_eq "S1b 零次 fastboot flash/erase 调用" "0" "$(mock_log_count ' (flash|erase) ')"
}

# ================================================================ S2
s2() {
    scenario "S2 伪造/损坏的备份(manifest sha256 与磁盘不符)→ 拒刷退 2"
    local tmp=$RESULTS/S2
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN2
    : >"$MOCK_LOG"
    make_backup "$tmp" SN2
    assert_rc "S2 前置: mock 备份成功" 0 "$(cat "$tmp/backup.rc")"
    prime_00_state "$tmp/bk" SN2
    printf 'TAMPERED\n' >>"$tmp/bk/SN2/persist.img"   # 破坏 persist 分区镜像
    run_cmd "$tmp" bash "$OP6_DIR/flash-all.sh" --backup-dir "$tmp/bk" --images-dir "$IMAGES" --yes
    assert_rc "S2 flash-all 退 2(sha256 不符)" 2 "$RUN_RC"
    assert_contains "S2 stderr 点名 persist 分区" "$tmp/last.err" "persist"
    assert_contains "S2 stderr 指示重跑 10-backup" "$tmp/last.err" "10-backup-persist.sh"
    assert_eq "S2 零次 fastboot flash/erase 调用" "0" "$(mock_log_count ' (flash|erase) ')"
}

# ================================================================ S3
s3() {
    scenario "S3 mock 备份仪式:五分区 manifest 齐、sha256 可独立复验、幂等"
    local tmp=$RESULTS/S3
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN3
    : >"$MOCK_LOG"
    make_backup "$tmp" SN3
    assert_rc "S3 10-backup 退出码 0" 0 "$(cat "$tmp/backup.rc")"
    local mf=$tmp/bk/SN3/manifest.json
    jq -e '.schema_version == 1 and .serial == "SN3" and
           (.partitions | length) == 5 and
           ([.partitions[].name] | sort) == (["fsc","fsg","modemst1","modemst2","persist"] | sort) and
           ([.partitions[].sha256] | length) == 5 and
           all(.partitions[]; (.size > 0) and (.file | endswith(".img")))' \
        "$mf" >/dev/null 2>&1 &&
        ok "S3 manifest schema/五分区/字段齐" ||
        bad "S3 manifest 校验失败: $mf"
    # sha256 独立复验:重新经 mock adb 取流并哈希,必须与 manifest 一致
    if [ -f "$mf" ]; then
        local p want got all_match=yes
        while IFS=$'\t' read -r p want; do
            got=$(adb exec-out dd "if=/dev/block/by-name/$p" 2>/dev/null | sha256sum | cut -d' ' -f1)
            [ "$got" = "$want" ] || { all_match=no; bad "S3 $p sha256 复验失败($got ≠ $want)"; }
        done < <(jq -r '.partitions[] | [.name, .sha256] | @tsv' "$mf")
        [ "$all_match" = yes ] && ok "S3 五分区 sha256 全部可独立复验"
    fi
    assert_file "S3 归档 persist.tar.gz 存在" "$tmp/bk/SN3/persist.tar.gz"
    local members
    members=$(tar -tzf "$tmp/bk/SN3/persist.tar.gz" | sort | tr '\n' ' ')
    assert_eq "S3 tar 含五成员" "fsc.img fsg.img modemst1.img modemst2.img persist.img " "$members"
    assert_contains "S3 输出提醒离线第二副本" "$tmp/backup.out" "离线第二副本"
    # 幂等:重跑覆盖同 serial 目录,仍绿
    make_backup "$tmp" SN3
    assert_rc "S3 幂等重跑退出码 0" 0 "$(cat "$tmp/backup.rc")"
}

# ================================================================ S4
s4() {
    scenario "S4 00 状态 + 有效备份 + 合法镜像 → 过门进入层调度(Task1 桩期:缺失层上报 6;层在位:全链完成)"
    local tmp=$RESULTS/S4
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN4
    : >"$MOCK_LOG"
    make_backup "$tmp" SN4
    prime_00_state "$tmp/bk" SN4
    run_cmd "$tmp" bash "$OP6_DIR/flash-all.sh" --backup-dir "$tmp/bk" --images-dir "$IMAGES" --yes
    assert_contains "S4 stderr 备份门已通过" "$tmp/last.err" "备份校验通过"
    assert_contains "S4 stderr 镜像校验已通过" "$tmp/last.err" "镜像校验通过"
    if [ -f "$OP6_DIR/20-flash-boot.sh" ]; then
        # Task 2 之后:层在位,过门即全链完成(S9 的正例在此层叠复证)
        assert_rc "S4 flash-all 过门后全链成功" 0 "$RUN_RC"
        assert_contains "S4 状态含 40 层" "$tmp/bk/SN4/.flash-state" "40-set-slot done"
    else
        # Task 1 桩期:按编号探测缺失 → 层未实现,零次设备写
        assert_rc "S4 flash-all 上报缺失层(非零)" 6 "$RUN_RC"
        assert_contains "S4 stderr 报层未实现" "$tmp/last.err" "层未实现"
        assert_contains "S4 stderr 点名 20-flash-boot" "$tmp/last.err" "20-flash-boot"
        assert_eq "S4 零次 fastboot flash/erase 调用(层未实现,未触设备写)" "0" "$(mock_log_count ' (flash|erase) ')"
    fi
}

# ================================================================ S5
s5() {
    scenario "S5 无设备(工具在但设备缺席 / 工具缺失)→ 33 + stderr 首行 DEVICE_REQUIRED"
    local tmp=$RESULTS/S5
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN5
    : >"$MOCK_LOG"
    export MOCK_NO_DEVICE=1
    run_cmd "$tmp" bash "$OP6_DIR/10-backup-persist.sh" --backup-dir "$tmp/bk"
    assert_rc "S5a 10-backup(adb 无设备)退 33" 33 "$RUN_RC"
    assert_first_line_prefix "S5a stderr 首行 DEVICE_REQUIRED" "$tmp/last.err" "DEVICE_REQUIRED:"
    run_cmd "$tmp" bash "$OP6_DIR/flash-all.sh" --backup-dir "$tmp/bk" --images-dir "$IMAGES"
    assert_rc "S5b flash-all(fastboot 无设备)退 33" 33 "$RUN_RC"
    assert_first_line_prefix "S5b stderr 首行 DEVICE_REQUIRED" "$tmp/last.err" "DEVICE_REQUIRED:"
    unset MOCK_NO_DEVICE
    # 工具缺失路径:本宿主无 fastboot/adb,用原始 PATH(无 mock)复现
    run_cmd "$tmp" env PATH="$ORIG_PATH" bash "$OP6_DIR/10-backup-persist.sh" --backup-dir "$tmp/bk"
    assert_rc "S5c 无 adb 工具退 33" 33 "$RUN_RC"
    assert_first_line_prefix "S5c stderr 首行 DEVICE_REQUIRED" "$tmp/last.err" "DEVICE_REQUIRED:"
}

# ================================================================ S6
s6() {
    scenario "S6 00-unlock:无旗标退 5;有旗标在无备份状态下可独立成功并强指引立即备份(解锁→备份物理顺序,防死锁)"
    local tmp=$RESULTS/S6
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN6
    : >"$MOCK_LOG"
    run_cmd "$tmp" bash "$OP6_DIR/00-unlock.sh" --backup-dir "$tmp/bk"
    assert_rc "S6a 00-unlock 无旗标退 5" 5 "$RUN_RC"
    assert_contains "S6a stderr 警示数据全清" "$tmp/last.err" "用户数据全清"
    assert_contains "S6a stderr 指示旗标" "$tmp/last.err" "--i-accept-data-wipe"
    assert_eq "S6a 零次 flashing unlock 调用" "0" "$(mock_log_count 'flashing unlock')"
    run_cmd "$tmp" bash "$OP6_DIR/00-unlock.sh" --backup-dir "$tmp/bk" --i-accept-data-wipe
    assert_rc "S6b 00-unlock 有旗标(无备份)独立成功" 0 "$RUN_RC"
    assert_contains "S6b 输出强指引 10-backup-persist.sh" "$tmp/last.out" "10-backup-persist.sh"
    assert_eq "S6b 发起 flashing unlock 一次" "1" "$(mock_log_count 'flashing unlock')"
    assert_contains "S6b 层状态记录 00-unlock done" "$tmp/bk/SN6/.flash-state" "00-unlock done"
    assert_contains "S6b 层状态留档 unlock_ability" "$tmp/bk/SN6/.flash-state" "unlock_ability=1"
}

# ================================================================ S7
s7() {
    scenario "S7 20 层:erase dtbo(×3)先于一切 flash;boot_a/boot_b 双 slot;vbmeta 两向"
    local tmp=$RESULTS/S7
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN7
    : >"$MOCK_LOG"
    make_backup "$tmp" SN7
    assert_rc "S7 前置: mock 备份成功" 0 "$(cat "$tmp/backup.rc")"
    mk_images_dir "$tmp/imgs" yes
    run_cmd "$tmp" bash "$OP6_DIR/20-flash-boot.sh" --backup-dir "$tmp/bk" --images-dir "$tmp/imgs"
    assert_rc "S7 20 层(有 vbmeta)退出码 0" 0 "$RUN_RC"
    # 顺序门禁:任何 flash 调用都不得先于第一个 erase dtbo
    if awk '/erase dtbo/{e=1} / flash /{if(!e) exit 1}' "$tmp/mock.log"; then
        ok "S7 erase dtbo 先于一切 flash 调用"
    else
        bad "S7 顺序门禁失效:存在先于 erase dtbo 的 flash 调用"
    fi
    assert_eq "S7 erase dtbo 三次(当前+dtbo_a+dtbo_b)" "3" "$(mock_log_count 'erase dtbo')"
    assert_eq "S7 boot_a 写入一次" "1" "$(mock_log_count 'flash boot_a')"
    assert_eq "S7 boot_b 写入一次" "1" "$(mock_log_count 'flash boot_b')"
    assert_eq "S7 vbmeta 带旗标写入一次" "1" "$(mock_log_count 'disable-verity --disable-verification flash vbmeta')"
    assert_contains "S7 层状态记录 20-flash-boot done" "$tmp/bk/SN7/.flash-state" "20-flash-boot done"
    # 无 vbmeta 变体:跳过并说明,不失败
    local tmp2=$RESULTS/S7b
    mkdir -p "$tmp2"
    export MOCK_LOG="$tmp2/mock.log"
    : >"$MOCK_LOG"
    make_backup "$tmp2" SN7
    mk_images_dir "$tmp2/imgs" no
    run_cmd "$tmp2" bash "$OP6_DIR/20-flash-boot.sh" --backup-dir "$tmp2/bk" --images-dir "$tmp2/imgs"
    assert_rc "S7b 20 层(无 vbmeta)退出码 0" 0 "$RUN_RC"
    assert_contains "S7b stderr 打印跳过原因" "$tmp2/last.err" "跳过 vbmeta"
    assert_eq "S7b 零次 vbmeta 写入" "0" "$(mock_log_count 'flash vbmeta')"
}

# ================================================================ S8
s8() {
    scenario "S8 30 层:无 --yes 拒执行(退 5);超传输上限退 7;正常 --yes 成功"
    local tmp=$RESULTS/S8
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN8
    : >"$MOCK_LOG"
    make_backup "$tmp" SN8
    mk_images_dir "$tmp/imgs" no
    run_cmd "$tmp" bash "$OP6_DIR/30-flash-rootfs.sh" --backup-dir "$tmp/bk" --images-dir "$tmp/imgs"
    assert_rc "S8a 30 层无 --yes 退 5" 5 "$RUN_RC"
    assert_contains "S8a stderr 指示 --yes" "$tmp/last.err" "--yes"
    assert_contains "S8a 打印将覆盖的分区" "$tmp/last.out" "userdata"
    assert_eq "S8a 零次 flash userdata" "0" "$(mock_log_count 'flash userdata')"
    # 超上限:2 MiB 镜像 vs 1 MiB 检查值 → 退 7,上游指引,零写入
    local tmp2=$RESULTS/S8b
    mkdir -p "$tmp2"
    export MOCK_LOG="$tmp2/mock.log"
    : >"$MOCK_LOG"
    make_backup "$tmp2" SN8
    mk_images_dir "$tmp2/imgs" no 2097152
    run_cmd "$tmp2" env ARCHMAGE_FLASH_MAX_TRANSFER_MB=1 \
        bash "$OP6_DIR/30-flash-rootfs.sh" --backup-dir "$tmp2/bk" --images-dir "$tmp2/imgs" --yes
    assert_rc "S8b 30 层超上限退 7" 7 "$RUN_RC"
    assert_contains "S8b stderr 给上游指引" "$tmp2/last.err" "fastboot getvar max-download-size"
    assert_eq "S8b 零次 flash userdata" "0" "$(mock_log_count 'flash userdata')"
    # 正常路径:--yes → 成功写入 + 层状态
    local tmp3=$RESULTS/S8c
    mkdir -p "$tmp3"
    export MOCK_LOG="$tmp3/mock.log"
    : >"$MOCK_LOG"
    make_backup "$tmp3" SN8
    mk_images_dir "$tmp3/imgs" no
    run_cmd "$tmp3" bash "$OP6_DIR/30-flash-rootfs.sh" --backup-dir "$tmp3/bk" --images-dir "$tmp3/imgs" --yes
    assert_rc "S8c 30 层 --yes 成功" 0 "$RUN_RC"
    assert_eq "S8c flash userdata 一次" "1" "$(mock_log_count 'flash userdata')"
    assert_contains "S8c 层状态记录 30-flash-rootfs done" "$tmp3/bk/SN8/.flash-state" "30-flash-rootfs done"
}

# ================================================================ S9
s9() {
    scenario "S9 全链 flash-all(mock):备份门→40 层状态完成;中断重跑仅执行剩余层(SKIP)"
    local tmp=$RESULTS/S9
    mkdir -p "$tmp"
    export MOCK_LOG="$tmp/mock.log" MOCK_SERIAL=SN9
    : >"$MOCK_LOG"
    make_backup "$tmp" SN9
    prime_00_state "$tmp/bk" SN9
    mk_images_dir "$tmp/imgs" yes
    run_cmd "$tmp" bash "$OP6_DIR/flash-all.sh" --backup-dir "$tmp/bk" --images-dir "$tmp/imgs" --yes
    assert_rc "S9a 全链退出码 0" 0 "$RUN_RC"
    local state=$tmp/bk/SN9/.flash-state
    assert_contains "S9a 状态含 20 层" "$state" "20-flash-boot done"
    assert_contains "S9a 状态含 30 层" "$state" "30-flash-rootfs done"
    assert_contains "S9a 状态含 40 层" "$state" "40-set-slot done"
    if awk '/erase dtbo/{e=1} / flash /{if(!e) exit 1}' "$tmp/mock.log"; then
        ok "S9a 全链中 erase dtbo 先于一切 flash"
    else
        bad "S9a 全链顺序门禁失效"
    fi
    assert_eq "S9a set_active 一次" "1" "$(mock_log_count 'set_active')"
    # 人为中断:从状态文件抹掉 30/40 完成行,重跑只应执行剩余层
    sed -i '/^30-flash-rootfs done/d;/^40-set-slot done/d' "$state"
    export MOCK_LOG="$tmp/mock-rerun.log"
    : >"$MOCK_LOG"
    run_cmd "$tmp" bash "$OP6_DIR/flash-all.sh" --backup-dir "$tmp/bk" --images-dir "$tmp/imgs" --yes
    assert_rc "S9b 中断重跑退出码 0" 0 "$RUN_RC"
    assert_contains "S9b stdout SKIP 已完成的 20 层" "$tmp/last.out" "SKIP 20-flash-boot"
    assert_eq "S9b 重跑零次 erase dtbo(20 层被跳过)" "0" "$(mock_log_count 'erase dtbo')"
    assert_eq "S9b 重跑零次 flash boot(20 层被跳过)" "0" "$(mock_log_count 'flash boot')"
    assert_eq "S9b 重跑 flash userdata 一次(30 层补做)" "1" "$(mock_log_count 'flash userdata')"
    assert_eq "S9b 重跑 set_active 一次(40 层补做)" "1" "$(mock_log_count 'set_active')"
    assert_contains "S9b 状态恢复含 40 层" "$state" "40-set-slot done"
}

# ================================================================ S10
s10() {
    scenario "S10 分区拒绝断言两向:清单内(xbl/dtbo/modemst1/persist/xbl_a)退 3;允许面(boot_a/userdata/vbmeta)放行"
    local tmp=$RESULTS/S10
    mkdir -p "$tmp"
    local p rc bad_count=0
    for p in xbl xbl_config modem modemst1 modemst2 abl tz hyp rpm keymaster devinfo persist fsc fsg dtbo xbl_a xbl_b dtbo_a; do
        ( exec 2>"$tmp/assert.err"; bash -c 'source "$1"; archmage_flash::assert_flash_target "$2"' _ "$OP6_DIR/lib.sh" "$p" )
        rc=$?
        if [ "$rc" -ne 3 ]; then
            bad_count=$((bad_count + 1))
            bad "S10 拒绝清单分区 $p 应退 3, 实得 rc=$rc"
        fi
    done
    [ "$bad_count" -eq 0 ] && ok "S10 全部拒绝清单分区(含 slot 后缀)退 3"
    assert_contains "S10 拒绝理由指向 PITFALLS 3" "$tmp/assert.err" "拒绝刷写分区"
    for p in boot boot_a boot_b vbmeta userdata system; do
        if bash -c 'source "$1"; archmage_flash::assert_flash_target "$2"' _ "$OP6_DIR/lib.sh" "$p" 2>/dev/null; then
            ok "S10 允许面分区 $p 放行"
        else
            bad "S10 允许面分区 $p 不应被拒绝"
        fi
    done
}

# ---------------------------------------------------------------- 执行
s1
s1b
s2
s3
s4
s5
s6
s7
s8
s9
s10

# ---------------------------------------------------------------- 汇总
printf '\n' | tee -a "$RESULTS/summary.log"
note "通过断言: $PASS  失败断言: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    note "失败清单:"
    for f in "${FAILED[@]}"; do note "  - $f"; done
    note "结果目录: $RESULTS"
    exit 1
fi
note "场景矩阵全绿。结果目录: $RESULTS"
exit 0
