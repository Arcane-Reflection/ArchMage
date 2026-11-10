# Omarchy → ArchMage 商标层/信息层替换清单(普查基线)

> 普查基线:本机 Omarchy 4.5.0-3(2026-11-10 只读取证)。
> 用途:桌面线转 Omarchy 基座后,所有用户可见的商标/信息触点替换为 ArchMage。
> 决策前提见 DESKTOP-ROADMAP.md 与 HANDOFF-OMARCHY-BASE.md。

## 替换层级定义(先立规矩)

- **L1 化妆品层**(必做):用户看得见的一切——os-release、issue、开机画面、SDDM、
  壁纸/logo、about/fastfetch、菜单文案。
- **L2 命令层**(必做):用户敲的一切——/usr/bin/omarchy* 入口名、帮助文本、
  元数据头(omarchy:summary → archmage:summary)。
- **L3 内部层**(默认不动):/usr/share/omarchy 实现路径、~/.config/omarchy 配置路径、
  [omarchy] 仓库名。理由:上游经 pacman 仓库更新这些文件,改路径/名 = 每次上游更新
  都要重新改名(维护地狱);内部标识符用户不可见。L3 仅在我们与上游决裂时启动。

---

## 一、商标层(用户看得见的"这是谁的系统")

| # | 触点 | 位置 | 现状(4.5.0 实测) | 替换方式 | 层 |
|---|---|---|---|---|---|
| B1 | os-release | /usr/share/omarchy/etc-overrides/os-release → /etc/os-release | NAME/PRETTY_NAME="Omarchy", ID=omarchy, BUILD_ID=4.5.0 | 我方 overlay 覆写:NAME/PRETTY_NAME="ArchMage", ID=archmage, ID_LIKE=arch, BUILD_ID/VERSION_ID=跟踪版本 | L1 |
| B2 | /etc/issue(控制台登录横幅) | 自动引用 \S{PRETTY_NAME} | 随 B1 自动变,无需单独改 | 验证即可 | L1 |
| B3 | 内核名 | linux-omarchy 7.2.15-1(专属内核包,7727 文件) | uname 显示 `-omarchy` 后缀 | **v1 保留 omarchy 内核**(调校好的发行内核,名字是化妆品);v2 可选自建 linux-archmage | L1(延后)|
| B4 | Plymouth 开机画面 | /usr/share/omarchy/default/plymouth/(omarchy.script, logo.png, bullet/entry.png)| omarchy 主题脚本+logo | 换 logo.png/背景 → ArchMage 图;主题脚本名可暂留(不可见)| L1 |
| B5 | SDDM 登录屏主题 | /usr/share/omarchy/default/sddm/omarchy/(Main.qml, logo.png)+ /etc/sddm.conf.d/10-theme.conf(Current=omarchy)| omarchy 主题 | 复制主题目录→archmage,改 QML 中 logo/标题;conf.d Current=archmage | L1 |
| B6 | 壁纸包 | ~/.config/omarchy/backgrounds + themed 背景模板 | pink-blood-omarchy 等命名 | 换 ArchMage 壁纸集(或保留部分 Omarchy 壁纸,无商标元素)| L1 |
| B7 | logo 资产 | /usr/share/omarchy/logo.svg + logo.txt(ASCII)+ plymouth/sddm 内嵌 | Omarchy 字标 | ArchMage 字标 SVG+ASCII(ASCII 用于 logo.txt/about)| L1 |
| B8 | 关于页 | omarchy-branding-about(-animation)/ launch-about + skel branding/about.txt(ASCII 大字画)| "关于 Omarchy" 展示 | about.txt 换 ArchMage ASCII;branding-about 脚本文案改 ArchMage | L1 |
| B9 | fastfetch 系统信息 | /etc/fastfetch/config.jsonc(omarchy-settings 提供)| 显示 Omarchy 标识 | 配置改 ArchMage ASCII+字段 | L1 |
| B10 | 菜单/主题文案 | /usr/share/omarchy/default/i18n/(54 语言,含 zh-CN/zh-TW)+ omarchy-menu.jsonc | 菜单标题含 Omarchy | i18n 文件批量替换品牌词(zh-CN 必做,其余可保留英文)| L1 |

## 二、信息层(用户看得到的"它说它是什么/连着谁")

