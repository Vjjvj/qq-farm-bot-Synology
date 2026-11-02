# 群晖 DSM 构建与打包教程

面向想自己出 `.spk` 的人。装包用的路径与配置见根 [README](../README.md)，本文只讲**怎么把包打出来、打完怎么验、出问题往哪看**。文中实测数据来自 2026-11-02 的 SA6400（DSM 7.2.2-72806 Update 8，glibc 2.36，15.7G 内存 / 4 核）。

打包链在 [`synology/`](../synology/build.sh)：`build.sh` + `conf/privilege` + `scripts/` 七个生命周期钩子。

## 一、前置条件

| 项 | 要求 |
|---|---|
| 构建机操作系统 | **必须是 Linux**。脚本开头 `uname -s` 直接拒绝非 Linux：外层 `.spk` 是不压缩的 tar，里面那颗 `node` 二进制要保住 755 可执行位，Git Bash/MSYS 打包会丢权限，装到 DSM 上起不来 |
| 工具链 | GNU tar、Node.js 20+、pnpm 10、curl、`sha256sum`/`md5sum`/`du`/`find`（GNU coreutils+findutils） |
| 出站网络 | `nodejs.org`（官方 node dist + SHASUMS256）与 npm registry（`pnpm install`、corepack 取 pnpm）可达；不通就把 node 预置进缓存目录（见第五节） |
| 磁盘 | ≥2G 余量（源码 + `node_modules` + 缓存 + 产物；产物本体约 66M） |
| 目标机 glibc | **≥ 2.28**（Node 22 的硬要求）。装机前在群晖上确认：`/lib/libc.so.6 \| head -1` 或 `getconf GNU_LIBC_VERSION` |

> DSM 上 `/usr/bin/ldd --version` **没有任何输出**（它不是标准 GNU ldd），别拿它判断 glibc。

## 二、最短路径：在目标群晖上出包

构建机 = 安装目标，是最省事也更不容易踩坑的做法（架构、glibc 当场就是对的）。整条流程实测约 2 分钟出包。

### 2.1 取源码到 NAS

DSM 默认没有 `git`。有 git 就 clone；没有就用归档下载或在本地 `git archive` 传上去。

```sh
BUILD=/volume1/qq-farm-bot-build
mkdir -p "$BUILD/src" "$BUILD/cache"

# A. NAS 能访问 GitHub 且不介意没有 .git
curl -L https://codeload.github.com/Vjjvj/qq-farm-bot-Synology/tar.gz/refs/heads/master \
  | tar xz -C "$BUILD/src" --strip-components=1

# B. 从本地推已跟踪文件（25MB 左右，不含 node_modules/.git）
git -C /path/to/repo archive --format=tar.gz -o /tmp/qqfb-src.tar.gz HEAD
cat /tmp/qqfb-src.tar.gz | ssh root@<NAS_IP> 'cat > /volume1/qq-farm-bot-build/qqfb-src.tar.gz'
```

**传输要用管道，别用默认 `scp`**：DSM 的 sshd 没启 sftp 子系统，新版 `scp` 默认走 sftp，会得到

```
subsystem request failed on channel 0
scp: Connection closed
```

`scp -O`（退回旧协议）或者 `cat 文件 | ssh 'cat > 目标'` 都能绕开。两端各跑一次 `sha256sum` 对一下再往下走。

### 2.2 备一套构建用的 Node + pnpm

DSM 上没有 node/pnpm，自己在构建目录里挂一套，不碰系统路径、不装套件中心的 Node.js。

```sh
ND=$BUILD/cache/node-v22.23.3-linux-x64
cd "$BUILD/cache"
curl -fsSL -O https://nodejs.org/dist/v22.23.3/SHASUMS256.txt
curl -fsSL -O https://nodejs.org/dist/v22.23.3/node-v22.23.3-linux-x64.tar.gz
grep ' node-v22.23.3-linux-x64.tar.gz$' SHASUMS256.txt | sha256sum -c -    # 期望输出 OK
tar xzf node-v22.23.3-linux-x64.tar.gz

export PATH="$ND/bin:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
corepack enable pnpm --install-directory "$ND/bin"
node -v && pnpm -v          # v22.23.3 / 10.30.2
```

`packageManager` 字段锁的是 `pnpm@10.30.2`，corepack 会自己按版本从 registry 取，不需要 `npm i -g pnpm`。

