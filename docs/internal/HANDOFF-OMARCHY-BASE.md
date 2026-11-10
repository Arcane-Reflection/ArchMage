# 移交计划:桌面线转 Omarchy 基座(D-0)+ 后续 D 系列

> 移交日 2026-11-10。本文档自包含:接手机器/接手人只需本仓库 + 本文档即可继续。
> 前置阅读:docs/internal/omarchy-rebrand-inventory.md(商标/信息层普查清单)、
> .planning/DESKTOP-ROADMAP.md(桌面完成情况+D 系列原路线,本机私有,已摘录入本文)。

---

## 一、项目背景(30 秒版)

**ArchMage**:基于 Arch 的中文本地化 Linux 系统,反预装反臃肿,未来面向行业/终端市场。
双产品线:
- **手机线**(OP6/aarch64):基于 Kupfer 上游(bootstrap/kupferbootstrap 路线),已有
  nightly,CI 全绿。此线不在本次移交范围。
- **桌面线**(x86_64,本次移交主题):原计划在裸 Arch 上手搓 Hyprland 桌面
  (test/desktop-x86_64.sh,18/18 结构门禁,7.6G 镜像已能构建)。
  **决策变更(2026-11-10)**:改为基于 Omarchy 4.5.x 基座重建桌面线——桌面体验
  (Hyprland+quickshell 4.x 壳/主题/安装器/更新机制/limine+snapper 回滚)全部由
  Omarchy 基座提供,我们只叠加 CN 层 + TUI 管理层 + 品牌 + curation。

## 二、仓库与 CI 现状(接手第一步核对)

