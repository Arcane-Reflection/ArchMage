#!/usr/bin/env bash
# mock-fastboot.sh — OP6 刷机测试台的假 fastboot(T-02-09)。
#
# 只能经 run-tests.sh 以 symlink 暴露为 `fastboot` 并前置 PATH;首行横幅
# 声明它是 mock,绝不可用于真机路径。行为:
#   - 每次调用把完整命令行追加一行到 $MOCK_LOG(顺序断言的数据源);
#   - getvar serialno        → (bootloader) $MOCK_SERIAL
#   - getvar current-slot    → (bootloader) ${MOCK_CURRENT_SLOT:-a}
#   - flashing get_unlock_ability → (bootloader) ${MOCK_UNLOCK_ABILITY:-1}
#   - devices                → 一行设备(MOCK_NO_DEVICE=1 时无设备)
#   - 其余(erase/flash/set_active/reboot/flashing unlock)→ OKAY
#
# 故意不模拟失败语义:测试台的职责是证明调用顺序与拒绝逻辑,不是
# 仿真 fastboot 传输层。

SELF=fastboot
[ -n "${MOCK_LOG:-}" ] && printf '%s %s\n' "$SELF" "$*" >>"$MOCK_LOG"
SERIAL="${MOCK_SERIAL:-MOCKSN0001}"

finished() { printf 'Finished. Total time: 0.001s\n'; exit 0; }

case "$*" in
    devices)
        if [ -z "${MOCK_NO_DEVICE:-}" ]; then
            printf 'List of devices attached\n%s\tfastboot\n' "$SERIAL"
        else
            printf 'List of devices attached\n'
        fi
        exit 0
        ;;
    *'getvar serialno'*)
        printf '(bootloader) %s\n' "$SERIAL"
        finished
        ;;
    *'getvar current-slot'*)
        printf '(bootloader) %s\n' "${MOCK_CURRENT_SLOT:-a}"
        finished
        ;;
    *'flashing get_unlock_ability'*)
        printf '(bootloader) %s\n' "${MOCK_UNLOCK_ABILITY:-1}"
        finished
        ;;
    *'flashing unlock'*)
        printf '(bootloader) VAR not implemented — simulated OKAY\n'
        printf 'OKAY [  0.010s]\n'
        finished
        ;;
    erase' '*)
        printf "Erasing '%s'... OKAY [  0.020s]\n" "$2"
        finished
        ;;
    *' flash '*|flash' '*)
        # 找到 flash 子命令后的分区名(兼容全局旗标在前:
        # --disable-verity --disable-verification flash vbmeta <file>)
        part=""
        prev=""
        for a in "$@"; do
            if [ "$prev" = "flash" ]; then part=$a; break; fi
            prev=$a
        done
        printf "Sending sparse... OKAY [  0.530s]\n"
        printf "Flashing '%s'... OKAY [  0.530s]\n" "${part:-unknown}"
        finished
        ;;
    *set_active' '*)
        printf "Setting current slot to '%s'... OKAY [  0.030s]\n" "${*: -1}"
        finished
        ;;
    reboot)
        printf 'rebooting...\n'
        finished
        ;;
    getvar' '*|*'getvar'*)
        printf '(bootloader) \n'
        finished
        ;;
    *)
        printf 'OKAY [  0.001s]\n'
        finished
        ;;
esac
