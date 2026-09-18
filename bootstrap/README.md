# bootstrap — ArchMage 镜像构建(kupferbootstrap 驱动)

本目录只携带 **配置与驱动脚本**:`kupferbootstrap`(kbs)上游源码零修改、零 vendored 副本
(STRATEGY §4 overlay-only 生死线)。我们交给 kbs 的是一份 profile + 一份仓库声明,外加一个
把这些配置驱动起来的构建脚本。

## 文件结构

| 文件 | 作用 |
| --- | --- |
| `kbs-version.txt` | 单行 kbs 版本 pin(当前 `v0.3.0-rc0`,写入后不漂移;见下方「版本 pin 策略」) |
| `archmage.toml` | kbs TOML 配置:wrapper/pkgbuilds/paths + profile `archmage-op6-phosh`(device `sdm845-oneplus-enchilada`、flavour `phosh`、`pkgs_include = ["archmage-cn"]`)与 stage-1 构建用子 profile |
| `repos.local.yml` | kbs 用户级仓库配置(**整体替换**上游 pkgbuilds 内 `repos.yml`,因此是上游完整副本 + 注入的 `archmage` 段) |
| `bootstrap.sh` | 幂等驱动脚本(host/container 两相;详见下文三阶段) |

构建产物落在 `bootstrap/.work/`(已 gitignore):`kupfer/images/` 下的
`sdm845-oneplus-enchilada-phosh-{boot,root,full}.img` 与抽取出的
`sdm845-oneplus-enchilada-aboot.img`(Android boot 镜像,`fastboot flash boot` 用)。

## 版本 pin 策略

- `kbs-version.txt` 固定 kbs 的 git tag,pip 从官方 `gitlab.com/kupfer/kupferbootstrap` 按
  tag 安装(T-02-03/T-02-SC:不 vendor 源码、不执行任何 curl-bash)。
- **为何 pin `v0.3.0-rc0` 而非最新 stable `v0.2.0`**:上游最新 stable tag v0.2.0 只有
  `setup.cfg`(无 `setup.py`/`pyproject.toml`),现代 pip 对 bare setup.cfg 的 VCS URL
  一律拒绝安装(实测:`does not appear to be a Python project`);v0.2.0 时代的官方安装
  方式是 Docker 镜像 + requirements.txt,而非 pip。v0.3.0-rc0 是第一个带 `pyproject.toml`
  (可 pip 安装)的 tag,也是当前最新 tag;本仓库的安装机制(pip from git+tag)只能落在此。
  两者对本流程的载重语义一致(已逐一核对:pacstrap -G 无 keyring 事务、wrapper none、
  出厂 pacman.conf 生成、repos.local.yml 整体替换、profile 解析)。
- `repos.local.yml` 的键集合必须覆盖 pin 对应 pkgbuilds 分支(`dev`)的 `repos.yml`;
  `bootstrap.sh` 在 `kbs packages init` 之后做键集合 diff,上游演进导致缺键即报错退出,
  提示「按新 pin 重同步本文件」(逐字复制上游 repos.yml 后重新加回 `archmage` 段)。
- pkgbuilds 自带 `kbs_min_version`(当前快照为 v0.2.0-rc4),pin 的 v0.3.0-rc0 满足之
  (semver 比较)。

## 三阶段构建(为什么 CN 层不进 kbs 事务)

对上游源码(pinned tag 与 v0.2.0 均已核对,行为一致)核实过的事实:kbs 的镜像安装事务以 `pacstrap -G` 落在一个 **没有 pacman
keyring** 的新 rootfs 上,构建期 pacman.conf 里所有仓库都是上游的 `SigLevel = Never`
(kupfer prebuilts 无签名)。**`SigLevel Required` 的仓库无法通过这种无 keyring 事务**。
因此:

1. **stage 1** `kbs image build archmage-op6-phosh-build`:上游原样装配镜像
   (ALARM base + kupfer device/flavour/phosh 包)。构建期 `repos.local.yml` 使用
   「上游完整副本、去掉 archmage 段」的构建变体,构建 profile 用 `pkgs_exclude` 排除
   `archmage-cn`。
2. **stage 2** loop-mount rootfs 分区镜像,把 staging 公钥导入镜像 keyring 并本地签名,
   再以 `pacman -r` + `SigLevel Required`(签名数据库亦验证)安装 `archmage-cn` ——
   CN 默认值经我们的 staging 仓库**带完整签名纪律**进入镜像(01-02 已验证的外来 root
   keyring 手法)。该 keyring 随镜像出厂,真机上 pacman 信任的正是构建它的那把钥匙。
3. **stage 3** 加固出厂 `/etc/pacman.conf`:ALARM 段去掉构建期 `SigLevel = Never` 覆盖
   (回落到全局 `Required DatabaseOptional`,即 ALARM 上游政策:包签名必需、DB 无签名);
   kupfer prebuilts 段逐字保留上游 `Never`(其预编译包无签名,属上游政策,非我方放宽);
   追加 `archmage` 段(`SigLevel = Required`)。

## 本地用法

```bash
bash bootstrap/bootstrap.sh --check                # 离线自检:toml/yaml 结构 + pin(无需 docker)
bash bootstrap/bootstrap.sh --staging-dir /tmp/staging-repo   # 全量构建(需要可用容器引擎)
bash bootstrap/bootstrap.sh --install-only        # 只装 kbs + 校验配置
```

staging 目录取 `gh run download -n staging-repo` 的产物即可;平面布局与
`$arch/$repo` 布局都会被自动探测归一(`archmage.db -> cn.db.tar.zst` 符号链接)。

## CI 无 wrapper 运行原理(为什么不需要 kbs 的 docker wrapper)

`archmage.toml` 里 `[wrapper] type = "none"`:kbs **不**使用它自带的 docker wrapper。
`bootstrap.sh` 的 host 相把仓库与 staging 目录挂进一个 **特权
`menci/archlinuxarm:base`(aarch64)容器**,kbs 以 root 在容器内原样运行(losetup/mount
需要特权)。于 runner(ubuntu-24.04-arm,docker 可用)与本地开发机(docker 修好后的任意
引擎)是同一条路径;配置文件里的 `wrapper.type = "none"` 如实描述了 kbs 的运行方式。
镜像构建是 aarch64 原生的(arm64 runner 上无 binfmt、无交叉)。

## overlay-only 边界

kbs 上游零修改;本目录只有配置与驱动。任何 **CN 之外**的需求(新设备、新 flavour、构建
机制变化)一律走上游(pkgbuilds / kbs 仓库),不在本仓库 fork。镜像内的 CN 默认值全部经
`overlay/cn/` 元包进入(见 `overlay/cn/README.md`),`repos.local.yml` 只声明仓库与最严
签名级别(`SigLevel: Required`,绝不放宽)。
