# overlay/desktop — x86_64 桌面层(2026-11-10 立项;D-0 转 Omarchy 基座)

桌面产品线(x86_64)的专属包层。分组约定:

- `desktop` 组 = 本目录;packages CI 的 x86_64 leg 只构建 desktop/cn/core 三组
- aarch64 leg 构建全量手机 overlay(cn/core/device/phosh/apps/qemu),与本目录无关
- 工件:`staging-repo-x86_64`(aarch64 仍是 `staging-repo`,01-01 契约不变)
- cn-mirror 是 ALARM 专属(archlinuxarm 树);桌面镜像包(archmage-desktop-mirror,
  Arch 主线 TUNA/USTC)另行立项(D-2')

## 内容

- **archmage-desktop**(v3):桌面元包。D-0 起范围收窄为"Omarchy 基座缺失的部分":
  CN 层(locale/字体/网络默认)+ fcitx5 中文输入 + Ghostty + chromium +
  NetworkManager/ufw + fzf。桌面栈本体(Hyprland/uwsm/quickshell/SDDM/portals/
  pipewire/gum/limine+snapper)由钉版本的 omarchy 元包提供(builder:
  test/desktop-x86_64.sh,pin:test/omarchy-version.txt)
- **archmage-branding**(v1):品牌层引擎。L1 化妆品(os-release/SDDM 主题副本/
  plymouth logo/logo.svg/logo.txt/about/fastfetch/limine 品牌词/zh-CN 菜单文案)
  + L2 命令层(/usr/bin/archmage* 入口 symlink 农场、archmage.desktop 会话、
  主 AI skill 文案),经 99-archmage-branding PostTransaction hook 在每次
  omarchy 升级后重新施加。L3 内部路径(/usr/share/omarchy、[omarchy] 仓库名)
  **不动**——上游更新通道必须保持。分层普查:
  docs/internal/omarchy-rebrand-inventory.md

## 品牌合规(attribution)

Omarchy 基座 MIT 许可(c) Basecamp / omacom-io,https://github.com/basecamp/omarchy 。
上游桌面栈按钉版本原样进入镜像(未 fork);所有用户可见商标经 archmage-branding
替换为 ArchMage;镜像 FINGERPRINT.txt 携带同样的 attribution 行。