| # | 触点 | 位置 | 现状 | 替换方式 | 层 |
|---|---|---|---|---|---|
| I1 | 更新通道声明 | /etc/pacman.conf [omarchy] pkgs.omarchy.org/stable | 签名稳定仓库 | **保留原名不动**(L3 例外:仓库名是上游契约,改了断更新;用户不可见)| L3 |
| I2 | 滞后镜像 | /etc/pacman.d/mirrorlist → stable-mirror.omarchy.org | stable 滞后通道(与双通道哲学同构)| 保留;若上游域名变更随上游更新 | L3 |
| I3 | 版本检查 | omarchy-update-available(6h 轮询)+ update-* 家族 26 脚本 | 检查 Omarchy 新版本提示 | 保留机制;提示文案如含品牌词则替换 | L2 |
| I4 | 更新守卫 | libalpm 00-omarchy-update-guard.hook(PreTransaction Target=*)| 升级前检查更新入口 | 保留(好机制)| L3 |
| I5 | 文档/帮助链接 | agents/skills/omarchy/*.md(SKILL.md, contributing.md)、bash/env-bootstrap、菜单链接 | learn.omarchy.org、github.com/basecamp/omarchy 等 | 替换为 ArchMage 文档链接(v1 可占位指向我们仓库)| L2 |
| I6 | AI 代理技能 | /usr/share/omarchy/default/agents/skills/(omarchy, diagnose-crash, tensaku, voxtype…) | SKILL.md 自述 Omarchy | SKILL.md 改名+内容改 ArchMage;诊断类保留机制改文案 | L2 |
| I7 | 安装后信息 | omarchy-provision-user(--first-install ISO 模式)+ skel | 用户初始化文案 | 文案层替换 | L2 |

## 三、命令层(L2 的主体)

| # | 面 | 现状 | 替换方式 |
|---|---|---|---|
| C1 | 入口名 | /usr/bin/omarchy* 562 个(omarchy, omarchy-agent*, omarchy-update* 26, omarchy-menu…) | **加 `archmage` 同名入口(symlink/wrapper 到 omarchy 实现)**;旧入口保留(内部互调不断);v2 再收口 |
| C2 | 实现路径 | /usr/share/omarchy/bin/ 557 个脚本 | 保留路径(L3);仅替换用户可见字符串(help 输出里的品牌词)|
| C3 | 元数据格式 | `# omarchy:summary=… :args :examples :group :hidden` 自注解(调度器解析用)| 调度器解析时兼容双头(omarchy:/archmage:);格式名不改(L3)|
| C4 | 菜单结构 | omarchy-menu.jsonc + default/omarchy/ | 菜单内容由我们 curate(TUI 管理层接管后此面重构)|

## 四、结构与机制面(调查发现,保留不换)

| # | 机制 | 评价 | 处置 |
|---|---|---|---|
| M1 | defaults 部署:/usr/share/omarchy/default/(40+ 域:hypr/ghostty/waybar/themed/plymouth/sddm/limine/agents/i18n…)→ skel | 上游更新的主通道 | 保留(改名即断更新)|
| M2 | omarchy-update-guard PreTransaction hook | 防工作中升级,好机制 | 保留 |
| M3 | stable 滞后通道(mirrorlist-stable, lag ~1 month)| 与我们双通道哲学同构 | 保留 |
| M4 | 多架构 default/pacman/(aarch64, aarch64-apple 变体)| 上游已支持 ARM64(!)| 保留——未来手机 aarch64 桌面可复用 |
| M5 | limine 引导器 + limine-snapper-sync(替代 GRUB)| 快照同步更强 | 保留;rollback 测试适配 limine 语法 |
| M6 | SDDM(替代我们 greetd)| 基座自带 | 保留 |
| M7 | voxtype(语音输入)/ tensaku | 有趣的加成能力 | 后续评估 |

## 五、统计总览

- 品牌/信息字符串密度:/usr/share/omarchy/default/ 内 221 个文件含 "omarchy" 字符串
- 命令入口:/usr/bin/omarchy* 562;实现脚本 /usr/share/omarchy/bin/ 557
- 用户配置:~/.config/omarchy/(branding, defaults, extensions, hooks, shell.json, themed)
- i18n:54 语言(含 zh-CN/zh-TW 现成)
- 桌面相关包:omarchy(2329 文件)+ omarchy-settings(1092)+ linux-omarchy(7727)+
  omarchy-themes(-intro)+ omarchy-keyring

## 六、L1+L2 替换工作量估计

| 面 | 项数 | 方式 |
|---|---|---|
| L1 品牌资产 | B1/B2/B4/B5/B7/B8/B9/B10 ≈ 8 类 20+ 文件 | overlay 覆写 + 资产替换(ArchMage SVG/壁纸/ASCII 需设计素材)|
| L2 命令入口 | C1 562 入口(symlink 生成脚本化)| 脚本一次性生成 + CI 校验 |
| L2 文案 | I5/I6/I7 + help 输出品牌词 | sed 批量 + 人工抽查 |
| L1 B3 内核名 | v1 不动 | — |
