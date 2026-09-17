# 贡献指南 / Contributing

感谢参与 ArchMage。本仓库的维护成本生死线写在 [STRATEGY.md](STRATEGY.md) §4;下面是最常用的规则。

## 1. overlay-only(生死线)

**一切非 CN 差异永远跟上游,不 fork 出自己的版本,只做 overlay。** 本仓库的存续依赖 overlay-only 纪律(STRATEGY §4)。

上游分层:Arch Linux ARM(底座)→ pmaports(设备/内核)→ danctnix(移动软件包)→ kupferbootstrap(构建工具)。本仓库 `overlay/` 只承载 CN 差异:镜像源、NTP/DNS/connectivity、locale/时区/字体、中文输入、CN 应用集成。

- ✅ 正确姿势:新建一个包 `depends=(上游包名)`,通过 drop-in 配置或元包组合投递 CN 默认值(参考 `overlay/cn/` 现有五包)。
- ❌ 反例(会被直接拒绝):把 danctnix 的 `phosh/PKGBUILD` 拷进来加补丁、给上游包打"CN 优化"补丁、`replaces=`/`conflicts=` 任何上游包名。上游能修的问题,先把补丁以个人名义提交给上游(STRATEGY §5 回馈上游)。

衡量标准:overlay 与上游的 diff 只应包含 CN 默认值;diff 膨胀到覆盖大量非 CN 包时,项目已经走在死亡线上(参考 EndeavourOS ARM / Manjaro-ARM 的死因)。

## 2. 一包一目录一提交(danctnix 惯例)

- `overlay/<repo-group>/<pkg>/` 一个目录只放一个包(PKGBUILD、源文件、install 脚本)。
- `overlay/` 顶层目录 = pacman 仓库组,与仓库数据库 1:1(`cn/` → `cn.db.tar.zst`)。
- 一个提交只动一个包,提交信息格式:

  ```
  pkg: <repo>: <pkg>: <what>
  ```

  例如:`pkg: cn: archmage-cn-net: add CN connectivity check`。

## 3. PR 流程与 CI 签名边界

1. fork 仓库,从 fork 发起 PR(改动 `overlay/**` 会触发 CI)。
2. **PR 构建无 secrets 访问**(GitHub 原生隔离):PR 事件只构建、不入签名仓库,产出的 unsigned 工件仅供审阅,不会被后续流水线消费。
3. 人工评审通过、合并到 main 后,CI 才用 staging 密钥(`repo-add -s`)产出签名工件。合并即人工评审关口——请认真看待任意 PKGBUILD 都会在 CI 容器内执行的事实。
4. 全部 actions 按完整 commit SHA pin;不接受新增浮动 tag 或第三方 action(评审时拒绝)。

## 4. 什么允许进 overlay/

只有 CN 差异。判断:如果这个改动对非 CN 用户同样有意义,它应该去上游(danctnix / pmaports / Arch),而不是本仓库。拿不准就先开 issue 讨论。

## 5. 本地验证

```bash
cd overlay/cn/<pkg>
makepkg --printsrcinfo > /dev/null   # PKGBUILD 语法
makepkg -sf --noconfirm              # 本地构建(arch=any,x86_64 主机即可)
```

伞包 `archmage-cn` 依赖本仓库其它元包:先构建四个叶子包,伞包最后(或临时 `--nodeps`)。CN 元包的 install 脚本只在安装时生效,本地 makepkg 不会触碰你的系统。

## 6. 签名纪律(硬规则)

- 上游 ALARM 仓库段:`SigLevel Required DatabaseOptional`(ALARM 不分发签名数据库,强制兼容项)。
- ArchMage 自有仓库段:`SigLevel Required`。
- 任何 shipped 配置中出现 `TrustAll` = 立即拒绝(PITFALLS 2)。
