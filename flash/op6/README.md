# flash/op6 — OnePlus 6(enchilada)分层刷机 harness

编号分层脚本(每层独立可执行、幂等、可从任意失败层重入)+ `flash-all.sh`
编排 + 首刷前**强制备份仪式** + EDL 9008 救援指引。全部拒绝/顺序逻辑经
`tests/run-tests.sh` 的 mock-fastboot/mock-adb 场景矩阵(S1–S10)在无真机
环境回归,CI 门禁 `.github/workflows/flash-tests.yml`。

规格来源:PITFALLS 3(OP6 变砖路径)、ARCHITECTURE Anti-Pattern 3
(单一大脚本 → 编号分层 + 可恢复)。

## 前置条件

| 项 | 说明 |
| --- | --- |
| OnePlus 6 真机 + 数据线 | 建议囤 2 台(一台当救援演练台);**EDL 必须用 USB 2.0 口/线**(USB 3.x 会 Sahara Communication Failed) |
| android-tools(fastboot/adb) | Arch: `sudo pacman -S android-tools` |
| TWRP 镜像 | 备份需要 recovery 环境;获取:pmOS wiki oneplus-enchilada(Installation 页) |
| nightly 镜像资产 | `archmage-op6-phosh-YYYYMMdd-{boot,rootfs}.img.xz` 三件套(见下文取像校验) |
| gh CLI(取像用) | Arch: `sudo pacman -S github-cli`;仓库无 origin remote 时 `export ARCHMAGE_GH_REPO=owner/repo` |

设备进 fastboot 的入口:关机 → 按住 **音量+ 与 音量−** → 插 USB。

## 备份仪式(一页纸:为什么 persist/modemst 是命根子)

`persist` 分区存着**相机校准、指纹/传感器校准**;`modemst1/modemst2`
存着**基带/IMEI 状态**;`fsc/fsg` 是基带文件系统副本。这些是每台设备
**出厂独有的数据,丢了不能从任何镜像恢复** —— 而 OP6 的 EDL 救援
(MSM DownloadTool / edl)恢复流程**会 wiping 这五个分区**。也就是说:

> 没有备份的设备走一次 EDL,得到的不是"救回来的手机",是"能开机但
> 没基带、相机漂移的板子"。PITFALLS 3 把它列为不可接受代价。

所以本 harness 把铁律做成机器执行的事实:

- `10-backup-persist.sh`(设备在 TWRP,adb 模式)只读导出五分区 →
  `backups/<序列号>/persist.tar.gz` + `manifest.json`(每分区 sha256/大小/
  时间/工具版本)。幂等,重跑覆盖同序列号目录。
- 所有刷写层与 `flash-all.sh` 开头都过 `lib.sh::require_backup` 拒刷门:
  没有该序列号的**通过 sha256 校验的** manifest,任何 flash/erase 都不会
  发生(退 2;mock 场景 S1/S1b/S2 两向证明:无备份/坏 manifest → 零次设备写)。
- `backups/` 整体 gitignore —— 设备校准数据绝不入库;请把
  `persist.tar.gz + manifest.json` 复制到**离线第二副本**(另一台机器/加密盘)。

物理顺序(不可调换,防死锁):解锁(00)→ `fastboot boot twrp.img` →
备份(10)→ 刷写(20/30/40)。锁定 bootloader 拒绝 `fastboot boot`,所以
00-unlock 是唯一不挂备份门的层,替代闸是 `--i-accept-data-wipe` 显式旗标
+ 解锁完成后"立即执行 10-backup-persist.sh"强指引(S6 场景锁定)。

## 分层表(每层做什么 / 失败从哪重入)

| 层 | 做什么 | 关键防线 | 失败重入 |
| --- | --- | --- | --- |
| `00-unlock.sh` | 解锁 bootloader(设备侧音量键确认;`get_unlock_ability` 留档) | `--i-accept-data-wipe` 旗标(缺 → 退 5);中文警示(清数据/备份紧随/回锁风险) | 重跑即可;状态幂等 |
| `10-backup-persist.sh` | 五分区只读导出 + manifest | 产物自过拒刷门;fastboot 模式直接拒绝并指向 `fastboot boot twrp.img` | 重跑覆盖同序列号目录 |
| `20-flash-boot.sh` | **erase dtbo/dtbo_a/dtbo_b**(先于一切 flash)→ boot 写 **boot_a + boot_b 双 slot** →(有 vbmeta 资产时)`--disable-verity --disable-verification` 写 vbmeta,无则打印原因跳过 | erase 先于 flash 是规格(S7);每个 flash 目标过 `assert_flash_target` | 直接重跑(幂等);双 slot 总留一个可启动 |
| `30-flash-rootfs.sh` | rootfs.img → userdata | 覆盖前打印分区+镜像大小;`--yes` 旗标(退 5);超 fastboot 上限退 7 只给上游指引(`ARCHMAGE_FLASH_MAX_TRANSFER_MB` 可调,默认 512 MiB) | 直接重跑 |
| `40-set-slot.sh` | 非当前 slot `set_active`(默认自动取反)→ 拔线观察提示 → reboot | 同样挂备份门 | 重跑(set_active 幂等) |
| `flash-all.sh` | 编排 20→30→40 | 首刷仪式检查(00 状态缺失 → 退 2 + 指引)→ **require_backup 拒刷门** → 镜像 sha256+gpg 校验 → `--yes` 确认 → 层调度 | 层状态在 `backups/<serial>/.flash-state`;**重跑 flash-all.sh 即从失败层继续**,已完成层 SKIP(S9) |
| `rescue.sh` | EDL 9008 检测 + 救援指引 + 备份校验后的恢复序列 | 坏备份不进恢复流程;不提供引导链分区写入指引 | 见下页 |

