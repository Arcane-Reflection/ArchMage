# overlay/desktop — x86_64 桌面层(2026-11-10 立项)

桌面产品线(x86_64)的专属包层。分组约定:

- `desktop` 组 = 本目录;packages CI 的 x86_64 leg 只构建 desktop/cn/core 三组
- aarch64 leg 构建全量手机 overlay(cn/core/device/phosh/apps/qemu),与本目录无关
- 工件:`staging-repo-x86_64`(aarch64 仍是 `staging-repo`,01-01 契约不变)
- cn-mirror 是 ALARM 专属(archlinuxarm 树);桌面镜像包(archmage-desktop-mirror,
  Arch 主线 TUNA/USTC)另行立项

内容:
- archmage-desktop:桌面元包(CN locale/字体/网络默认),后续挂 TUI 管理层(v0.2)
