# 回滚指南(btrfs 快照,用户视角)

> **本文档覆盖什么**:系统更新翻车后,如何用 btrfs 快照把系统退回上一个
> 能用的状态——从引导菜单启动旧快照、把回滚固化为新默认、回滚后自检。
> **本文档不承诺什么**:QEMU 里端到端验证过的回滚链(`test/rollback-x86_64.sh`,
> tier = qemu)**不等于真机绿**;OP6 的真机回滚路径未在真机执行过
> (device-deferred,WINDOWS #26,33/DEVICE_REQUIRED 顺延)。已知缺口在
> §4 逐条列出,不作完成态表述。

## 1. 快照什么时候产生

镜像出厂带 snapper + snap-pac + grub-btrfs(根文件系统为 btrfs 平坦子卷
布局,快照存在 `@snapshots` 子卷、挂载于 `/.snapshots`——**在根子卷 `@`
之外**,回滚替换 `@` 时快照仓库不受牵连):

| 时机 | 行为 |
| --- | --- |
| 每次 pacman 安装/升级/删除事务 | snap-pac 自动产生 pre(事务前)+ post(事务后)一对快照 |
| 数量封顶 | `NUMBER_LIMIT=5` / `NUMBER_LIMIT_IMPORTANT=5`:只保留最近 5 对,更旧的自动清理 |
| 时间线快照 | `TIMELINE_CREATE=no`:没有定时快照,快照只随包事务产生 |

查快照:`snapper -c root list`。每一行的编号就是下文用到的快照号。

## 2. 从引导菜单回滚(先能启动再说)

系统已经起不来时(典型:一次 `pacman -Syu` 后内核/关键包损坏):

1. 开机在 GRUB 菜单选 **Arch Linux snapshots** 子菜单(grub-btrfs 维护,
   每次快照事件后自动重生成条目)。
2. 挑一个**翻车之前**的 pre 快照(或任何已知完好的 post 快照)回车。
3. 系统以**只读**方式从该快照启动——此时 uname -r 应显示快照内的旧内核,
   系统可用但仍在只读根上。这一步是 UPDATE-02 契约的引导面。

## 3. 把回滚固化为新默认

只读快照上无法长期生活,需要把快照变成可写的新默认子卷:

- **x86_64 开发机 / QEMU 环境**(GRUB 引导):在从快照启动的系统内执行
  `snapper -c root --ambit classic rollback <快照号>`——生成该快照的可写
  克隆并设为新的默认子卷,重启后常规引导即进入回滚后的系统。
- **OP6 真机**:用 `archmage-rollback <快照号>`(来自
  `archmage-btrfs-rollback` 包)。**先 `--dry-run`**:它只打印完整命令序列、
  不写任何盘,逐行看过再真跑。真跑做三件事(缺一不可,OP6 引导链与
  GRUB 环境根本不同——内核在 boot 分区,只切子卷默认的话启动的仍是坏
  内核):
  1. 快照 → 可写克隆 → `btrfs subvolume set-default`;
  2. 从 `/var/lib/archmage/bootimg/<内核版本>.img` 把该快照对应的
     boot.img 写入**非活动槽**(每次内核包事务由 hook 自动存档,位于
     @var、跨回滚存活);
  3. `qbootctl` 切槽并重启。

## 4. 已知缺口(逐条诚实)

| 缺口 | 事实 | 账目 |
| --- | --- | --- |
| x86_64 镜像 snapper 回滚后需要重建 grub.cfg | vanilla GRUB 的 10_linux 把内核路径钉在 `/@/boot/vmlinuz-linux`(toplevel 相对),grub 自身前缀也在 `/@/boot/grub`——**snapper 回滚替换默认子卷后,需在恢复出的系统内执行 `grub-mkconfig -o /boot/grub/grub.cfg`,常规启动才会反映回滚**;引导菜单进快照不受影响(快照条目自带 subvol 参数) | WINDOWS #23 |
| OP6 真机回滚路径未在真机执行 | `archmage-rollback` 的 snapper clone + boot.img dd + qbootctl 切槽全链只在 QEMU 做过结构校验(bash -n、--dry-run 命令序列审计、33 守卫实退);需 OP6 + qbootctl 真机验证 | WINDOWS #26,33/DEVICE_REQUIRED |
| snapper 限额模板到达镜像的时机 | 安装 scriptlet 只在已启动的 systemd 系统上落配置;pacstrap 构建的镜像在**首次真机包升级**时生效 | WINDOWS #24 |

## 5. 回滚后验证清单

| # | 检查 | 预期 |
| --- | --- | --- |
| 1 | `uname -r` | 回到翻车前的内核版本(或与所选快照一致) |
| 2 | 系统进入并可用 | 从新默认子卷正常启动,无 failed unit(`systemctl --failed`) |
| 3 | `findmnt /` | 挂的是默认子卷(无多余 `subvol=` 压参数;镜像出厂 fstab 即此形态) |
| 4 | `snapper -c root list` | 回滚产生的新快照在列;封顶 5 生效 |
| 5 | 下一次 `pacman -Syu` | 正常事务,产生新的 pre/post 快照对 |
| 6 | (仅 x86_64,WINDOWS #23) | 已在恢复出的系统内重建 grub.cfg(§4) |
