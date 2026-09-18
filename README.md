# ArchMage

> 基于 Arch Linux ARM 的 CN 化开放 Linux 手机系统(overlay-only flavor):Phosh 移动栈 + 出厂 CN 默认值(镜像/NTP/DNS/locale/字体),以"一切皆代码"的方式维护。
>
> An open, CN-localized Arch Linux ARM phone OS: Phosh mobile stack plus factory CN defaults, maintained entirely as code.

**状态 / Status:** Phase 2(OnePlus 6 镜像管线)进行中——`image.yml` 每日镜像流水线(OP6 aarch64 + x86_64 QEMU → 结构门禁 → nightly Release)与本地产线脚本已就绪,首跑待公开仓库创建与推送(见 `.planning/` user_setup);Phase 1 成果(CN 元包 arm64 CI 签名仓库、QEMU 开发环回)持续可用。

技术策略与阶段路线见 [STRATEGY.md](STRATEGY.md);贡献规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 目录结构

| 目录 | 用途 |
| --- | --- |
| `overlay/cn/` | CN 出厂默认元包(pacman 仓库组 `cn`,一包一目录):mirror / net / locale / fonts-meta / APN 预设 `archmage-cn-apn` / 伞包 `archmage-cn` |
| `overlay/phosh/` | Phosh 风味包:`archmage-phosh-safety`(锁屏安全默认,dconf 锁死通知内容不上锁屏) |
| `overlay/device/` | 设备 overlay(Phase 2,OnePlus 6) |
| `overlay/qemu/` | QEMU 虚拟设备包(Phase 1,01-02) |
| `bootstrap/` | kupferbootstrap 配置与镜像构建驱动(02-01;overlay-only,不含 fork) |
| `test/` | QEMU 冒烟测试与 fixtures(01-02 填充;`fixtures/pacman-verify.conf` 已可用) |
| `flash/op6/` | OnePlus 6 分层刷机脚本(Phase 2 填充) |
| `tools/` | 自动化维护工具(Phase 4 填充) |
| `.planning/` | 项目规划文档(GSD) |

## 快速上手(本阶段成果)

前置:Arch 系主机(装 `base-devel`)、`git`、GitHub CLI `gh`(已 `gh auth login`)。

1. **克隆**:

   ```bash
   git clone https://github.com/uMaj35ty/ArchMage.git
   cd ArchMage
   ```

2. **本地构建一个 CN 元包**(`arch=(any)`,x86_64 主机无需交叉环境):

   ```bash
   cd overlay/cn/archmage-cn-mirror
   makepkg -sf --noconfirm
   ls *.pkg.tar.zst
   ```

   注:伞包 `archmage-cn` 依赖本仓库其它元包,请先构建四个叶子包,伞包最后构建(或用 `--nodeps`;CI 内自动按此处理)。

3. **push 触发 CI 并获取签名 staging 仓库**(arm64 runner 构建 + `repo-add -s` 签名):

   ```bash
   gh run watch "$(gh run list --workflow=packages.yml --branch main --limit 1 \
     --json databaseId --jq '.[0].databaseId')" --exit-status
   gh run download -n staging-repo -D /tmp/staging-repo
   gpg --import /tmp/staging-repo/staging-key.asc
   gpg --verify /tmp/staging-repo/cn.db.tar.zst.sig /tmp/staging-repo/cn.db.tar.zst
   bsdtar -tf /tmp/staging-repo/cn.db.tar.zst | grep '/desc'   # 入库的包
   ```

   `staging-repo` 工件内容:`cn.db.tar.zst`、`cn.db.tar.zst.sig`、`staging-key.asc`、`FINGERPRINT.txt`、`*.pkg.tar.zst` 包文件。用 pacman 验证可用 [test/fixtures/pacman-verify.conf](test/fixtures/pacman-verify.conf)。

## CI 行为(`packages.yml`)

| 触发 | 构建范围 | 签名 |
| --- | --- | --- |
| push 到 main(`overlay/**` 或 workflow 变更) | 差量(相对上一次 main tip) | ✅ secrets 密钥(缺失时 ephemeral 回退,显著标注) |
| pull_request(`overlay/**`) | 差量(相对 base) | ❌ 无 secrets,工件 unsigned,仅供审阅 |
| workflow_dispatch | 全量 | 同 main |