- 仓库:github.com/Arcane-Reflection/ArchMage(gh 登录 uMaj35ty)
- HEAD:1e0e07c fix(desktop): builder 需传递解析态给自包装(见下文"已修问题链")
- 七条流水线:packages(双架构)/ image(op6+qemu+desktop 三镜像)/ qemu-smoke /
  gap-report / upstream / perf(仅手动,托管 runner 无 KVM)/ flash-tests
  ——**image 工作流当前红**:qemu-x86_64-image 的 smoke 断言 cn_defaults 期待伞包
  (已 aarch64 化),570902c 已改门禁为 cn 子包语义但未验证;desktop-x86_64-image
  绿;a15c7d6 修了自包装参数传递(见下文教训 #1)。接手后先跑一轮 image 确认。
- 双架构 packages 全绿(42814242911):aarch64 全量手机 overlay + x86_64
  desktop/cn/core 三组;工件 staging-repo / staging-repo-x86_64。
- .planning/(本机私有,不入库):DESKTOP-ROADMAP.md/ROADMAP.md/WINDOWS.md/
  omarchy-rebrand-inventory.md 已在本机;**接手机器需本目录同步或按本文档重建**。

## 三、D-0 计划:Omarchy 基座接入(详细步骤)

### D-0.1 确认上游仓库与钉版本
- 上游稳定仓库(本机 4.5.0-3 实测):`[omarchy] Server = https://pkgs.omarchy.org/stable/$arch`,
  keyring 包 omarchy-keyring(MIT 许可;stable-mirror.omarchy.org 滞后镜像同构我们双通道)。
- 在仓库记录 `test/omarchy-version.txt`(如 `4.5.0-3`),builder 读取钉版本。
- 上游 repo:github.com/basecamp/omarchy(注意 releases 里仓库显示 omacom/omarchy)。

### D-0.2 builder 改造(test/desktop-x86_64.sh)
现有构建器(裸 Arch + 手搓 Hyprland)保留为 `--legacy` 模式;新默认走 Omarchy 基座:
1. pacman.conf 追加 `[omarchy]`(pkgs.omarchy.org/stable + keyring);保留 core/extra
   (我们的 CN overlay 与基座并行)。
2. pacstrap 清单改为:`base linux-omarchy linux-omarchy-headers`(上游专属调校内核,
   7.2.15-1,uname 后缀 -omarchy;v1 接受内核名,v2 评估 linux-archmage)+ omarchy 元包
   (keyring/themes-intro/settings/themes + hyprland quickshell uwsm sddm 门户 gum 等,
   omarchy 元包 depends 自带)。
3. **品牌替换**(清单见 omarchy-rebrand-inventory.md,L1+L2):
   - B1 os-release 覆写(ID=archmage,PRETTY_NAME=ArchMage)
   - B5 SDDM 主题复制为 archmage(QML logo/标题)
   - B7/B8 logo.svg/logo.txt/about.txt 换 ArchMage 字标
   - B9 fastfetch 配置
   - C1 562 个 /usr/bin/archmage* 入口 symlink 生成脚本(→ omarchy 实现)
   - I5/I6 文档与 AI skills 文案
4. **保留项**:stable 滞后镜像、update-guard hook、limine+snapper 同步、
   i18n(现成 zh-CN)、omarchy-provision-user(ISO 模式)。
5. **我们的叠加**:archmage-desktop 元包(CN locale/字体/net + fcitx5 + TUI 工具)、
   Hyprland 会话、mirror 包(后续 D-2')。

### D-0.3 启动验证(D-1' 并入)
- QEMU 启动:SDDM → autologin → Hyprland+quickshell 桌面 → 截图门禁(grim 非黑屏)。
- 验证 quickshell 壳渲染正常(4.x 壳;上轮 quickshell 经验:触屏问题已在 OP6 VM 解决)。
- fcitx5 + Ghostty 手动验证(CN 输入)。

### D-0.4 CI 接线
- desktop-x86_64-image job 改调新构建路径;smoke 断言改 desktop 语义(伞包→子包/元包)。
- publish-nightly 桌面资产已有分片逻辑,无需改。

## 四、已修问题链(血泪教训,接手必读,全部在本仓库 git 历史)

1. **自包装传参**(a15c7d6):self-wrap 传 "$@" 会被 arg-parse 循环 shift 消费成空——
   **必须传解析态**(inner_args+=(--from-ci) 模式)。任何新自包装脚本同坑。
2. **archlinux:base 镜像重构**:无 [extra](gh/桌面栈装不上,静默 >/dev/null 更致命)——
   [extra] 守卫 + 不静默 pacman 输出;包名是 github-cli 非 gh。
3. **--populate 收钥匙环名**(archlinuxarm)非包名(archlinuxarm-keyring);先装包后 populate。
4. **sfdisk 简写** type=UEFI/512MiB 无效 → 显式 GUID+扇区(mkrootfs-x86_64.sh 766 行形式)。
5. **裸 loop 设计**:共享 /dev 上 loopNpN 异步物化(mkrootfs PITFALL)——ESP/root 分文件
   + dd 组装;mkfs.vfat 标签 ≤11 字符;stale 镜像 btrfs 签名残留需 rm+`-f`。
6. **全量 -Syu 纪律**(0b18893):`-Sy pkg` 在上游 ABI 迁移期(openssl 3→4)会拉新
   openssl 破坏容器自身 pacman(libssl.so.3 消失)。五个构建脚本已统一 -Syu;新脚本必守。
7. **snapper 弱绑定**:chroot 无 DBus 套接字,create-config 必死(FileNotFound)——
   遵从 archmage-btrfs-rollback 脚本特弱绑定(配置留首启);不要在 chroot 抢跑。
8. **复合命令勿进 gate() 包装**:args 里 &&/重定向不按脚本行语义重解析(静默死亡)。
9. **组目录散文件**:git ls-files 会带出 overlay/<组>/README.md 之类——读 $d/PKGBUILD
   前先存在性检查(a486965 教训)。
10. **PKGBUILD arch= 字段即分组语义**:手机/ALARM 专属包显式 arch=(aarch64),桌面 leg
    按 PKGBUILD arch= 过滤;伞包(cn)与回滚包(btrfs-rollback)的取舍见
    dc54dff/570902c/e6ebe3e 三连(回滚包最终回归 any——纯脚本+模板,桌面同样需要)。

## 五、上游风险与对策

- **上游漂移**:Omarchy 3→4 全量重构先例。对策:钉 stable 通道(自带 ~1 个月滞后)+
  omarchy-version.txt 记录;weekly upstream 工作流可加 omarchy 仓库检查。
- **4.x quickshell 触屏**:OP6 VM 上已验证 quickshell 触屏问题(鼠标倒置等)为
  virglrenderer 1.3.0 已修 bug——桌面 x86_64 无此问题。
- **品牌合规**:Omarchy MIT——保留版权声明(镜像 docs 加 attribution);
  所有用户可见商标换 ArchMage(L1+L2 清单执行)。
- **CN 网络注意**:pkgs.omarchy.org/stable-mirror 从 CN 可达性未测——构建时若慢,
  换 ARCHMAGE_DESKTOP_MIRROR_ORDER 或加 omarchy 镜像。

## 六、接手后首个工作项(按序)

1. 跑一轮 image 工作流确认 HEAD 状态(桌面绿;qemu-smoke 的 cn 门禁断言
   570902c 已修未验——若红按其 FAIL 文本对齐 cn 子包语义)。
2. D-0.1~D-0.4 依次执行,每步本地构建验证(desktop-x86_64.sh,
   ARCHMAGE_DESKTOP_MIRROR_ORDER=cn,~20-40 分钟一轮)。
3. D-0 完成后:镜像 QEMU 启动验证(D-0.3)→ 截图给用户。
4. 之后按 DESKTOP-ROADMAP.md D-2'(mirror)→ D-3'(签名)→ D-4'(TUI 层,
   需先做 v0.2 Phase 5 调度器)→ D-5'(回滚验证,注意 limine 语法适配)。

## 七、本机私有文档索引(.planning/ 不随仓库走,需手动同步)

- DESKTOP-ROADMAP.md:桌面完成情况+原 D 系列(已被本 D-0 计划部分取代)
- ROADMAP.md:全项目路线(手机线 P0-P4 + v0.2 TUI 里程碑)
- WINDOWS.md:CI 全部教训归档(十五关+桌面五轮)
- omarchy-rebrand-inventory.md:已提升至 docs/internal/(随仓库走)
- research/omarchy-quickshell-mobile-prep.md:Omarchy 4.x 架构与 quickshell 能力调研
