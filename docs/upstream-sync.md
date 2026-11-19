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

`git fetch` 偶发报 `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030e)`。这不是网络或代理坏了（`.gitconfig` 里的 `http.https://github.com/.proxy` 照常可用）：2026-11-07 那次连 `ls-remote` 都失败，隔天同一台机器直接 `git fetch upstream` 又好了。所以先原样重试一次，还不行再看 Git 构建带不带 OpenSSL 后端：

```sh
git -c http.sslBackend=openssl fetch upstream --tags   # 没有该后端时会 warning 并回落 schannel，无害
```

本机现在的 Git 是 `niugit` 构建，`openssl` 后端不可用（打 `warning: Ignoring unavailable SSL backend 'openssl'`），这种情况下只能重试或换 Git 发行版。

**判断会不会冲突**（这一步别省，先算再合）：

```sh
base=$(git merge-base master upstream/master)
git diff --name-only "$base" master            # 本地补丁碰过的文件
git diff --name-only "$base" upstream/master   # 上游改过的文件
```

两份名单的交集就是冲突面；交集为空，直接 `git merge upstream/master` 不会有冲突（2026-11-04、11-07、11-09、11-12、11-17、11-18 六次交集都为空，合并都没有冲突、直接是合并提交）。

交集非空的几次，处理方式各不相同，都值得记住：

- **2026-11-15（上游 `1597406`）**：交集是 `README.md`，上游也在改自己的「额外功能」一节。`git merge` 依然**自动合并成功、零冲突**——两边改的是 README 的不同段落，git 按行合并得开。做法是合并后 `git diff <合并前基线> HEAD -- README.md` 逐段读，确认上游删掉的奶茶七项与本地群晖化段落都正确保留。
- **2026-11-16（上游 `bb506f5`，本仓库 `8e4ebfb`）**：交集是 `README.md` + `web/src/components/Sidebar.vue`，这次两个文件都各走了一种结局。`README.md` **真的冲突了**（两边都在同一个「上游同步说明」位置写版本清单，上游改上一条横幅、本地改下一条，落在同一段）；`Sidebar.vue` 则是**自动合并成功**。所以「交集非空」时两种结果都可能出现，`git merge` 报告成功也仍要逐项核对：这次 `Sidebar.vue` 合完后专门 grep 了 `群晖|spk |飞牛` 并 `git diff upstream/master -- Sidebar.vue`，确认群晖化文案与指向本 fork 的 `REPO_URL` 都还在。别因为「自动合并没报冲突」就直接信，尤其是 `Sidebar.vue` 这种上游动得勤的文件。
- **2026-11-17 晚（上游 `93c8465`，本仓库 `5e317a0`）**：交集又只有 `README.md`，也照样真冲突了——只要上游那天也动过「上游同步说明」这一段，就必然撞。这批是至今最大一次（34 个提交、114 个文件、跨三个版本），但**冲突面依然只有 README**，说明冲突量与提交量无关，只跟「两边是否碰同一段」有关。做法：解冲突时保留上游那份更完整的「变更章节清单」（它把 2026.11.16.4 之后的节都补上了），只把本节正文换成自己的。合并前先 `git log --oneline master..upstream/master` 数一遍提交、`git show upstream/master:fnos/飞牛部署与变更说明.md` 读一遍各节，比逐个文件猜要快。
- **2026-11-19（上游 `9dbe687`，本仓库 `ec0effd`）**：交集是 `README.md`、`docs/README.md`、`Sidebar.vue` 三个，**却零冲突**。原因值得记：上游这三批只改了 `fnos/飞牛部署与变更说明.md`（自己的变更说明），根 README 与 `docs/README.md` 一行没动，所以交集里的本地文件全是我们独有、上游没碰过。教训是**交集非空 ≠ 会冲突**，只是「可能撞」的必要条件；真正决定的是两边是否落在同一段。合并前照例 `git diff <base> master -- <交集文件>` 与 `git diff <base> upstream/master -- <交集文件>` 各看一眼，就知道上游到底动没动。

