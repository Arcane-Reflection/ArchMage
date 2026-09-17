# linuxphoneOS

> 基于 Arch Linux ARM 的 CN 化开放 Linux 手机系统(overlay-only flavor):Phosh 移动栈 + 出厂 CN 默认值(镜像/NTP/DNS/locale/字体),以"一切皆代码"的方式维护。
>
> An open, CN-localized Arch Linux ARM phone OS: Phosh mobile stack plus factory CN defaults, maintained entirely as code.

**状态 / Status:** 仓库骨架阶段(Phase 1)— CN 元包与 CI 出包环回可用;QEMU 开发环回与镜像构建见路线图。

技术策略与阶段路线见 [STRATEGY.md](STRATEGY.md);贡献规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 目录结构

| 目录 | 用途 |
| --- | --- |
| `overlay/cn/` | CN 出厂默认元包(pacman 仓库组 `cn`,一包一目录) |
| `overlay/phosh/` | Phosh 风味包(Phase 2 填充) |
| `overlay/device/` | 设备 overlay(Phase 2,OnePlus 6) |
| `overlay/qemu/` | QEMU 虚拟设备包(Phase 1,01-02) |
| `bootstrap/` | kupferbootstrap fork(Phase 2 填充) |
| `test/` | QEMU 冒烟测试与 fixtures(01-02 填充;`fixtures/pacman-verify.conf` 已可用) |
| `flash/op6/` | OnePlus 6 分层刷机脚本(Phase 2 填充) |
| `tools/` | 自动化维护工具(Phase 4 填充) |
| `.planning/` | 项目规划文档(GSD) |

## 快速上手(三步)

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

3. **push 触发 CI 并获取签名 staging 仓库**(arm64 runner 构建 + `repo-add -s` 签名):

   ```bash
   gh run watch "$(gh run list --workflow=packages.yml --branch main --limit 1 \
     --json databaseId --jq '.[0].databaseId')" --exit-status
   gh run download -n staging-repo -D /tmp/staging-repo
   gpg --import /tmp/staging-repo/staging-key.asc
   gpg --verify /tmp/staging-repo/cn.db.tar.zst.sig /tmp/staging-repo/cn.db.tar.zst
   ```

## CI 与签名

- `packages.yml` 在 `ubuntu-24.04-arm` runner 的 `menci/archlinuxarm:base-devel` 容器内构建 `overlay/` 中变更的包,产出 `staging-repo` 工件:`cn.db.tar.zst`、`cn.db.tar.zst.sig`、`staging-key.asc`、`FINGERPRINT.txt` 及包文件。
- 本仓库需为 **public**(arm64 runner 免费额度仅限公有仓库)。
- staging 签名密钥经仓库 secrets `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` 注入;secrets 缺失时 CI 用**仅本次运行有效**的 ephemeral 密钥并在工件与 job summary 显著标注(配置方法见 `.planning/phases/01-skeleton-devloop/01-01-PLAN.md` 的 user_setup)。stable 级密钥永不进入自动化(STRATEGY §8)。
- 签名纪律:上游 ALARM 仓库 `SigLevel Required DatabaseOptional`(ALARM 不分发签名数据库),自有仓库 `Required`;全仓库禁 `TrustAll`(PITFALLS 2)。

## 模拟器开发环回

(由 Phase 1 计划 01-02 填充:`test/vm-x86_64.sh` 交互 VM 与 `test/smoke-aarch64.sh` 无头冒烟。本节当前不提供任何命令。)