要求与配置:

- **仓库必须为 public**:GitHub arm64 runner(`ubuntu-24.04-arm`)免费额度仅限公有仓库。
- **staging 签名密钥**(推荐配置;见 `.planning/phases/01-skeleton-devloop/01-01-PLAN.md` user_setup):仓库创建后,在本机生成并只把公钥指纹公开;私钥经 secrets 注入,stable 级密钥永不进入自动化(STRATEGY §8):

  ```bash
  gpg --quick-generate-key "ArchMage staging" ed25519 sign 0   # 记下指纹
  gpg --armor --export-secret-keys <FPR> | gh secret set GPG_PRIVATE_KEY
  gh secret set GPG_PASSPHRASE        # 若设了口令
  ```

  secrets 未配置期间,main 构建用**仅本次运行有效**的 ephemeral 密钥并在工件与 job summary 显著标注,其签名工件不可被下游消费。

- **签名纪律**(PITFALLS 2):上游 ALARM 仓库 `SigLevel Required DatabaseOptional`(ALARM 不分发签名数据库),自有仓库 `Required`;全仓库禁 `TrustAll`。

## 镜像发布(`image.yml`,nightly)

每日(schedule 03:17 UTC / dispatch / push)产出两套镜像并发布为 GitHub Release **`nightly`**(prerelease):

| Job | 镜像 | 门禁 | tier |
| --- | --- | --- | --- |
| `op6-image`(arm64 runner) | `archmage-op6-phosh-YYYYMMdd-{boot,rootfs}.img.xz`(aarch64,device `sdm845-oneplus-enchilada`) | Android boot magic + loop-mount rootfs 后 shipping-discipline / phosh / archmage-cn 断言(`tools/checks/verify-image.sh`) | `device-pending`(结构已验,真机启动由 02-02/02-03) |
| `qemu-x86_64-image` | `archmage-qemu-x86_64-YYYYMMdd.img.xz` | CI 内无头启动到 SSH 的 smoke 断言集(`test/smoke-x86_64.sh`)+ `verify-image.sh` | `qemu`(CI 已验启动) |

**资产三件套**:每个 `.img.xz` 都伴随同名 `.sha256` 与 `.sig`(detached GPG 签名);外加 `manifest.json`(`name/arch/device/flavour/tier/build_date/sha256/sig_key_fingerprint/ephemeral_key`)与 `FINGERPRINT.txt`。签名密钥策略与 staging 仓库一致:配置了 `GPG_PRIVATE_KEY`/`GPG_PASSPHRASE` secrets 时用持久密钥,否则用**仅本次运行有效**的 ephemeral 密钥并在 `manifest.json`(`ephemeral_key: true`)与 `FINGERPRINT.txt` 双标记 —— 其签名只证明本次运行自身的完整性,不可作为 ArchMage 来源证明。发布保留最近 3 个 dated nightly(`nightly-YYYYMMdd`),移动 `nightly` 标签始终指向最新资产;发布仅用官方 `gh CLI`,无任何第三方 release action。

**校验与使用**:

```bash
# 取像(移动 nightly 标签)+ 校验
gh release download nightly -p 'archmage-qemu-x86_64-*.img.xz' -p '*.sha256' -p '*.sig' \
  -p 'FINGERPRINT.txt' -p 'manifest.json'
sha256sum -c archmage-qemu-x86_64-*.img.xz.sha256
gpg --verify archmage-qemu-x86_64-*.img.xz.sig archmage-qemu-x86_64-*.img.xz
  # gpg 需先导入发布公钥:指纹见 FINGERPRINT.txt(与项目公示的 staging
  # 密钥指纹核对后导入;ephemeral 密钥签名的资产见上段警示)
jq -r '.tier' manifest.json   # qemu = CI 已验启动;device-pending = 结构已验待真机
xz -d archmage-qemu-x86_64-*.img.xz
```

x86_64 开发镜像即 `vm-x86_64.sh` 的官方取像来源(见下节);解压后 `--image` 直接可传。