还有一件跟冲突无关、但每次同步都该留意的：**上游也在往自己的仓库里叠 fork 功能**（飞牛 fork 的增强，如 2026-11-17 带进来的牧场好友等级排序、牧场最近访客，以及后来的五条调度/日志分支）。这些提交同样以 `[fnos-fork]` 标注，和本仓库的 `[fnos-fork]` 撞名但互不相关——`grep fnos-fork` 看到的并不都是自己写的，改代码前先 `git log -1` 看是谁提交的。

**交集为空也别直接合完就走：先读一遍上游的变更说明，看它有没有「我自己刻意没引入上游某段」的决定**。2026-11-18 那次就是例子：上游 `2026.11.17.3` 的说明里明确写了 #148 的 `initialFarmCheckDone` / `initialFriendCheckDone` / `ranchDeferredUntil`（牧场按低优先级闸门推迟）**与飞牛 fork 的农牧轮流调度冲突，它自己没引入**。这种「上游主动剔除」的部分，如果我们机械地全盘 merge，就会把上游扔掉的逻辑重新带回来，而且**测试不会拦**（那套逻辑原本就没有测试覆盖群晖侧的分支）。

这次的具体核对方法：合完立刻 grep 那几个标志名，确认它们**只出现在 `[fnos-fork]` 的注释里**、没有被真正接进调度：

```sh
Select-String -Path core/src/core/worker.ts -Pattern 'initialFarmCheckDone|initialFriendCheckDone|ranchDeferredUntil'
```

结果为 0 命中或只在注释里出现，才算对。反过来，上游「有意引入」的部分（那次是 `runWithRequestClass` 排队、`canContinue` 网关健康让路、`wakeRanchMarketExchange` 便便到账唤醒）要逐一确认在代码里真实存在。**遇到上游说「我不引入 X」，就把 X 当成一份负面清单来核对，而不是当它不存在。**

**合并**（用 merge，不要 rebase，理由见第 3 节）：

```sh
git merge upstream/master
```

**验证，四条都要过**。2026-11-19 那次合并（上游 `9dbe687`，三个飞牛版本一批进来）的实测：core 453 通过、web 71 通过、`vue-tsc` 无输出、`web build` 成功。**用例数会随上游增删测试双向变化**：11-15 那次上游下架奶茶 fork 功能，一次删掉 6 个 core 测试文件与 2 个 web 测试文件，core 从 414 掉到 359、web 从 52 掉到 47；11-16 上游加牧场，core 回到 387、web 回到 52；11-17 白天加好友等级与最近访客，core 到 399、web 到 55；11-17 晚上游叠了五条调度/日志分支加三个 PR，core 到 449、web 到 71；11-18 上游只合两个 PR（#147/#148）且没加测试文件，仍是 449/71；11-19 上游 #153 带进 `farm-ripening.test.js`（催熟策略），core 到 453，web 仍 71。看到数字变化先确认是不是上游增删的，别当成测试挂了或自己改错了。上游自己的变更说明里通常写了它的用例数（`2026.11.19.1` 记的是 453/71），**合完对一下这两个数**，一致就说明本地没有漏合并的测试改动。

**还要单独核一遍「默认值」**。上游改默认值时，测试全绿也不代表升级行为没变——2026-11-17 晚那次上游 #145 把 `RANCH_AUTOMATION_DEFAULTS` 里十几个 `false` 全改成 `true`，测试一条都不会响，但用户升级后牧场会开始自己干活。做法是每批合并后 `git diff <合并前基线> HEAD -- '**/DEFAULT*' '**/*defaults*' '**/config/*.ts'` 扫一遍，再判断影响面：