分区拒绝清单(`lib.sh::assert_flash_target`,退 3):
`xbl xbl_config modem modemst1 modemst2 abl tz hyp rpm keymaster devinfo
persist fsc fsg dtbo`(含 `_a`/`_b` 后缀变体)。dtbo 只允许 erase、绝不允许
flash。任何刷写层对清单内目标的 flash 参数直接熔断(S10 两向回归)。

退出码契约:0 成功;1 环境/用法;2 备份门或首刷仪式;3 分区拒绝清单;
4 镜像校验(sha256/gpg);5 缺确认旗标;6 层未实现/编排错误;7 超传输上限;
**33 DEVICE_REQUIRED(设备/工具缺席 —— 记 WINDOWS.md 顺延,非脚本缺陷)**。

## 取像与校验(nightly Release)

`flash-all.sh` 默认经官方 gh CLI 从 Release `nightly` 取像(资产契约来自
02-01:`archmage-op6-phosh-YYYYMMdd-{boot,rootfs}.img.xz` + `.sha256` +
`.sig` + `FINGERPRINT.txt`),**sha256 校验 + gpg 验签(签名者指纹必须等于
FINGERPRINT.txt 声明值)双验通过后才允许进入任何刷写层**(退 4 不触
fastboot;`FINGERPRINT.txt` 标记 EPHEMERAL 时给显著警告)。手工校验等价于:

```bash
export ARCHMAGE_GH_REPO=<owner>/<repo>          # 仓库无 origin remote 时
gh release download nightly -R "$ARCHMAGE_GH_REPO" \
  -p 'archmage-op6-phosh-*-boot.img.xz{,.sha256,.sig}' \
  -p 'archmage-op6-phosh-*-rootfs.img.xz{,.sha256,.sig}' -p 'FINGERPRINT.txt'
sha256sum -c archmage-op6-phosh-*-boot.img.xz.sha256
gpg --verify archmage-op6-phosh-*-boot.img.xz.sig archmage-op6-phosh-*-boot.img.xz
  # 需先导入发布公钥(指纹见 FINGERPRINT.txt,与项目公示指纹核对)
```

**`--images-dir` 边界**:该参数仅供 mock 测试台与已预取(离线校验过的)
目录旁路**下载**步骤;sha256/gpg 校验对目录内文件照常执行,不豁免。
真机流程不要用它 —— 默认路径(`fetch_image`)才是发布侧签名的完整链路。

## EDL 救援(一页纸)

**何时需要**:fastboot 都进不去(dtbo 未 erase 即刷 / slot 混淆 / 误碰引导
链分区)。入口:关机 → 按住 Vol+ & Vol− → 插 USB(震动/白灯)→
`lsusb` 出现 `05c6:9008`(Qualcomm QDLoader 9008)。**必须 USB 2.0**。

```bash
bash flash/op6/rescue.sh                # 检测 + 分步指引(bkerler/edl 安装、
                                        # firehose/rawprogram 出处:pmOS wiki
                                        # oneplus-enchilada/Unbricking + XDA)
bash flash/op6/rescue.sh --serial <SN>  # 备份 manifest 校验通过后,才打印
                                        # persist/modemst 的 edl/dd 恢复序列
bash flash/op6/rescue.sh --check        # 环境自检(CI/无真机冒烟;退 0/1)
```

硬边界:rescue.sh **不提供**对 xbl/xbl_config/modem/abl/tz 的任何写入指引
—— 那是硬砖与校准毁灭的来源(PITFALLS 3);引导链恢复只能走带签名校验
的官方 MSM 流程,并由人逐字核对 pmOS wiki / XDA 文档。

**演练要求(PITFALLS "Looks Done But Isn't")**:每批设备至少完整演练
一次 EDL 恢复并留档(manifest sha256、时间、恢复后基带/IMEI 表现)。
"文档写了"不等于"恢复过"。

## mock 测试台(无真机回归)

```bash
bash flash/op6/tests/run-tests.sh       # S1–S10 场景矩阵,退出码即门禁
```

`tests/mock-fastboot.sh` / `tests/mock-adb.sh` 是 PATH 前置的假二进制
(`tests/fastboot`、`tests/adb` 符号链接;每次调用记录到 `$MOCK_LOG`,
分区数据按 (分区, 序列号) 确定性生成,sha256 可复算)。场景矩阵证明:
无备份/坏 manifest 拒刷且零次设备写(S1/S1b/S2)、备份五分区可复验(S3)、
过门进入层调度(S4)、无设备 33 + stderr 首行 `DEVICE_REQUIRED`(S5)、
00 层旗标与解锁→备份顺序(S6)、erase-before-flash 与双 slot 与 vbmeta
两向(S7)、--yes 与传输上限(S8)、中断重跑 SKIP(S9)、分区拒绝清单两向
(S10)。mock 仅存在于 `tests/` 目录且只由测试台接线(T-02-09:不可能混入
真机路径造成假绿)。
