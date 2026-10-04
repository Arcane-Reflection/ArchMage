# 输入法(fcitx5,用户视角)

> **本文档覆盖什么**:出厂默认的中文输入法是什么、在会话里怎么用、候选框
> 行为如何,以及输入矩阵当前的验证现状。
> **本文档不承诺什么**:六行工具箱矩阵目前 **2/6 行在 QEMU 绿**;失败的行
> 全部如实标注失败原因与顺延路径(真机面 device-deferred,WINDOWS
> #27/#28/#30,33/DEVICE_REQUIRED)。不存在"全矩阵已验证"的说法。

## 1. 默认输入法:fcitx5(waylandim)

出厂默认系统键盘是 **fcitx5**,经 waylandim(Phosh/compositor 的
input-method 接口)接入图形会话:

| 事实 | 说明 |
| --- | --- |
| 提供方 | `archmage-fcitx5-osk` 包(overlay/phosh/) |
| 顶掉的默认 OSK | squeekboard(包内 `Conflicts: squeekboard/stevia`,`Provides: phosh-osk-provider`,pacstrap 显式按 provider 解析) |
| 接入方式 | fcitx5 以 input-method keyboard 接入 compositor(waylandim 语义),工具箱应用照常经各自的 IM 模块(GtkIMModule/Qt IM/XIM)到达 fcitx5 |
| 出厂行为 | 会话启动即随 Phosh 会话可用,无需用户手动拉起 |

## 2. 会话内用法与候选框

- 拼音输入:点入任意文本框 → 屏幕键盘(FCITX5 面板)输入拼音 → 候选框
  出现 → 选字上屏。
- 候选框锚定:候选窗口跟随焦点文本框,**竖屏下锚定在输入框上方**,经
  `zwp_input_popup_surface_v2` 实现(input-popup 语义;QEMU 已验证的判定
  见下节缺口表——**真机竖屏遮挡行为未验**)。
- 中英切换、标点行为与上游 fcitx5 一致,本仓库不做上游能改的差异
  (overlay-only 纪律,CONTRIBUTING §1)。

## 3. 验证现状:六行矩阵(诚实表)

矩阵定义与执行器:[`test/ime/run-matrix.sh`](../test/ime/run-matrix.sh)
(在 QEMU 会话内逐行独立运行,每行断言「你好」真实上屏、拼音原文不落
缓冲)。当前 **2/6 行 QEMU 绿**:

| 行 | 状态 | 说明 |
| --- | --- | --- |
| gtk4-wayland(text-input-v3) | ✅ 绿 | 出厂默认路径 |
| qt6-wayland | ✅ 绿 | Qt6 wayland 走 wl_shm,无需 EGL |
| gtk3-wayland | ❌ QEMU 环境 | GDK 需要 EGL(或 GLX)呈现窗口,pixman 渲染器无 dmabuf(无 virgl 就没有 GBM 设备)——窗口无法呈现、拿不到焦点 |
| gtk3-x11(Xwayland) | ❌ QEMU 环境 | 同 GTK3 呈现类失败;X 行键入经 XTEST(合成器 virtual-keyboard → Xwayland 的键码路径对 wtype 有误译) |
| qt5-xwayland(xcb) | ❌ QEMU 环境 | 焦点正常但 commit 投递不落 |
| chromium-wayland | ❌ QEMU 环境 | 预编辑经 wayland-ime 渲染,但 commit 不到达 DOM 值 |

失败行的**共同点**:都是 QEMU 渲染/投递环境的限制,不是输入法配置问题
——但**"不是配置问题"这个判断本身也未经真机反证**,所以这些行一律保持
红,不顺延成"绿"。

## 4. 已知缺口(逐条顺延,不作完成态)

| 缺口 | 状态 | 账目 |
| --- | --- | --- |
| GTK3 两行(gtk3-wayland / gtk3-x11)的 IM 接入路径 | 真机面或 virgl-enabled QEMU 才可验;真机 OP6(freedreno GL)预期可呈现窗口 | WINDOWS #27,33/DEVICE_REQUIRED |
| qt5-xwayland 与 chromium-wayland 的 commit 投递 | 真机面顺延 | WINDOWS #28,33/DEVICE_REQUIRED |
| 竖屏候选框遮挡/跟随行为(真 DSI 面板,scale 2) | QEMU 只验了 input-popup 锚定语义;真机首启复查;兜底方案为 gtk4-layer-shell 面板(包结构不受影响) | WINDOWS #30,33/DEVICE_REQUIRED |
| 真机面板上的端到端中文输入 | 属真机清单验收范围 | `test/on-device/op6-checklist.md` |

## 5. 开发者入口

- 会话验证 harness:`test/ime/ime-verify.sh`(构建/复用 dev 镜像 → 启动
  Phosh 会话 → 逐行跑矩阵 → `test/results/<ts>/ime.json` +
  `ime-matrix.json`,tier = qemu)。
- 决策记录(候选框锚定方案选型):`test/ime/decision-spike.md`。
- 上游问题(candidates:fcitx5 / phoc / wlroots 的 IM grab 崩溃类)按
  overlay-only 纪律以个人名义回馈上游,不在本仓库 fork 规避
  (STRATEGY §4/§5,CONTRIBUTING §1)。

## 虚拟键盘排查档案(2026-10-04,stevia 时代)

### 现象与最终形态

- stevia 0.57 已接管 im-v2 席位(顶替 fcitx5 waylandim,后者自启动已压制);
- `sm.puri.OSK0 SetVisible true` **可强制展开键盘并正常打字**(英文);
- **自动展开/收起不工作**:任意应用(含 text-input-v3 正规的 GTK4 应用)聚焦时,
  stevia 收到 `zwp_input_method_v2.activate()` 但选择不展开(WAYLAND_DEBUG 抓包,
  activate 后零表面创建);hunspell 词典缺失会加剧(`Failed to init completer`)。

### 排查链(每环有证据)

1. fcitx5 包自带 XDG 自启动 → 抢占 im-v2 唯一席位 → stevia 收 `unavailable()`。
   修复:压制自启动(镜像已烘焙)。
2. phosh 0.57 的 DBus 面:名字 `sm.puri.OSK0`(无 org 前缀)、路径 `/sm/puri/OSK0`、
   `Visible` 属性只读、展开用 `SetVisible b true` 方法。旧文档的
   `org.sm.puri.OSK0` + `/org/sm/puri/OSK0` + 可写 Visible 全部过时。
3. `display-manager.service` 是绝对路径符号链接:verify 的 `-e` 测试会解析到
   验证容器自身根(greetd 未装于容器)→ 永假。检查用 `-L`。
4. `osk_old` 断言语义:初始必须 `absent`(首版写成 `yes` 导致永红——断言 bug)。
5. 遗留开放项:activate 收到但不展开。下一层线索:
   - `mobi.phosh.osk` schema(mobile-settings 带来)的 `scaling`(auto-portrait/
     auto-landscape)与 `osk-features`;
   - phosh-mobile-settings 的 OSK 面板里是否有额外启用项;
   - stevia 上游 issue(带本档案的 WAYLAND_DEBUG 抓包可复现)。
6. 中文路线:stevia 中文走 uim(Arch 仓库缺,Debian 有 phosh-osk-stevia-uim
   分包参照);P1 自建键盘走 fcitx5 VirtualKeyboardBackend DBus
   (clear-code/fcitx5-virtualkeyboard-ui 参考实现)。

### 镜像内容(已烘焙)

greetd(自动登录 archmage/PIN 1234)+ seatd + pixman 渲染 + stevia +
phosh-mobile-settings + hunspell-en_us + fcitx5 自启动压制。
