#!/usr/bin/env bash
# mock-adb.sh — OP6 刷机测试台的假 adb(T-02-09)。
#
# 只能经 run-tests.sh 以 symlink 暴露为 `adb` 并前置 PATH;首行横幅声明
# 它是 mock,绝不可用于真机路径。行为:
#   - 每次调用把完整命令行追加一行到 $MOCK_LOG;
#   - devices → 一行 device 状态(MOCK_NO_DEVICE=1 时无设备);
#   - get-serialno → $MOCK_SERIAL;
#   - exec-out dd if=/dev/block/by-name/<p>(以及 shell dd 变体)→ 按
#     (分区名, 序列号) 生成确定性数据 —— sha256 可跨运行复算,这正是
#     10-backup-persist.sh 产物可复验的关键。

SELF=adb
[ -n "${MOCK_LOG:-}" ] && printf '%s %s\n' "$SELF" "$*" >>"$MOCK_LOG"
SERIAL="${MOCK_SERIAL:-MOCKSN0001}"

case "$*" in
    devices)
        if [ -z "${MOCK_NO_DEVICE:-}" ]; then
            printf 'List of devices attached\n%s\tdevice\n' "$SERIAL"
        else
            printf 'List of devices attached\n'
        fi
        exit 0
        ;;
    get-serialno)
        printf '%s\n' "$SERIAL"
        exit 0
        ;;
    *dd\ if=*)
        # 提取 if= 路径里的分区名(/dev/block/by-name/<p>)
        part=""
        for a in "$@"; do
            case "$a" in
                if=*) part=${a#if=}; part=${part##*/by-name/} ;;
            esac
        done
        if [ -z "$part" ]; then
            printf 'mock-adb: no if= partition found\n' >&2
            exit 1
        fi
        # 确定性数据:同 (part, serial) → 同 sha256
        awk -v p="$part" -v s="$SERIAL" 'BEGIN{for(i=0;i<128;i++) printf "%s|%s|%04d\n", p, s, i}'
        exit 0
        ;;
    shell*)
        printf '\n'
        exit 0
        ;;
    *)
        printf '\n'
        exit 0
        ;;
esac
