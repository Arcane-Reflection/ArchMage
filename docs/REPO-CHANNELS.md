# 双通道仓库与 stable 签名仪式(REPO-CHANNELS)

> UPDATE-03 的机器面:**CI 只产 staging;stable 的签名动作全部发生在维护者
> 宿主机;密钥永不进入任何自动化**(CI、runner、容器、脚本)。本文档是
> 「人工门禁」的操作说明书 —— 脚本只负责可机械验证的部分
> (`tools/repo/promote-staging.sh`),仪式由人执行。

## 1. 通道模型

```
packages.yml(CI,自动)          维护者宿主机(人工)              客户端
┌──────────────────────┐   3–7 天泡期   ┌──────────────────────┐
│ overlay/*/ makepkg    │ ────────────▶ │ promote-staging.sh    │
│ repo-add -s → staging │   人工 review  │ --real(逐包 detach-  │
│ 逐包 .sig + DB .sig   │   (见 §2)     │ sign + repo-add -s -k)│
└──────────────────────┘               └──────────┬───────────┘
                                                   │ 发布
                              ┌────────────────────┴──────────────────┐
                              │ stable 通道(人工签名,永不进 CI)      │
                              │ testing 通道(= staging,自动)         │
                              └───────────────────────────────────────┘
```

| 通道 | pacman.conf 段名 | 产出方 | 签名 | 出厂状态 | 用途 |
|------|------------------|--------|------|----------|------|
| staging/testing | `[archmage-testing]` | packages.yml(CI,自动) | CI 里的 ephemeral/persistent staging key | **生效**(镜像内嵌副本) | 滚动尝鲜;镜像自更新 |
| stable | `[archmage-stable]`(注释态) | 维护者宿主机人工仪式 | stable key(离线仪式) | 注释态, ceremonies 后启用 | 保守用户;`pacman-key --populate archmage` 的信任锚随 archmage-keyring 包分发 |

泡期策略:staging 工件产出后**泡 3–7 天**才允许晋升(`--min-age-days`,
默认 3,机器强制下限)—— 让 staging 的传染性问题(依赖缺失、配置破坏)
先在 testing 用户群暴露。泡期是下限不是上限;改动越敏感,泡得越久。

## 2. promote-staging 真实模式仪式(逐条)

前置:维护者宿主机;本机 GNUPGHOME 持有 stable 签名密钥(§3);`gh`
已登录;要晋升的 staging 工件已确定(某个 packages.yml run 的
staging-repo artifact)。

1. **取工件**:
   `tools/repo/promote-staging.sh --from-ci --real --out-dir /srv/stable-promote`
   (或先把 artifact 下载到目录,走 `--repo-dir`)。脚本自动:gh run
   download → 校验 DB 与逐包签名(01-01 契约)→ 生成 sha256 清单。
2. **sha256 核对**:脚本写出的 `promote-consumed.sha256` 与工件来源
   (CI run 页面/本地下载)比对一遍 —— 脚本验的是「签名一致」,人核对
   的是「这就是我审过的那份」。
3. **泡期检查**:`--min-age-days`(默认 3)按工件时间戳强制;不足即退。
   泡期内人工 review 内容:新包 diff、依赖闭包、install scriptlet、
   overlay 改动 —— **这一步没有机器替代,是整个双通道模型的意义所在**。
4. **逐包签名**:脚本对每个包执行 `gpg --detach-sign`(stable key)。
5. **签 DB**:脚本执行
   `repo-add -s --include-sigs -k <STABLE_KEY_FPR> stable.db.tar.zst <pkgs>`
   —— `-s -k` 签仓库数据库;`--include-sigs` 必须显式传(repo-add 自
   2021 起不再隐式把包签名嵌进 DB,packages.yml CI 同款先例)。
6. **发布**:产物 `stable.db.tar.zst + stable.db.sig + 每包 .sig + 每包`,
   脚本附 `promote-produced.sha256`。发布到宿主渠道(静态文件服务),
   之后通知客户端切换(§5)。

脚本在 CI 环境一律拒绝(`GITHUB_ACTIONS`/`CI` 任一设置即
`HUMAN_GATE:` 首行 stderr,退出码 2)—— `--dry-run` 也拒绝:签名链的
机械部分整体不进自动化。

