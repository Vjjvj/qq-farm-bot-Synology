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

**判断会不会冲突**（这一步别省，先算再合）：

```sh
base=$(git merge-base master upstream/master)
git diff --name-only "$base" master            # 本地补丁碰过的文件
git diff --name-only "$base" upstream/master   # 上游改过的文件
```

两份名单的交集就是冲突面；交集为空，直接 `git merge upstream/master` 不会有冲突。

**合并**（用 merge，不要 rebase，理由见第 3 节）：

```sh
git merge upstream/master
```

**验证，四条都要过**。2026-11-04 那次合并的实测：core 402 通过、web 48 通过、`vue-tsc` 无输出、`web build` 成功。

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
| `README.md`（根） | 群晖化：安装步骤、出包、版本号规则、实机验证状态 | 每次发版都写 | 2026-11-03 那次合并的唯一冲突就在这；按语义合并，别整段取一边 |
| `docs/README.md` | 索引里加了群晖相关行 | 新增专题文档时 | 单行，手工并排 |
| `web/src/components/Sidebar.vue` | 5 处文案：飞牛字样改群晖、`fpk v…` → `spk v…`、开源地址指本 fork | 会（账号下拉、布局调整） | **按语义找，别按行号**——上游加个类名行号就漂了 |
| `fnos/sea/` | 群晖版复用它的 esbuild 打包参数 | 碰过 1 次（SEA 引入） | 一般不冲突；改 `synology/build.sh` 前 diff 一眼 |
| 三个 `package.json` | 上游自己按日期改版本号 | 每次发版 | 自动合并，取上游值 |

只在群晖版存在的新文档，文件本身不会撞；要留意的是把它登记进索引的那一两行。

## 5. 合并之后

- **版本号与上游脱钩**：`synology/build.sh` 里 `APP_VERSION="${SPK_VERSION:-$(TZ=Asia/Shanghai date '+%Y.%m.%d')-1}"`，跟上游 manifest 的 `version` 没关系。spk 版本必须是 `YYYY.MM.DD-N`（月日补零，同日再发递增 `-N`）——DSM 把它当「主版本-feature build」两段比较，`2026.11.4` 这种没后缀的会和飞牛包混在一起。
- **上游带新依赖**（`pnpm-lock.yaml` 变了）：本机先 `pnpm install --frozen-lockfile`；CI 的依赖缓存 key 走 `hashFiles('pnpm-lock.yaml')`，会自动换新，不用手动清。
- **出包只能在 Linux**：Windows 上只能做到构建那步，`synology/build.sh` 有系统闸。走 CI（`.github/workflows/build-spk.yml`，手动触发时 `spk_version` 留空则按「上海日期-run number」，`publish_release` 决定是否连带发 Release）或在 NAS / Linux 机上跑脚本。
- **armv8 仍是未实机验证**：上游改动不会因为 CI 变绿就变成「armv8 已支持」。
- **提交和推送是两次授权**：合并完先报状态，别自己 `git push`。

## 6. 别做

- `git push --force`，或对已推送的 `master` 做 rebase。
- 把上游 tag（如 `v2026.11.4-fnos`）当本仓库的发布 tag；我们的发布 tag 前缀固定 `spk-`。
- 顺手删 `fnos/` 或「整理」上游目录结构——那是上游变更说明和打包参数的来源，群晖版还靠它对齐构建参数。
- 在同一次同步合并里夹带自己的功能改动或格式化。
