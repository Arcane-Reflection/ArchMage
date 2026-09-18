# OnePlus 6(enchilada)真机验证清单

> **本清单所有项 tier = hardware,仅真机可验,CI 永不代验。**
> QEMU 绿 ≠ 真机绿(PITFALLS 4):modem/传感器/触屏/引导链/GPU 在模拟器里
> "完美工作"恰恰掩盖真问题。本清单就是那道只在真机上存在的门。

- **对象**:ArchMage OP6 镜像(`archmage-op6-phosh`,device `sdm845-oneplus-enchilada` 口径以 manifest.json 为准)
- **产出**:填好的结果 JSON(复制 `test/on-device/op6-results-template.json`),提交到 `test/on-device/results/`(约定见 README「真机验证」节)
- **判级**:全部六项执行完毕后,`tools/checks/device-tier.sh` 校验结果并把镜像 manifest 的 `tier` 从 `device-pending` 晋升为 `device-verified`(`boot-phosh` 必须为 pass 才允许晋升)

---

## 第 0 节 前置(开机前的留档)

**本节仅真机可验。**

| # | 步骤 | 预期 | 判定 | 备注 |
| --- | --- | --- | --- | --- |
| 0.1 | 记录序列号:`fastboot getvar serialno`(或机身 SIM 托/包装) | 得到序列号 | ☐ pass ☐ fail | 结果 JSON 的 `serial` 字段 |
| 0.2 | 确认备份在档:`flash/op6/backups/<序列号>/manifest.json` 存在且五分区(persist/modemst1/modemst2/fsc/fsg)sha256 与磁盘一致 | `bash flash/op6/lib.sh` 拒刷门放行(或重跑 `10-backup-persist.sh` 幂等通过) | ☐ pass ☐ fail | 02-02 备份仪式;无备份不得继续刷机 |
| 0.3 | 记录镜像名与校验值:nightly Release 的 `archmage-op6-phosh-YYYYMMdd-{boot,rootfs}.img.xz` + `.sha256` 通过 + `manifest.json` 的 `tier` 当前值 | `sha256sum -c` 通过;`tier == "device-pending"` | ☐ pass ☐ fail | 结果 JSON 的 `image{name,sha256}` 字段 |
| 0.4 | SIM 就绪:已实名、未停机的实体 SIM(移动/联通/电信任一),插入卡槽 | 设置中可见运营商/信号 | ☐ pass ☐ fail | 建议先在原厂系统或另一台手机确认该卡可收发短信 |
| 0.5 | **启动链留档**:`fastboot getvar all > fastboot-getvar-<序列号>.txt` 并归档到本机记录(连同 0.1–0.4 一起) | 输出含 `current-slot`、`slot-successful:*`、bootloader 版本等 | ☐ pass ☐ fail | **关闭 STATE.md 既有 blocker 的输入**:确认本机启动链是 ABL(Android bootloader)还是 u-boot——Phase 3 UPDATE-02 回滚设计依赖此结论;`unlocked:yes` 亦在此确认 |

## 第 1 节 启动至 Phosh 桌面(DEVICE-03)

**本节仅真机可验。**这是 tier 晋升的门槛项(check id `boot-phosh`)。

| # | 步骤 | 预期 | 判定 | 备注 |
| --- | --- | --- | --- | --- |
| 1.1 | 按 02-02 流程刷机(`flash-all.sh --yes`),完成后拔线观察设备重启 | 震动/点亮 → 引导 Logo → 数十秒内出现锁屏 | ☐ pass ☐ fail | 卡 logo/黑屏/循环重启均记 fail 并拍照留档 |
| 1.2 | 上滑/按电源解锁(默认无密码,首次启动) | 可解锁进入 Phosh 桌面 | ☐ pass ☐ fail | |
| 1.3 | 上滑进应用概览,可见预装应用图标;点开任一应用再返回 | 概览手势与应用启动均正常 | ☐ pass ☐ fail | 触屏、GPU(freedreno)在此一并覆盖 |

判定:`boot-phosh` = pass 当且仅当 1.1–1.3 全 pass。

## 第 2 节 短信收发(TELE-01)

**本节仅真机可验。**两个方向各记一条 check(`sms-mo` 本机发出 / `sms-mt` 收到回复)。

| # | 步骤 | 预期 | 判定 | 备注 |
| --- | --- | --- | --- | --- |
| 2.1 | 打开 Chats(或任一短信应用),向另一台手机发送一条短信 | 对方收到,内容完整 | ☐ pass ☐ fail | `sms-mo`(mobile-originated) |
| 2.2 | 用那台手机回复一条 | 本机 Chats 收到并展示 | ☐ pass ☐ fail | `sms-mt`(mobile-terminated);中文内容一并发一条,覆盖 CJK 编码链路 |

判定:双向到达才算短信可用;单方向失败记 fail 并在备注写明方向。

## 第 3 节 移动数据 + APN(TELE-01 / CN-03)

**本节仅真机可验。**

