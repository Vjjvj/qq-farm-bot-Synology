# 同步上游代码（飞牛版 → 群晖 fork）

> 何时读我：要把上游的新提交并进本仓库时。
> 不在这里：出包与装机前自检见 [synology-build.md](synology-build.md)；安装、升级、回滚见根 [README](../README.md)。

## 1. 拓扑

| remote | 地址 | 角色 |
| --- | --- | --- |
| `origin` | `Vjjvj/qq-farm-bot-Synology` | 群晖版，只出 `.spk`，日常推送目标 |
| `upstream` | `Maksim-venus/qq-farm-bot-fnos` | 飞牛版；它自己再合并原始项目 `liyangpengs/qq-farm-bot` |

两边主干都叫 `master`。群晖侧改动全部隔离在 `synology/` 与 `.github/`，不往上游提 PR。

## 2. 五步

先看差了多少：

```sh
git status            # 必须干净，脏工作区不要开始合并
git fetch upstream
git rev-list --left-right --count master...upstream/master   # 左=本地独有，右=上游新增
git log --oneline master..upstream/master                    # 上游这批具体改了什么
```

本机 `git fetch` 走 schannel 时可能报 `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)`，这不是网络或代理的问题（`.gitconfig` 里的 `http.https://github.com/.proxy` 照常可用），换 TLS 后端即可：

```sh
git -c http.sslBackend=openssl fetch upstream --tags
```

**判断会不会冲突**（这一步别省，先算再合）：

```sh
base=$(git merge-base master upstream/master)
git diff --name-only "$base" master            # 本地补丁碰过的文件
git diff --name-only "$base" upstream/master   # 上游改过的文件
```

两份名单的交集就是冲突面；交集为空，直接 `git merge upstream/master` 不会有冲突（2026-11-04 与 2026-11-07 两次交集都为空，合并都没有冲突）。

**合并**（用 merge，不要 rebase，理由见第 3 节）：

```sh
git merge upstream/master
```

**验证，四条都要过**。2026-11-07 那次合并（上游 `2bdcf37`）的实测：core 402 通过、web 48 通过、`vue-tsc` 无输出、`web build` 成功。

Windows 上跑这四条有两个坑，都不是代码问题：`node --test` 要派生带管道的子进程，沙箱/受限令牌下会以 `spawn EPERM` 挂在每个测试文件上（core 会「全部失败」，看着像合并炸了）；`web build` 的 esbuild 清理临时目录时可能报 `Access is denied`。把 `TEMP`/`TMP` 指到工作区内再跑，或直接在完整权限下跑，就能过。

```sh
pnpm -C core test          # 内部先 build:ts 再 node --test
pnpm -C web test
pnpm -C web typecheck
pnpm -C web build
```

## 3. 为什么必须 merge，不能 rebase

- `master` 已经推到 `origin` 并被 CI 消费：装机包的 `BUILD_INFO` 里记 `source_commit`，发布用的 `spk-*` tag 也指向具体提交。rebase 改写已推送提交，包和提交就对不上了，别人 fetch 还得强制。
- 上游自己也全程用 merge —— `fnos/飞牛部署与变更说明.md` 每条同步都写「采用 merge 提交，没有 rebase」。两边一致，下次同步的 merge-base 单调前进，同一处冲突只解一次。
- 真要压缩提交，只在还没推送的临时分支上做，别动 `master`。

## 4. 已知冲突面

| 路径 | 本地改了什么 | 上游会碰吗 | 冲突时怎么办 |
| --- | --- | --- | --- |
| `synology/`、`.github/`、`docs/synology-build.md` | 群晖打包链 | **从不**（`git rev-list --count upstream/master -- <路径>` 当前为 0） | 不会冲突，不用检查 |
| `README.md`（根） | 群晖化：安装步骤、出包、版本号规则、实机验证状态。「上游同步说明」那段每次同步都得重写，写法见第 6 节 | 每次发版都写 | 解法见第 5 节；2026-11-03 那次合并的唯一冲突就在这 |
| `docs/README.md` | 索引里加了群晖相关行，新增文档时要登记 | 新增专题文档时 | 单行，手工并排 |
| `web/src/components/Sidebar.vue` | 5 处文案：飞牛字样改群晖、`fpk v…` → `spk v…`、开源地址指本 fork | 会（账号下拉、布局调整） | **按语义找，别按行号**——上游加个类名行号就漂了 |
| `fnos/sea/` | 群晖版复用它的 esbuild 打包参数 | 碰过 1 次（SEA 引入） | 一般不冲突；改 `synology/build.sh` 前 diff 一眼 |
| 三个 `package.json` | 上游自己按日期改版本号 | 每次发版 | 自动合并，取上游值 |

只在群晖版存在的新文档，文件本身不会撞；要留意的是把它登记进索引的那一两行。

## 5. 冲突怎么解

这个仓库的冲突基本都是**文案冲突**，不是逻辑冲突，两边都要留。

```sh
git status                              # 未合并的文件列在 Unmerged paths（UU）
git diff --name-only --diff-filter=U    # 只要文件名
```