### 2.3 跑构建

```sh
cd "$BUILD/src"
NODE_CACHE_DIR="$BUILD/cache" MAINTAINER=<你的名字> SPK_ARCH=x86_64 bash synology/build.sh
```

产物落在 `synology/out/qq-farm-bot_<版本>_<架构>.spk`，旁边一个 `.sha256`。取回本地同样走管道：

```sh
ssh root@<NAS_IP> 'cat /volume1/qq-farm-bot-build/src/synology/out/qq-farm-bot_2026.11.02-1_x86_64.spk' \
  > qq-farm-bot_2026.11.02-1_x86_64.spk
sha256sum -c qq-farm-bot_2026.11.02-1_x86_64.spk.sha256
```

> SSH 会话一断，前台构建就跟着没了。要脱管跑：
> `setsid nohup bash -c 'NODE_CACHE_DIR=… bash synology/build.sh > build.log 2>&1; echo $? > build.done' &`
> 然后本地 `while [ ! -s build.done ]; do sleep 5; done; cat build.log` 收结果。

## 三、可覆盖的构建变量

| 变量 | 默认 | 作用 |
|---|---|---|
| `SPK_ARCH` | `x86_64` | `x86_64` / `armv8` / `armv7`，映射到官方 node 的 `linux-x64` / `linux-arm64` / `linux-armv7l` |
| `SPK_VERSION` | 当天日期 `-1`（`TZ=Asia/Shanghai`） | 形如 `2026.11.02-4`，写进 `INFO` 的 `version` |
| `NODE_VERSION` | `v22.23.3` | 随包 node 的版本；老机型 glibc < 2.28 时退到 Node 20/18 对应的值 |
| `NODE_CACHE_DIR` | `<产物目录>/cache` | 指到已解压过 node dist 的目录，`4/6` 步检测到 `bin/node` 在就跳过下载与二次校验（省 60MB） |
| `SKIP_INSTALL` | 未设 | `1` 时跳过 `pnpm install`（依赖已装好）。**只影响 `1/6`**，不能跳过构建 |
| `MAINTAINER` | `git config user.name`，取不到写 `unknown` | 进 `INFO` 的 `maintainer`/`distributor`。NAS 上没有 `.git` 时**要显式给**，否则发布商名是 `unknown` |
| 第 1 个位置参数 | `synology/out` | 产物输出目录 |

`BUILD_INFO.source_commit` 在没有 `.git` 的机器上会是 `unknown`，只影响记档，不影响安装。

## 四、版本号规则

`YYYY.MM.DD-N`。DSM 把 `version` 当「主版本-feature build」两段比较：`2026.11.02-4` 比 `2026.11.02-3` 新，也比 `2026.11.01-9` 新。同一天反复出包就递增 `-N`，套件中心能直接覆盖升级。别写成带字母的后缀，`version` 分段要求纯数字。

## 五、打出来的东西长什么样

外层 `.spk` 是**不压缩的 ustar tar**，成员顺序有意义（`INFO` 必须在最前）：

```
INFO  package.tgz  conf/privilege  scripts/{preinst,postinst,preupgrade,postupgrade,preuninst,postuninst,start-stop-status}  PACKAGE_ICON.PNG  PACKAGE_ICON_256.PNG
```

内层 `package.tgz` 解到 `/var/packages/qq-farm-bot/target`：

```
node/bin/node                    # 官方 Node，755
node/LICENSE
BUILD_INFO                       # app_version / bot_version / source_commit / spk_arch / runtime / built_at
server/bin/main.js               # esbuild 产物，无 node_modules
server/bin/worker.js
server/resources/{gameConfig,proto,utils/*.wasm}
server/web/dist/
```

图标直接复用飞牛的 `fnos/qq-farm-bot/ICON.PNG` 与 `ICON_256.PNG`——尺寸正好是 DSM 要的 64×64 和 256×256。

**一个坑（两层规则不一样）**：内层 `package.tgz` 的成员名带 `./` 前缀（`./server/bin/main.js`），按名提取必须写全：`tar xf package.tgz -C dir ./server/bin/main.js`，漏掉 `./` 会 `Not found in archive`。外层 `.spk` 的成员名**不带**前缀（`INFO`、`conf/privilege`）。

## 六、装机前自检（不用安装就能验完）