## 电话栈现状(TELE-01/02)

**验证目标 vs 不承诺项**:

- **短信收发与移动数据**是 Phase 2 的验证目标(真机清单 `test/on-device/op6-checklist.md` 第 2/3 节,标注「仅真机可验」)。
- **语音通话:尽力而为、不承诺。**VoLTE 依赖上游 sdm845 IMS 逆向进展(postmarketOS pmaports work item [#1878](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/issues/1878));国内 2G/3G 已大规模退网,无 VoLTE 时传统 2G 语音回退在多数城市不可用。真机实测结果按清单第 4 节留档,无论结果如何均不构成承诺。

**APN 预设(CN-03)**:`archmage-cn-apn` 包内置三大运营商连接档案(`/usr/lib/NetworkManager/system-connections/archmage-apn-{cmnet,3gnet,ctnet}.nmconnection`,只读系统连接),`verify-image.sh` 的 `apn_presets_present` 断言保证三档案随镜像。预设一律 **autoconnect=false**(防插错卡自动连错网),按 SIM 运营商手动启用:

```bash
# 路径一:设置 → Mobile Network 下拉选择对应运营商档案
# 路径二:命令行(以移动 cmnet 为例)
nmcli con up "中国移动 (cmnet)"
```

**锁屏安全默认(SAFETY-01/02)**:`archmage-phosh-safety` 包把「锁屏通知内容显示」出厂设为关闭并以 dconf 锁死(唯一被锁的键;解锁后的横幅通知不受影响),锁屏紧急呼叫入口为 Phosh 原生、镜像不叠加任何锁屏组件;镜像构建时 `assert-shipping-discipline.sh` 的 `safety_config_present` 与 `no_recommender_components`(`tools/checks/safety-denylist.txt`)断言安全配置在位、无广告/推荐/遥测包。

## 真机验证(OnePlus 6,hardware tier)

**清单位置**:[`test/on-device/op6-checklist.md`](test/on-device/op6-checklist.md)。全清单六节(第 0 节前置留档 + 启动/短信/数据/通话现状/应急锁屏)均为 **tier = hardware,仅真机可验,CI 永不代验**(QEMU 绿 ≠ 真机绿)。

**执行方式**:按 02-02 备份仪式完成 `backups/<序列号>/manifest.json` 在档 → 刷入 nightly 镜像 → 插入已实名 SIM → 逐节执行清单,每项记 pass/fail;第 0 节的 `fastboot getvar all` 留档输出用于确认启动链(ABL vs u-boot,Phase 3 回滚设计输入)。探测设备是否在场:`bash tools/checks/device-tier.sh --probe`(缺 fastboot/adb 与无设备同归退出码 33,stderr 首行 `DEVICE_REQUIRED`)。

**结果 JSON 提交约定**:

- 复制 [`test/on-device/op6-results-template.json`](test/on-device/op6-results-template.json)(schema_version=1;六枚举 check id:`boot-phosh` / `sms-mo` / `sms-mt` / `mobile-data` / `call-status` / `emergency-lockscreen`,每项 `{status: pass|fail|na, notes}`),逐项填写;
- 提交到 `test/on-device/results/`,文件名 `op6-<序列号>-<YYYYMMDD>.json`;
- **不含个人数据**:字段仅 serial、image{name,sha256}、checks、performed_by(GitHub 用户名/昵称)、date;`notes` 只写结论与照片文件名,**不得**写入手机号码、短信内容、联系人等任何个人信息;照片本身不入库。

**tier 晋升(manifest:device-pending → device-verified)**:

```bash
bash tools/checks/device-tier.sh --results test/on-device/results/op6-<序列号>-<日期>.json   # 先校验(缺项/非法值退 1)
bash tools/checks/device-tier.sh --results <同上> --manifest <nightly Release 的 manifest.json>
# boot-phosh=pass 时 manifest 原位改写 tier 并附 verified_by/verified_at/checks_summary;
# 非 pass 拒绝晋升退 2。
```

**Release 说明更新**:晋升后的 `manifest.json` 重传到 nightly Release(`gh release upload nightly manifest.json --clobber`),并 `gh release edit nightly --notes <更新后的说明>` 注明该镜像的真机验证结论(六项 status 概览 + 结果 JSON 的仓库路径);tier 晋升只有经 `device-tier.sh` 校验的人执结果一条路径,CI 不产生 `device-verified`。

## 模拟器开发环回

两条命令构成开发环回的"运行与验证"半边。

### aarch64 无头冒烟(一条命令,真实端到端)

```bash
bash test/smoke-aarch64.sh --from-ci
```

一条命令完成:下载 main 最新成功 CI run 的 `staging-repo` 工件 → 构建最小 ALARM aarch64 rootfs(经容器内 `pacman -r` 增量安装 `openssh` + `archmage-cn` 伞包,出厂 CN 默认值随之生效)→ QEMU 无头启动 → SSH(`127.0.0.1:2222`)→ 断言 → 结构化 JSON。宿主机缺 `qemu-system-aarch64` 时会自动在 archlinux 容器内装 `qemu-emulators-full` 并重入自身,对开发者保持一条命令(需要可用容器引擎;docker daemon 未启动时脚本会打印修复命令)。

断言(每条独立记录在 JSON;`phosh` 仅信息性,不作门禁 —— 图形栈不进 CI 门禁):

| 断言 | 门禁 | 内容 |
| --- | --- | --- |
| `multi_user` | ✅ | `systemctl is-active multi-user.target` = active |
| `no_failed_units` | ✅ | `systemctl --failed --no-legend` 为空 |
| `cn_mirror_config` | ✅ | `/etc/pacman.d/mirrorlist` 含 TUNA/USTC 源 |
| `pacman_sync_via_cn_mirror` | ✅ | VM 内 `pacman -Syu` 成功(CN-01 环回证明) |
| `cn_defaults_installed` | ✅ | `archmage-cn` + `noto-fonts-cjk` 已装且 locale 为 `zh_CN.UTF-8` |
| `phosh_informational` | ℹ️ | 仅记录 phosh 状态 |

结果工件落在 `test/results/<ts>/`(软链 `test/results/latest` 指向最新):`smoke.json`(schema v1,含 `tier: "qemu"` 层级标注 —— QEMU 绿 ≠ 真机绿)、`serial.log`(串口)、`journal.log`(本次启动 journal)、`pacman-syu.log`、`console.log`。退出码 0 即门禁通过(供 01-03 CI 消费)。构建中间产物与一次性 SSH 私钥在 `test/build/`(已 gitignore,不入库)。

### x86_64 KVM 交互环回(日常 Phosh 开发)

```bash
test/vm-x86_64.sh --check --image /path/to/image.raw   # 自检:qemu/KVM/固件/镜像
test/vm-x86_64.sh --image /path/to/image.raw           # 交互启动(KVM,无 KVM 则 WARNING 后 TCG)
```

virtio 存储/网络 + virtio-vga + usb-tablet,内存 4096M,SSH 转发仅绑 `127.0.0.1:2222`;raw 与 qcow2 均可(EFI 引导走 OVMF,EFI 变量持久化在镜像旁 `<image>.vars.fd`;也可用 `--kernel/--initrd` 直启旁路)。

**镜像获取(Phase 1 的 SKELETON 手动取像 stub 已由 02-01 关闭)**:官方来源是 nightly Release 的 x86_64 开发镜像(上节「镜像发布」的取像命令;`test/mkrootfs-x86_64.sh` 亦可本地从 staging 仓库构建等价镜像)。`vm-x86_64.sh` 代码未变,`--image` 直接传入解压出的 raw 镜像即可;未提供镜像时脚本仍打印取像指引并以非零退出,postmarketOS 通用镜像仍可作为临时替代。

## 命名与商标

- **ArchMage**(法师帽 × Arch 三角)是独立社区项目,**不是** Arch Linux 官方产品;本项目基于 [Arch Linux ARM](https://archlinuxarm.org) 与 danctnix/kupferbootstrap/pmaports 等上游构建("derived from Arch Linux")。
- 与 AUR 上的 `archmage`(CHM 工具)仅同名不同域:本项目的包均使用 `archmage-cn-*` 等前缀命名空间,不发布裸名 `archmage` 包。