## 3. 密钥仪式(key ceremony)指引

目标:stable 签名密钥只存在于离线介质,在线机器只留签名子键,自动化
接触不到任何私钥。

- **离线主键 + 签名子键**:在永不上网的机器(或临时 Live 环境)生成
  主密钥:
  `gpg --batch --quick-gen-key "ArchMage stable release key <stable@archmage.invalid>" rsa4096 cert never`
  随即添加签名子键:
  `gpg --quick-add-key <FPR> rsa2048 sign never`
  (never 过期 + 硬件介质 + rotation 承担风险控制,Phase 4 细化)。
- **主键离库**:把主密钥导出(`gpg --export-secret-keys`)存入离线介质
  (加密 U 盘/智能卡/纸质),从在线机器删除主密钥私钥,仅保留子键:
  `gpg --delete-secret-keys <主键FPR>`(子键留驻)。
- **签名子键驻维护者宿主机**:导入子键(或直接用智能卡)。日常晋升
  (§2)只用子键;子键泄露时主键可撤销并签发新子键(见 §6)。
- **介质纪律**:密钥介质不插任何 CI 机器、不进任何仓库、不进任何容器
  镜像;`STABLE_KEY_FPR` 指纹可以公开,私钥路径只在本机 GNUPGHOME。
- **首次导出 keyring**:`tools/repo/export-keyring.sh <STABLE_KEY_FPR>`
  只导出公钥半边(`gpg --export`)—— 产出
  `overlay/core/archmage-keyring/archmage.gpg` 与 `archmage-trusted`
  指纹清单;脚本不读取任何私钥文件。

## 4. keyring 包的产出与 stable 自更新路径

1. 仪式完成:`export-keyring.sh` 写入 `archmage.gpg` + `archmage-trusted`;
   删除 `overlay/core/archmage-keyring/.ci-defer`,提交并 push ——
   packages.yml 从此把 keyring 包打进 staging(`.ci-defer` 存在时 CI
   显式跳过该包,仪式前仓库提交态不含 archmage.gpg,由 .gitignore 锁定)。
2. keyring 包随 stable 首发 promotion 进入 stable 通道。
3. 新客户端一次性导入:`pacman-key --add stable-key.asc &&
   pacman-key --lsign-key <FPR>`(密钥随发布页分发,指纹多渠道核对),
   之后装 `archmage-keyring` → `pacman-key --populate archmage` 全自动。
4. 自更新闭环:keyring 包自身经 stable 通道分发,由 stable key 签名
   —— 之后 key 更新(如添加新子键指纹)只需发新版 keyring 包,客户端
   `pacman -Syu` 即完成 populate,无需再手工导入。

## 5. 客户端切换方法

镜像出厂态:`[archmage-testing]` 生效(SigLevel Required,指向镜像内嵌
staging 副本或托管镜像),`[archmage-stable]` 为注释态段 +
`/etc/pacman.d/archmage/channels/stable.conf`(空 Server 列表)随镜像
预置。切换到 stable:

1. 确认 `archmage-keyring` 已安装(或按 §4.3 一次性导入)。
2. 编辑 `/etc/pacman.d/archmage/channels/stable.conf`,填入 stable 渠道
   Server(托管地址或本地镜像)。
3. `/etc/pacman.conf` 里取消 `[archmage-stable]` 段注释(SigLevel
   Required + Include stable.conf),按需注释/删除 `[archmage-testing]`。
4. `pacman -Sy` —— Required 纪律在两个通道都不放松(签名不符即拒绝,
   无任何豁免开关)。

回退到 testing:反向操作即可(两个通道的包同源同构建,仅签名与泡期
不同)。

## 6. 轮换(rotation)指针

密钥轮换的完整流程(新主键生成、新旧 key 并行期、旧指纹进 revoked、
keyring 包大版本 bump)规划于 **Phase 4**;届时本节升级为逐条文档。
在此之前:若发生子键泄露,直接用离线主键生成 revoke 证书,重走 §3–§4
(新指纹进 archmage-trusted,新 keyring 包发 stable),客户端
`pacman -Syu` 自愈。
