# linuxphoneOS

> 基于 Arch Linux ARM 的 CN 化开放 Linux 手机系统(overlay-only flavor):Phosh 移动栈 + 出厂 CN 默认值(镜像/NTP/DNS/locale/字体),以"一切皆代码"的方式维护。
>
> An open, CN-localized Arch Linux ARM phone OS: Phosh mobile stack plus factory CN defaults, maintained entirely as code.

**状态 / Status:** Phase 1(骨架与开发环回)— CN 元包全家桶可本地构建,push 到 main 由 arm64 CI 出签名 staging 仓库;QEMU 开发环回与镜像构建见路线图。

技术策略与阶段路线见 [STRATEGY.md](STRATEGY.md);贡献规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 目录结构

| 目录 | 用途 |
| --- | --- |
| `overlay/cn/` | CN 出厂默认元包(pacman 仓库组 `cn`,一包一目录):mirror / net / locale / fonts-meta / 伞包 `linuxphoneos-cn` |
| `overlay/phosh/` | Phosh 风味包(Phase 2 填充) |
| `overlay/device/` | 设备 overlay(Phase 2,OnePlus 6) |
| `overlay/qemu/` | QEMU 虚拟设备包(Phase 1,01-02) |
| `bootstrap/` | kupferbootstrap fork(Phase 2 填充) |
| `test/` | QEMU 冒烟测试与 fixtures(01-02 填充;`fixtures/pacman-verify.conf` 已可用) |
| `flash/op6/` | OnePlus 6 分层刷机脚本(Phase 2 填充) |
| `tools/` | 自动化维护工具(Phase 4 填充) |
| `.planning/` | 项目规划文档(GSD) |

## 快速上手(本阶段成果)

前置:Arch 系主机(装 `base-devel`)、`git`、GitHub CLI `gh`(已 `gh auth login`)。

1. **克隆**:

   ```bash
   git clone https://github.com/uMaj35ty/linuxphoneOS.git
   cd linuxphoneOS
   ```

2. **本地构建一个 CN 元包**(`arch=(any)`,x86_64 主机无需交叉环境):

   ```bash
   cd overlay/cn/linuxphoneos-cn-mirror
   makepkg -sf --noconfirm
   ls *.pkg.tar.zst
   ```

   注:伞包 `linuxphoneos-cn` 依赖本仓库其它元包,请先构建四个叶子包,伞包最后构建(或用 `--nodeps`;CI 内自动按此处理)。

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
  gpg --quick-generate-key "linuxphoneOS staging" ed25519 sign 0   # 记下指纹
  gpg --armor --export-secret-keys <FPR> | gh secret set GPG_PRIVATE_KEY
  gh secret set GPG_PASSPHRASE        # 若设了口令
  ```

  secrets 未配置期间,main 构建用**仅本次运行有效**的 ephemeral 密钥并在工件与 job summary 显著标注,其签名工件不可被下游消费。

- **签名纪律**(PITFALLS 2):上游 ALARM 仓库 `SigLevel Required DatabaseOptional`(ALARM 不分发签名数据库),自有仓库 `Required`;全仓库禁 `TrustAll`。

## 模拟器开发环回

两条命令构成开发环回的"运行与验证"半边。

### aarch64 无头冒烟(一条命令,真实端到端)

```bash
bash test/smoke-aarch64.sh --from-ci
```

一条命令完成:下载 main 最新成功 CI run 的 `staging-repo` 工件 → 构建最小 ALARM aarch64 rootfs(经容器内 `pacman -r` 增量安装 `openssh` + `linuxphoneos-cn` 伞包,出厂 CN 默认值随之生效)→ QEMU 无头启动 → SSH(`127.0.0.1:2222`)→ 断言 → 结构化 JSON。宿主机缺 `qemu-system-aarch64` 时会自动在 archlinux 容器内装 `qemu-emulators-full` 并重入自身,对开发者保持一条命令(需要可用容器引擎;docker daemon 未启动时脚本会打印修复命令)。

断言(每条独立记录在 JSON;`phosh` 仅信息性,不作门禁 —— 图形栈不进 CI 门禁):

| 断言 | 门禁 | 内容 |
| --- | --- | --- |
| `multi_user` | ✅ | `systemctl is-active multi-user.target` = active |
| `no_failed_units` | ✅ | `systemctl --failed --no-legend` 为空 |
| `cn_mirror_config` | ✅ | `/etc/pacman.d/mirrorlist` 含 TUNA/USTC 源 |
| `pacman_sync_via_cn_mirror` | ✅ | VM 内 `pacman -Syu` 成功(CN-01 环回证明) |
| `cn_defaults_installed` | ✅ | `linuxphoneos-cn` + `noto-fonts-cjk` 已装且 locale 为 `zh_CN.UTF-8` |
| `phosh_informational` | ℹ️ | 仅记录 phosh 状态 |

结果工件落在 `test/results/<ts>/`(软链 `test/results/latest` 指向最新):`smoke.json`(schema v1,含 `tier: "qemu"` 层级标注 —— QEMU 绿 ≠ 真机绿)、`serial.log`(串口)、`journal.log`(本次启动 journal)、`pacman-syu.log`、`console.log`。退出码 0 即门禁通过(供 01-03 CI 消费)。构建中间产物与一次性 SSH 私钥在 `test/build/`(已 gitignore,不入库)。

### x86_64 KVM 交互环回(日常 Phosh 开发)

```bash
test/vm-x86_64.sh --check --image /path/to/image.raw   # 自检:qemu/KVM/固件/镜像
test/vm-x86_64.sh --image /path/to/image.raw           # 交互启动(KVM,无 KVM 则 WARNING 后 TCG)
```

virtio 存储/网络 + virtio-vga + usb-tablet,内存 4096M,SSH 转发仅绑 `127.0.0.1:2222`;raw 与 qcow2 均可(EFI 引导走 OVMF,EFI 变量持久化在镜像旁 `<image>.vars.fd`;也可用 `--kernel/--initrd` 直启旁路)。

**镜像获取当前为手动步骤(SKELETON 标注的 stub,Phase 2 由 kupferbootstrap 自动化)**:可现成使用 [postmarketOS generic x86_64 Phosh 镜像](https://images.postmarketos.org/genericx86/)(`unxz` 解压后直接传入),脚本未提供镜像时也会打印该指引并以非零退出。