- 只改常量：`cloneAccountConfig` 只对值为 `undefined` 的键套默认值，**已保存过的开关不受影响**，但要写进 README 提醒「新账号/新字段是这个默认」。
- 带迁移代码：像 `fnos-claim-default-migration` 那样在启动时**主动改写老配置**（还会写标记文件保证只做一次）的，影响所有老用户，必须在 README 里单独点出来，说明改了什么、标记文件在哪、之后手动关掉会不会被改回。
- 上游改了默认值而本 fork 要保留旧默认（如「好友放蚊子」默认关）：改回来时**加 `[fnos-fork]` 注释写明原因和日期**，否则下次同步会被人当成手滑改错又改回去。

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
| `README.md`（根） | 群晖化：安装步骤、出包、版本号规则、实机验证状态。「上游同步说明」那段每次同步都得重写，写法见第 6 节 | 每次发版都写 | 解法见第 5 节；2026-11-03、2026-11-16、2026-11-17 晚三次合并的冲突都在这里，三次都撞在同一段「上游同步说明」。**上游只要动了这段就必撞**，与这批提交多少无关 |
| `docs/README.md` | 索引里加了群晖相关行，新增文档时要登记 | 新增专题文档时 | 单行，手工并排 |
| `web/src/components/Sidebar.vue` | 5 处文案：飞牛字样改群晖、`fpk v…` → `spk v…`、开源地址指本 fork | 会（账号下拉、布局调整） | **按语义找，别按行号**——上游加个类名行号就漂了 |
| `fnos/sea/` | 群晖版复用它的 esbuild 打包参数 | 碰过 1 次（SEA 引入） | 一般不冲突；改 `synology/build.sh` 前 diff 一眼 |
| 三个 `package.json` | 上游自己按日期改版本号 | 每次发版 | 自动合并，取上游值。**注意上游常常只改 `core` / `web` 两个、根的不动**（2026-11-17 晚就是这样），别顺手写「三个都变了」，实读一遍再写 |

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

**根 README 的「上游同步说明」每次都要重写**。六个要素缺一个就算没写完，2026-11-19 那次（合并提交 `ec0effd`）的填法：

| 要素 | 填什么 |
| --- | --- |
| 上游到哪个提交 | `9dbe687` |
| 对应的飞牛版本号 | `2026.11.19.1`（读 `fnos/qq-farm-bot/manifest` 的 `version`；`fnos/飞牛部署与变更说明.md` 抬头那个 `2026.11.1` 是过期的，别抄） |
| 本仓库的合并提交号 | `ec0effd` |
| 带进来哪些用户可见变化 | 牧场巨大图鉴一键已读；按牧场场景同步好友名单并优先显示昵称；背包出售、成熟后自动领图鉴奖励（`ranch_illustrated` 默认开）；21 级棚自动解锁；集市兑换拆成便便 / 松果两个独立开关（`ranch_market_organic_poop` / `_pinecone`，默认都开）；化肥催熟策略 `normal_ripen` / `organic_ripen`；窝 / 棚分组与幼崽补栏顺序；好友巡查续跑与次数停排 |
| `core` / `web` 的 `package.json` 是否变 | 只有 `web` 变（`20261119`），根 `20261116`、`core` `20261117` 未变——这条要实读再写，别按「上游发版就会 bump」推 |
| 验证到哪一步 | 四条命令通过（core 453、web 71、`vue-tsc` 无输出、`web build` 成功），与上游 `2026.11.19.1` 自述的用例数一致；**没有用真号验证过**，上游自己也只做到模拟网关冒烟 |

这次还多了一类要写进正文的东西：**上游拆开或新增了默认开启的开关**。#162 把 `ranch_market_organic` 拆成两个独立开关（默认都开），#160 新增 `ranch_illustrated`（默认开）。和单纯改常量不同，这类改动要看有没有迁移代码：`migrateRanchMarketAutomation` 只给缺失的键填值、已明确设置的独立开关优先，所以老用户不会因为升级突然开始兑松果；但 `ranch_illustrated` 是纯新增字段，老配置里没有这个键，`cloneAccountConfig` 会套上默认值，**等于升级即生效**。两者都得进「升级前要知道」。判断方法是合完直接看默认值文件里新键有没有配套的归一化 / 迁移函数：