- 打开文件，找 `<<<<<<<` / `=======` / `>>>>>>>` 三行标记，把两段手工合成一段。**不要用 `git checkout --ours` / `--theirs`**——那会整段丢掉一边，`README.md` 和 `Sidebar.vue` 这种纯文案文件每次都会丢。
- 上游和我们改的是同一行 import 或同一组类名 → 两边都保留，合完用 `pnpm -C web typecheck` 确认没漏。这类情况在飞牛侧发生过两次，记在 `fnos/飞牛部署与变更说明.md`：`2026.11.3` 撞在 `core/src/core/worker.ts` 的 API 分发表，`2026.11.4` 撞在 `MilkTeaContent.vue` 的 import 行，两边都保留了。
- 全部解完再 `git add <那个文件>`，然后 `git commit`（默认合并信息即可）。别用 `git commit -a`，也别为了过检 `--no-verify`。
- 中途想收手：`git merge --abort`，工作区回到合并前。
- 解完必须重跑第 2 节那四条验证。冲突解错最常见的表现是测试挂或 `vue-tsc` 报错，而不是构建不出来。

## 6. 合并之后

**根 README 的「上游同步说明」每次都要重写**。六个要素缺一个就算没写完，2026-11-07 那次（合并提交 `d82df10`）的填法：

| 要素 | 填什么 |
| --- | --- |
| 上游到哪个提交 | `2bdcf37` |
| 对应的飞牛版本号 | `2026.11.7`（读 `fnos/qq-farm-bot/manifest` 的 `version`；`fnos/飞牛部署与变更说明.md` 抬头那个 `2026.11.1` 是过期的，别抄） |
| 本仓库的合并提交号 | `d82df10` |
| 带进来哪些用户可见变化 | 种植延迟 / 偷菜延迟真正生效（首块与首位可偷立即执行，其余按配置间隔，等待期间释放自动化锁，正常访友间隔 200–350ms）；设置页两项延迟加上限；奶茶无员工时雇佣页不再报错；奶茶详情直接切侧栏不再白屏；快乐不独享奖励展示与奶茶布局重做；客户端 / 微信版本升到 `1.16.3.8_20261028`，TSDK wasm 更新 |
| `core` / `web` 的 `package.json` 是否变 | 变了，三个 `package.json`（含根）都从 `20261102` 升到 `20261104`——这条要实读再写，不能按「上游发版就会 bump」推 |
| 验证到哪一步 | 四条命令通过（core 402、web 48、`vue-tsc` 无输出、`web build` 成功）；**没有用真号验证过**，上游自己也只做到安装包冒烟 |

写的时候三条纪律：

- 「合并提交就是安装包的 `source_commit`」是飞牛那边的说法，我们的 `.spk` 版本号与它无关，见下一条。
- 只写实际发生过的：没验证就写「没验证」；代码位置给文件名 + 函数名，别写行号（行号会漂）。
- PR 号可以写，但每个都要对着 `git log --oneline master..upstream/master` 核，不要凭记忆。

**新增或删除专题文档时，索引两处都要改**：`docs/README.md` 的表格，以及根 README 的「项目文档」列表（前者自身的「维护约定」要求同时更新）。这两处也正是每次同步最容易撞的单行冲突——单行，手工并排就行。

其余几项：

- **版本号与上游脱钩**：`synology/build.sh` 里 `APP_VERSION="${SPK_VERSION:-$(TZ=Asia/Shanghai date '+%Y.%m.%d')-1}"`，跟上游 manifest 的 `version` 没关系。spk 版本必须是 `YYYY.MM.DD-N`（月日补零，同日再发递增 `-N`）——DSM 把它当「主版本-feature build」两段比较，`2026.11.4` 这种没后缀的会和飞牛包混在一起。
- **上游带新依赖**（`pnpm-lock.yaml` 变了）：本机先 `pnpm install --frozen-lockfile`；CI 的依赖缓存 key 走 `hashFiles('pnpm-lock.yaml')`，会自动换新，不用手动清。
- **出包只能在 Linux**：Windows 上只能做到构建那步，`synology/build.sh` 有系统闸。走 CI（`.github/workflows/build-spk.yml`，手动触发时 `spk_version` 留空则按「上海日期-run number」，`publish_release` 决定是否连带发 Release）或在 NAS / Linux 机上跑脚本。
- **armv8 仍是未实机验证**：上游改动不会因为 CI 变绿就变成「armv8 已支持」。
- **提交和推送是两次授权**：合并完先报状态，别自己 `git push`。

## 7. 别做

- `git push --force`，或对已推送的 `master` 做 rebase。
- 把上游 tag（如 `v2026.11.4-fnos`）当本仓库的发布 tag；我们的发布 tag 前缀固定 `spk-`。
- 顺手删 `fnos/` 或「整理」上游目录结构——那是上游变更说明和打包参数的来源，群晖版还靠它对齐构建参数。
- 在同一次同步合并里夹带自己的功能改动或格式化。