| # | 步骤 | 预期 | 判定 | 备注 |
| --- | --- | --- | --- | --- |
| 3.1 | 确认飞行模式关闭;按 SIM 运营商启用对应 APN 预设(设置 → Mobile Network 选档,或 `nmcli con up "中国移动 (cmnet)"` 等) | 连接激活,状态栏出现移动数据图标 | ☐ pass ☐ fail | 三预设(cmnet/3gnet/ctnet)均 autoconnect=false,必须手动启用 |
| 3.2 | 断开 Wi-Fi(或确认 Wi-Fi 关闭),浏览器打开任一国内站点 | 页面经蜂窝网络加载成功 | ☐ pass ☐ fail | |
| 3.3 | 终端执行 `sudo pacman -Syu`(保持 Wi-Fi 关闭) | 同步/升级走蜂窝成功 | ☐ pass ☐ fail | CN 镜像源(TUNA/USTC)在蜂窝下的实际可达性一并覆盖 |

判定:`mobile-data` = pass 当且仅当 3.1–3.3 全 pass。

## 第 4 节 通话现状(TELE-02,不承诺项)

**本节仅真机可验。**目标是**现状留档**,不是"修好通话"。

| # | 步骤 | 预期 | 判定 | 备注 |
| --- | --- | --- | --- | --- |
| 4.1 | 本机拨出电话至另一台手机 | 记录实际结果(接通/无声/失败) | ☐ pass ☐ fail | 如实记录;失败不影响其他节判定 |
| 4.2 | 另一台手机拨入本机 | 记录实际结果(振铃/接通/无反应) | ☐ pass ☐ fail | |
| 4.3 | 登记上游状态:VoLTE 依赖 postmarketOS pmaports work item #1878(sdm845 IMS 逆向)的进展;国内 2G/3G 大规模退网背景下,无 VoLTE 的 2G 语音回退在多数城市不可用 | 备注栏写明当日结论与引用 | ☐ pass ☐ fail | 「尽力而为、不承诺」:无论 4.1/4.2 结果如何,ArchMage 不承诺语音通话;后续进展跟上游 |

判定:`call-status` = 4.1–4.3 的综合结果(pass = 双向均接通且有质量;fail = 任一方向不可用,备注写明)。

## 第 5 节 应急锁屏(SAFETY-01)

**本节仅真机可验。**每条用例独立判定;这是本项目的立项论点,逐条走完。

| # | 步骤 | 预期 | 判定 | 备注 |
| --- | --- | --- | --- | --- |
| 5.1 | 熄屏后点亮:锁屏上找到紧急呼叫入口 | **一键可达**(锁屏原生入口,无需解锁、无额外层级) | ☐ pass ☐ fail | Phosh 原生紧急呼叫入口;ArchMage 不叠加任何锁屏组件 |
| 5.2 | 进入紧急呼叫拨号界面 | **无任何覆盖层**(无通知横幅、无画报、无弹窗遮挡拨号盘) | ☐ pass ☐ fail | 这是 `show-in-lock-screen=false` + dconf 锁的真机面 |
| 5.3 | 锁屏出现通知(另一台手机发条消息触发)后,再走 5.1 的路径 | 通知不遮挡紧急入口;锁屏不显示任何通知**内容** | ☐ pass ☐ fail | 内容推送在锁屏上默认且锁死关闭 |
| 5.4 | 误触返回用例 A:从锁屏通知下拉/横幅出发 | **一键返回**锁屏或紧急界面 | ☐ pass ☐ fail | |
| 5.5 | 误触返回用例 B:锁屏状态下误触进入设置快速项(若有)/相机等 | **一键返回**锁屏/紧急界面 | ☐ pass ☐ fail | |
| 5.6 | 误触返回用例 C:紧急拨号界面误触返回/取消 | 仍在锁屏,紧急入口依旧一键可达 | ☐ pass ☐ fail | |

判定:`emergency-lockscreen` = pass 当且仅当 5.1–5.6 全 pass;任何一条出现"需要多步才能退回"或"有内容遮挡"即 fail 并拍照。

---

## 执行后:提交结果并晋升 tier

1. 复制 `test/on-device/op6-results-template.json` 为 `test/on-device/results/op6-<序列号>-<YYYYMMDD>.json`,逐项填写(`status` 只能是 `pass`/`fail`/`na`;`notes` 记录备注与照片文件名)。
2. `bash tools/checks/device-tier.sh --results <结果JSON>` 校验(缺项/非法值会列出来并退 1)。
3. 取到该镜像的 `manifest.json`(nightly Release 资产)后:
   `bash tools/checks/device-tier.sh --results <结果JSON> --manifest <manifest.json>`
   —— `boot-phosh=pass` 时 manifest 的 `tier` 被改写为 `device-verified`(附 `verified_by`/`verified_at`/`checks_summary`);否则拒绝晋升退 2。
4. 把晋升后的 manifest 与结果 JSON 一并提交,并按 README「真机验证」节更新 Release 说明。
