# Spike decision: 候选窗走 classic UI 锚定,不自绘面板(03-01,03-RESEARCH Week-1 spike 1/2)

**结论:(A) classic UI 锚定成立 —— Task 2 不建 gtk4-layer-shell 自绘候选窗面板。**

证据留档运行:`test/results/20261002T133657Z/`(2026-10-02,KVM, patched phoc + pixman
渲染的最终形态);此前 20261002T121327Z 与 20261002T115256Z 两轮运行给出同型证据
(协议行数 61/64,截图同构)。

03-RESEARCH 给出的两条路线:

- (A) fcitx5 classic UI 原生承担候选窗:phoc 接力 `zwp_input_popup_surface_v2`,候选窗/预编辑串跟随应用上报的 `text-input-v3 set_cursor_rectangle` 光标矩形;
- (B) phoc 不接力或遮挡,自绘 gtk4-layer-shell 兜底面板(计划内偏差)。

实测证据支持 (A),判据逐条留档如下。

## 判据 1:fcitx5 以 waylandim 绑定 input-method-v2(唯一客户端位)

- `test/ime/ime-verify.sh` 启动的 fcitx5 全程带 `WAYLAND_DEBUG=1`,其日志即探针
  (工件名 `ime-probe.log`)。每次运行在 phoc 下可见完整的
  `zwp_input_method_v2` 绑定序列(bind → commit_state → activate),
  计数 60-64 条协议行;`zwp_input_method_keyboard_grab_v2` 抢占与释放正常,
  无 keyboard-grab 失败行(`fcitx5_waylandim_healthy` 门禁断言)。
- squeekboard 激活路径在会话启动前 `systemctl --user mask mobi.phosh.OSK.service`
  屏蔽(Task 2 后镜像不再含 squeekboard),`ime_unique_im_client` 断言 fcitx5
  是唯一 input-method 客户端。

## 判据 2:classic UI 创建 zwp_input_popup_surface_v2(而非退化为 (0,0) 面板)

- 探针日志中可见 fcitx5 classic UI 创建 `zwp_input_popup_surface_v2`
  (每次输入会话 2 条协议行:get_input_popup_surface → configure),
  即 phoc 按 text-input-v3 的 `set_cursor_rectangle` 把弹窗锚到光标矩形,
  **没有**退化为 (0,0) 定位的自绘面板。
- 门禁断言 `waylandim_popup_probe`(ime.json)钉死该证据:
  popup 行数 > 0 且 input-method-v2/grab 行数 > 0 才 pass
  (留档运行实测:input-method-v2 64 行 + popup 2 行)。

## 判据 3:候选窗/预编辑跟随光标矩形(截图佐证)

- 输入轮截图(工件,每次运行重新捕获,归档于
  `test/results/<ts>/ime-candidate-window.png` 与 `ime-committed.png`):
  - 预编辑态:预编辑串(下划线 "ni hao")渲染在 GTK4 输入框光标处,
    fcitx5 classic UI 的弹窗表面贴着光标矩形锚定;
  - 提交态:空格选词后缓冲区变为「你好」。
- 应用侧地面真值(`test/ime/apps/gtk-entry-app.py` 逐行 JSON 日志):
  缓冲区收到「你好」且原始拼音串从不落入缓冲
  (`ime_e2e_chinese_commit` 门禁断言,IME-01 机器面)。

## 判据 4(边界):QEMU 判据与真机判据的分工

- 本 spike 的全部证据来自 QEMU/KVM headless 输出(720x1440 竖屏几何,
  pixman 渲染)。**候选窗在真机竖屏上的遮挡/跟随行为无法在 QEMU 判定**
  (无 DSI 面板、无真实 scale=2 几何)——按计划记为 device-deferred,
  OP6 首刷后按 33/DEVICE_REQUIRED 语义复验(已记 WINDOWS 账本)。
- Xwayland 行(GTK3-x11 / Qt5-xcb)的候选窗由 fcitx5 classic UI 的 X11
  定位承担,不走 `zwp_input_popup_surface_v2`(该协议只覆盖 Wayland 原生
  客户端);矩阵行只断言提交串,不断言锚定。

## 2026-10-02 运行中的附带发现(影响 harness,不影响结论)

- phoc 0.57.0 在 input-method keyboard-grab 销毁时读 wlroots 0.20 改为
  NULL 的信号载荷 → 段错误(与 labwc #2978 / sway #8864 同类,上游未修;
  debuginfod 符号化定位 handle_im_keyboard_grab_destroy)。dev 镜像以
  mkrootfs 的 phoc pin(重编译加补丁)修复——这是 harness 健壮性问题;
  classic UI 锚定路径本身不受影响。
- Qt 5.15 的 wayland 客户端缓冲集成需要合成器侧 linux-dmabuf(pixman
  不广播),Qt5 矩阵行显式走 Xwayland(xcb);Qt6/chromium 以 wl_shm
  在 wayland 原生路径工作。
- 合成器虚拟键盘(wtype)→ Xwayland 的按键路径存在键码错译
  (`wtype abc` 在无 fcitx5 的 QLineEdit 里落成「12」)——Xwayland 矩阵行
  的程序化键入改走 XTEST(xdotool),该行为是否影响真实键盘待真机复验。

## 对后续计划的影响

- Task 2(archmage-fcitx5-osk 包)不包含任何自绘面板代码——包内
  README 记录同一结论。
- 若真机复验发现竖屏遮挡,兜底(gtk4-layer-shell 面板)按计划内偏差
  路径补入,包结构不受影响。