`tar xOf` / `tar xf` 到临时目录即可，全程只读。

| 检查项 | 命令 | 期望 |
|---|---|---|
| 外层成员与顺序 | `tar tvf <pkg>.spk` | `INFO` 在最前；`scripts/*` 全是 `-rwxr-xr-x`、owner/group 为 `0/0` |
| 权限声明合法 | `tar xOf <pkg>.spk conf/privilege` | **只有** `defaults.run-as="package"` + `username`/`groupname` 四行，没有 `ctrl-script`/`executable`/`tool` |
| `INFO` 关键字段 | `tar xOf <pkg>.spk INFO` | `checksum` 与实测 `md5sum package.tgz` 逐字一致、`extractsize` 与 payload 实际 KB 相符、`arch` 与目标机型匹配、`yes`/`no` 字段没有别的值 |
| 脚本语法 | 逐个 `sh -n scripts/*` | 七个脚本全部通过（`#!/bin/sh`，POSIX 写法） |
| 随包 node 可执行 | 内层解出后 `md5sum node/bin/node`，与构建机上那颗 node 比对 | 一致，且 `-rwxr-xr-x` |
| 产物语法 | 用那颗 node 跑 `node --check server/bin/main.js worker.js` | 通过 |
| 没有 TCP 锁 | `grep -c "QQ_FARM_NO_TCP = " server/bin/*.js` | 0 处（飞牛版把 `QQ_FARM_NO_TCP=1` 用 `--banner:js` 编进产物，带上来群晖就永远拒绝监听） |
| 没有飞牛标记 | `find payload -name FNOS_NATIVE` | 空（代码里有读取它的分支，文件不存在即不生效） |
| 前端挂根路径 | `grep -o 'src="[^"]*"' server/web/dist/index.html` | `/assets/index-*.js` 之类根路径，无 `/webman` 前缀 |
| 资源完整性 | `find server/resources/gameConfig \| wc -l`、`ls server/resources/utils/*.wasm` | gameConfig 上千个文件、`proto` 里 0 个 `.bak`、两颗 wasm 齐 |

`build.sh` 自己带了两道硬拦截，触发就退出而不是打出坏包：产物里 grep 到 `QQ_FARM_NO_TCP` 赋值；`core/node_modules` 里出现 `.node` 原生模块（那样必须随包提供对应架构的预编译文件）。

**别把随包的 `node` 解到 `/tmp` 下执行**：DSM 7 的 `/tmp` 是 `tmpfs (rw,nosuid,nodev,noexec)`，权限位明明是 `-rwxr-xr-x` 也会报 `Permission denied`，看着像包坏了。自检的工作目录放 `/volume1/...` 下，同一颗 node 实测在那儿 `-v` 输出 `v22.23.3`。同理，`sha256sum -c xxx.spk.sha256` 必须在 `.sha256` 记录的同名文件所在目录里跑——那文件只记 basename，换目录会报找不到。

## 七、装完第一次验证

```sh
/usr/syno/bin/synopkg status qq-farm-bot     # 非交互 SSH 里 synopkg 不在 PATH，必须写绝对路径
ps -eo pid,user,args | grep appstore/qq-farm-bot/node | grep -v grep
netstat -lntp | grep 3007
tail -f /var/packages/qq-farm-bot/var/qq-farm-bot.log   # var 是 DSM 软链，指向套件所在卷的 @appdata/<pkg>
grep -a qq-farm-bot /var/log/synopkg.log | tail -20      # 安装链路：preinst → 解包 → postinst → start
```

期望：`status` 返回 running、进程属主是 `sc-qq-farm-bot`、监听 `0.0.0.0:3007`（`settings.conf` 里 `ADMIN_HOST` 改过则对应变化）。`synology/out` 旁边那份 `.sha256` 在传输前后各验一次。