```sh
git diff <合并前基线> HEAD -- '**/*defaults*' core/src/config core/src/types/config.ts core/src/models/store/account-config.ts
```

那批还新增了一个要素，将来碰到同类情况要照做：**上游在变更说明里写了「我刻意没引入 X」时，X 必须作为负面清单逐项核对**。这次是 #148 的牧场低优先级闸门（`initialFarmCheckDone` / `initialFriendCheckDone` / `ranchDeferredUntil`），上游因为和农牧轮流调度冲突没有引入，我们 merge 后 grep 确认它们只出现在 `[fnos-fork]` 注释里，并在 README 里单独说明「我们也没接、为什么」。

2026-11-17 晚那批的正文结构同样值得照抄：**先分「上游原始项目的 PR」和「上游飞牛 fork 自己的分支」两块**（两者混在一起时不分就写成一锅粥），再单独列「升级前要知道的三件事」讲默认值变更，最后才是协议/版本号和验证情况。凡是会改用户既有设置的，一律进「升级前要知道」。写的时候四条纪律：

- **删功能的版本要在 README 里明说「升级会少什么、想留就别升」**。2026-11-15 那次下架奶茶自动化就是例子——用户升级后功能直接消失，光写「合并了 PR」不够。
- 「合并提交就是安装包的 `source_commit`」是飞牛那边的说法，我们的 `.spk` 版本号与它无关，见下一条。
- 只写实际发生过的：没验证就写「没验证」；代码位置给文件名 + 函数名，别写行号（行号会漂）。
- PR 号可以写，但每个都要对着 `git log --oneline master..upstream/master` 核，不要凭记忆。

**新增或删除专题文档时，索引两处都要改**：`docs/README.md` 的表格，以及根 README 的「项目文档」列表（前者自身的「维护约定」要求同时更新）。这两处也正是每次同步最容易撞的单行冲突——单行，手工并排就行。

其余几项：

- **版本号与上游脱钩**：`synology/build.sh` 自己按「构建日期 + 当天第几个包」选号，跟上游 manifest 的 `version` 没关系。spk 版本必须是 `YYYY.MM.DD-N`（月日补零，`N` 为当天序号、每天从 `1` 重新算）——DSM 把它当「主版本-feature build」两段比较，`2026.11.4` 这种没后缀的会和飞牛包混在一起。
- **上游带新依赖**（`pnpm-lock.yaml` 变了）：本机先 `pnpm install --frozen-lockfile`；CI 的依赖缓存 key 走 `hashFiles('pnpm-lock.yaml')`，会自动换新，不用手动清。
- **出包只能在 Linux**：Windows 上只能做到构建那步，`synology/build.sh` 有系统闸。走 CI（`.github/workflows/build-spk.yml`，手动触发时 `spk_version` 留空则按「上海日期-当天第几个包」自动选号，`publish_release` 决定是否连带发 Release）或在 NAS / Linux 机上跑脚本。
- **armv8 仍是未实机验证**：上游改动不会因为 CI 变绿就变成「armv8 已支持」。
- **提交和推送是两次授权**：合并完先报状态，别自己 `git push`。

## 7. 别做

- `git push --force`，或对已推送的 `master` 做 rebase。
- 把上游 tag（如 `v2026.11.4-fnos`）当本仓库的发布 tag；我们的发布 tag 前缀固定 `spk-`。
- 顺手删 `fnos/` 或「整理」上游目录结构——那是上游变更说明和打包参数的来源，群晖版还靠它对齐构建参数。
- 在同一次同步合并里夹带自己的功能改动或格式化。
