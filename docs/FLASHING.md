# 刷机指南(OnePlus 6,用户视角)

> **本文档覆盖什么**:从公开 nightly 资产出发,在一台 OnePlus 6(enchilada)
> 上完成备份与刷机的完整步骤,以及每一步失败后从哪里重入。
> **本文档不承诺什么**:分层脚本与备份/救援链的**真机执行面尚未在真机上
> 执行过**(device-deferred,退出码 33/DEVICE_REQUIRED 约定顺延,账目见
> `.planning/WINDOWS.md` #16/#17/#18)。文档步骤以 harness 已验证的逻辑为
> 准(mock 场景矩阵 S1–S10 回归 + CI 门禁);**真机首刷请同时对照
> [`test/on-device/op6-checklist.md`](../test/on-device/op6-checklist.md)**
> ——那是唯一在真机上算数的验收。完整的脚本级细节见
> [`flash/op6/README.md`](../flash/op6/README.md)(本文是它的用户入口)。

## 1. 资产获取与校验

刷机只认 nightly Release 的三件套(镜像 + sha256 + 独立签名),外加指纹
清单。**校验不过就不许进任何刷写层**——脚本层也是这么做的(校验失败退 4,
不触 fastboot):

```bash
export ARCHMAGE_GH_REPO=<owner>/<repo>     # 仓库无 origin remote 时需要
gh release download nightly -R "$ARCHMAGE_GH_REPO" \
  -p 'archmage-op6-phosh-*-boot.img.xz{,.sha256,.sig}' \
  -p 'archmage-op6-phosh-*-rootfs.img.xz{,.sha256,.sig}' \
  -p 'FINGERPRINT.txt' -p 'manifest.json'

sha256sum -c archmage-op6-phosh-*-boot.img.xz.sha256
sha256sum -c archmage-op6-phosh-*-rootfs.img.xz.sha256
gpg --verify archmage-op6-phosh-*-boot.img.xz.sig  archmage-op6-phosh-*-boot.img.xz
gpg --verify archmage-op6-phosh-*-rootfs.img.xz.sig archmage-op6-phosh-*-rootfs.img.xz
  # gpg 需先导入发布公钥:指纹见 FINGERPRINT.txt,与项目公示指纹核对一致
  # 后才导入;FINGERPRINT.txt 标注 EPHEMERAL 时,该签名只证明本次运行自身
  # 的完整性,不构成来源证明(manifest.json 的 ephemeral_key 字段同标记)
jq -r '.tier' manifest.json
```

`manifest.json` 的 `tier` 字段诚实标注验证层级:出厂 OP6 镜像为
`device-pending`(结构已验:Android boot magic + 挂载后的 discipline /
phosh / archmage-cn 断言;**真机启动未被 CI 代验**)。晋升为
`device-verified` 只有一条路:人执真机清单 → 结果 JSON → `device-tier.sh`
校验(见 README「真机验证」节)。

## 2. 前置条件

| 项 | 说明 |
| --- | --- |
| OnePlus 6 真机 + 数据线 | 建议囤 2 台(一台当救援演练台);**EDL 必须用 USB 2.0 口/线**(USB 3.x 会 Sahara Communication Failed) |
| android-tools(fastboot/adb) | Arch 系主机:`sudo pacman -S android-tools` |
| TWRP 镜像 | 备份需要 recovery 环境;获取途径见 pmOS wiki oneplus-enchilada 的 Installation 页 |
| 已校验的 nightly 资产 | 上节三件套 |
| gh CLI | 仅取像用 |

设备进 fastboot 的入口:关机 → 按住 **音量+ 与 音量−** → 插 USB。

## 3. 备份仪式(为什么 persist/modemst 是命根子)

`persist` 存**相机校准、指纹/传感器校准**;`modemst1/modemst2` 存**基带 /
IMEI 状态**;`fsc/fsg` 是基带文件系统副本。这些是每台设备**出厂独有、丢
了不能从任何镜像恢复**的数据——而 EDL 救援流程**会清掉这五个分区**。没
有备份的设备走一次 EDL,得到的不是"救回来的手机",是"能开机但没基带、
相机漂移的板子"。所以:

- `10-backup-persist.sh`(设备在 TWRP、adb 模式)只读导出五分区 →
  `backups/<序列号>/persist.tar.gz` + `manifest.json`(每分区 sha256 /
  大小 / 时间 / 工具版本)。幂等,重跑覆盖同序列号目录。
- 所有刷写层与 `flash-all.sh` 开头都过 **require_backup 拒刷门**:没有该
  序列号**通过 sha256 校验的** manifest,任何 flash/erase 都不会发生。
- `backups/` 整体不入库;请把 `persist.tar.gz + manifest.json` 复制一份到
  **离线第二副本**(另一台机器/加密盘)。

完整叙述见 [`flash/op6/README.md`](../flash/op6/README.md)「备份仪式」节。

## 4. 分层刷写步骤(00 → 40)

物理顺序不可调换:解锁(00)→ `fastboot boot twrp.img` → 备份(10)→
刷写(20/30/40)。锁定状态的 bootloader 拒绝 `fastboot boot`,所以 00 是
唯一不挂备份门的层(替代闸见下表)。

| 层 | 做什么(一句话) | 失败从哪重入 |
| --- | --- | --- |
| `00-unlock.sh --i-accept-data-wipe` | 解锁 bootloader(设备侧音量键确认;**会清数据**,备份紧随其后) | 重跑即可,状态幂等;缺旗标退 5 |
| `fastboot boot twrp.img` | 进 TWRP recovery(备份的前置环境) | 重跑 |
| `10-backup-persist.sh` | 五分区只读导出 + manifest(过拒刷门自检) | 重跑覆盖同序列号目录 |
| `20-flash-boot.sh` | 先 erase dtbo(规格,先于一切 flash)→ boot 写 boot_a + boot_b 双 slot | 直接重跑(幂等);双 slot 总留一个可启动 |
| `30-flash-rootfs.sh --yes` | rootfs 镜像写入 userdata | 直接重跑;超传输上限退 7 |
| `40-set-slot.sh` | 切换 active slot(默认自动取反)→ 拔线重启 | 重跑(set_active 幂等) |
| `flash-all.sh --yes` | 20→30→40 编排(含镜像校验与拒刷门) | **重跑即从失败层继续**,已完成层 SKIP |

一键编排:`bash flash/op6/flash-all.sh --yes`(镜像默认经 gh 从 nightly
取像并双验通过后才进入层调度;层状态在 `backups/<序列号>/.flash-state`)。
退出码契约:0 成功;2 备份门/首刷仪式;3 分区拒绝清单;4 镜像校验;5 缺
确认旗标;7 超传输上限;33 无设备/工具(约定顺延,非脚本缺陷)。

## 5. 首刷后首次启动检查

| 检查 | 预期 | 对应清单项 |
| --- | --- | --- |
| 重启后数十秒内 | 震动/点亮 → 引导 Logo → **锁屏**出现 | 清单 1.1(`boot-phosh` 门槛项) |
| 上滑解锁 | 进入 Phosh 桌面(出厂无锁屏密码) | 清单 1.2 |
| 锁屏界面 | 只有解锁与**紧急呼叫**两个入口(锁屏不显示任何通知内容,出厂 dconf 锁死) | SAFETY-01/02 |
| 预装应用 | 应用概览可开合、应用可启动返回 | 清单 1.3 |

镜像内置 sshd(QEMU 开发环回已验),但**真机上的 SSH 访问路径未被验证**
(device-deferred),首刷验收以清单为准,不要把 SSH 当真机入口依赖。

## 6. 救援(EDL 9008)与诚实边界

fastboot 都进不去时:关机 → 按住 Vol+ & Vol− → 插 USB(必须 USB 2.0)→
`lsusb` 出现 `05c6:9008` 即 9008 模式。`bash flash/op6/rescue.sh` 给出检测
与分步指引;`--serial <SN>` 在备份 manifest 校验通过后才打印
persist/modemst 的恢复序列。**rescue.sh 不提供引导链分区(xbl/abl/tz 等)
的写入指引**——那是硬砖与校准毁灭的来源。

已知缺口(逐条诚实,不作完成态宣传):

| 缺口 | 状态 | 账目 |
| --- | --- | --- |
| 真机备份(`10-backup-persist.sh` 在真 OP6 + TWRP 上执行) | device-deferred | WINDOWS #16 |
| 真机全链(00→40 到 `40-set-slot` done) | device-deferred | WINDOWS #17 |
| EDL 恢复完整演练(每批设备一次,留档) | device-deferred | WINDOWS #18 |
| OP6 启动链确认(ABL vs u-boot,影响回滚设计) | 待真机 `fastboot getvar all` 留档 | 清单第 0.5 节 |

以上全部需要 OP6 真机在台;硬件就绪后按
[`test/on-device/op6-checklist.md`](../test/on-device/op6-checklist.md) 执行
并把结果 JSON 提交到 `test/on-device/results/`。