## 八、失败对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| 弹窗「由于 XX 以 root 权限运行，因此无法安装」，`/var/log/synopkg.log` 只有 `Use any available volume to install` 两行、没有任何脚本执行记录 | `conf/privilege` 声明了 root 的 `ctrl-script`/`executable`/`tool`。**DSM 7.2 拒绝在解包之前**，官方签名包能这么写，第三方不能 | `privilege` 收缩成四行；钩子里所有 root-only 动作（`chown`、写 `/etc`、`synouser`）一律删掉——`target` 与 `var` 的属主 DSM 自己会改好。已在本机对照过 5 个第三方包（qBittorrent、docker-qinglong、DDNS-GO、SimplePermissionManager、git）与 3 个官方包 |
| 装上但起不来，DSM 只显示「未运行」 | 见下条逐因 | `start-stop-status start` 拉起后会轮询最多 10 秒确认进程存活，失败就删 PID 返回非 0，错误落在 `@appdata/qq-farm-bot/qq-farm-bot.log` |
| 进程秒退 | `node/bin/node` 丢了可执行位（在 Windows 上打的包）、缺 `server/bin/worker.js`、3007 被占、`@appdata` 不属 `sc-qq-farm-bot` | 依次 `ls -l` 那三项、`netstat -lntp \| grep 3007`、`id sc-qq-farm-bot`；换端口就改 `settings.conf` 的 `ADMIN_PORT` 再重启套件 |
| 装到一半报「安装失败」，看不出为什么 | `INFO` 字段问题（字段名拼错、`yes`/`no` 写了别的、`version` 分段非纯数字、`arch` 与机型不符、`checksum` 不匹配） | 具体原因只在 `/var/log/synopkg.log`；`uname -m` 拿机器架构，`synoinfo.conf` 的 `arch=` 可反查 DSM 的架构名 |
| 页面能打开但图裂、实时状态不动 | 构建期 `VITE_BASE` 与运行期 `QQ_FARM_GATEWAY_PREFIX` 是两个独立真理源，必须与「反代是否保留前缀」三者一致 | 本项目挂根路径，两者都留默认值即可；要改子路径反代就必须成对设置且反代保留前缀 |
| `vite build` 被 OOM kill | 内存不够 | 加 swap，或换台 x86 Linux 跑完 `1/6`～`3/6`，把 `synology/out/payload/` 传上群晖，再手动续跑 `4/6`～`6/6` 那几行（脚本没有分步开关） |
| 重复构建很慢 | `pnpm install` 每次重跑 | `SKIP_INSTALL=1`；node dist 用 `NODE_CACHE_DIR` 复用 |
| `sc-qq-farm-bot` 身份去构建反而更慢 | pnpm store 路径跟着用户走，换用户等于重解一遍依赖 | 构建用哪个都行，但**全程同一个用户**；构建与安装都不需要 `sc-` 账号参与 |
| 在 Windows 上打包后 DSM 起不来 | MSYS/Git Bash 丢可执行位，还会重写形如 `/xxx` 的环境变量值 | 别在 Windows 出包；`build.sh` 也已经先拦住 |

## 九、交叉架构（armv8 / armv7）

`SPK_ARCH=armv8 synology/build.sh` 会去拉 `node-v22.23.3-linux-arm64` 并打对应包。注意：

- 构建机本身是 x86 也没关系，脚本只是把官方 arm 版 node dist 塞进包里，交叉点是「下载哪个 dist」，不是交叉编译。
- **arm 机型要确认 glibc ≥ 2.28**，否则调 `NODE_VERSION` 退版本。
- 截至 2026-11-02，本仓库只在 SA6400/`x86_64` 上完成过实机安装与运行验证，`armv8` 属于参数化就绪但未实机验证。

## 十、安全边界（打包时就要想清楚的）

- 应用**没有登录页**，信任边界就是「谁能连到这个端口」。包默认写 `ADMIN_HOST="0.0.0.0"`，方便局域网直开，代价是同网段任何人可控制你挂上去的 QQ 账号。
- 经反代/隧道暴露时，反代必须**清掉 `X-Trim-*` 请求头**：没有这些头时应用把访问者当作管理员，而客户端自己伪造 `X-Trim-Isadmin: false` 反而会把自己降成普通用户。
- 想把默认值改掉，改 [`synology/scripts/postinst`](../synology/scripts/postinst) 里那段 `settings.conf` 模板；它只在文件不存在时写入，所以升级不会覆盖用户已改的配置。

## 相关文档

- 根 [README](../README.md) —— 功能清单、安装与配置。
- [`docs/config-storage.md`](config-storage.md) —— 账号配置与登录态的存储边界（决定备份什么、卸载会带走什么）。
- [`fnos/飞牛部署与变更说明.md`](../fnos/飞牛部署与变更说明.md) —— 飞牛版打包链；群晖版复用了它的 `fnos/sea/entry.js` 入口和图标。
