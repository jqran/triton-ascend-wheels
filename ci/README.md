# ws_daily —— 主线每日构建（两条产品线，二合一 wheel）

每天 **01:00**（cron，`daily_build.sh all`）在同一台 x86 构建机（Ubuntu 24.04、无 sudo、docker 容器内构建）上串行构建并发布**两条产品线**：

| 变体 | 源码 | release 里的 asset 形如 | 说明 |
|---|---|---|---|
| **dev** | triton-ascend `main-dev` + AscendNPU-IR `master` | `triton_ascend-3.6.0.dev0+git<sha8>-*.whl` | 开发线，最新特性 |
| **stable** | triton-ascend `main` + AscendNPU-IR `stable` | `triton_ascend-3.6.0+git<sha8>-*.whl` | 稳定线（发布分支 + sync 快照） |

两条线各自独立工作区、独立构建缓存、独立 state，**产物共用一个 `out/`**，并按**日期**合并发布成同一条 release
（tag 形如 `20260924`，两条线各一个 wheel asset —— 见下方「发布」）。

## 每条线的流程

1. 同步两个仓库到最新（`fetch` → `checkout -f -B` → `reset --hard` → `clean -fd`，保证 git status 干净；子模块更新，
   llvm-project 优先走本地种子 `~/workspace/AscendNPU-IR/third-party/llvm-project`，不够新自动回退 gitcode）
2. 容器 **ubuntu20**（Ubuntu 20.04 / glibc 2.31）内构建 AscendNPU-IR：`bishengir-compile/opt` + `hivmc` + 9 个模板库 `.bc`
   （`-t --bisheng-compiler $(readlink -f ~/Ascend/cann)/tools/bisheng_compiler/bin`，当前 CANN = 9.3.0）
   - 📦 **不再打包 `hivmc-a5`**（2026-09-25 起的包生效）。它本来只是 `hivmc` 的**同内容副本**（上游 packaging 也直接
     `cp`），而源码里 `hivmc-a5` **0 个调用点**：A5（Ascend950PR）走 `bishengir-compile` 内的 regbase 流水线（in-process，
     起子进程 `bishengir-compile-a5` 的分支被注释掉了），A3 路径也只用 `hivmc --version` 做版本探测
     （`$BISHENG_INSTALL_PATH` → `$PATH`，失败仅 warning）。a5 实测：删掉后 `chunk_gla_fwd_o_gk` 10/10 通过、
     PATH 金丝雀 0 次拦截。收益：wheel 少一份独立压缩 ≈43MB
3. 整理 payload → 构建 TA wheel（经上游 `TRITON_ASCEND_BISHENGIR_PATH` 把 payload 打进 `triton/backends/ascend/bishengir/`，二合一）
4. 打包到 `out/<日期>_ta<sha8>_npuir<sha8>_<variant>/`（wheel + payload tar.gz + BUILD_INFO）+ 刷新 `out/INDEX.md`、`out/latest-<variant>`
5. 两条线都建完后**合并发布成一条 release**（tag = 日期，如 `20260924`；两条线各一个 wheel asset，说明由 BUILD_INFO
   自动生成：对照表 + 每变体的 commit/message、子模块指针、glibc / CANN 版本、wheel md5、已知问题）→
   **https://github.com/jqran/triton-ascend-wheels**
6. 保留 14 天且至少 3 份；两个仓库 commit 与上次成功构建相同则跳过（`FORCE=1` 强制）

## 目录布局

```
~/ws_daily/
├── daily_build.sh  publish_release.sh  check_failure.sh  ack_last_failure.sh  README.md
├── src/ build/ payload/ state/      # dev 线（沿用历史路径，保住热构建缓存）；state/ 里另有 health.txt、ATTENTION
├── stable/{src,build,payload,state} # stable 线
├── out/                             # 两条线共用：<日期>_..._dev/、<日期>_..._stable/、INDEX.md、latest-dev|latest-stable
└── logs/                            # daily_dev_<日期>.log、daily_stable_<日期>.log、publish_<日期>.log
```

## 失败看板（登录就知道）

构建出问题时不用去翻日志：`state/ATTENTION` 一旦存在，**登录 x86 / 新开 shell 就会打印醒目提示**
（`.bashrc` 里只有 3 行调用，逻辑在 `check_failure.sh`；没问题时完全静默、零打扰）：

```
╔════════════════════════════════════════════════════════════════════════╗
║   ⚠️   ws_daily 每日构建：上一轮有问题，请看一眼                     ║
╚════════════════════════════════════════════════════════════════════════╝
  2026-09-25 01:23:41  overall=FAIL   dev=FAIL
  updated: 2026-09-25 01:23:41     overall: FAIL     detail:  dev=FAIL
    … 快速动作：看日志 / 发布日志 / out/INDEX.md / 消除提示 …
```

- **判定规则**：任一变体 `FAIL`/`PARTIAL_TA_ONLY`/`CONTAINER_DOWN`、发布真失败（退出码非 0 非 2）、
  或**子进程退出码非 0 但状态文件没更新**（被 kill/崩溃）→ 置 `ATTENTION`；
  只有「`all` 跑完且两条线都 `OK`（不是 `SKIPPED_UNCHANGED`）」或手动 ack 才清除
  （跳过不清，避免长期失败被"没变更"掩盖）
- **锁占用（另一实例正在跑）**：本轮让位 → 写 `overall: SKIPPED_LOCK`，**不动**登录提示、退出码 0
  （靠"状态文件是否在本次启动之后被写过"判断，避免拿上一晚的 OK 误判成功、误清提示）
- **看详情**：`cat ~/ws_daily/state/health.txt`（总体 + 各变体最近一次 + 日志路径）
- **消除提示**：`~/ws_daily/ack_last_failure.sh`（把内容追加进 health.txt 作历史，然后删 `ATTENTION`）
- **回退**：`.bashrc` 里删掉 `# >>> ws_daily failure notice` 标记块即可；备份见 `~/ws_daily_backup/<日期>/bashrc.before-banner`

## 常用命令

```bash
~/ws_daily/daily_build.sh dev            # 只跑开发线
~/ws_daily/daily_build.sh stable         # 只跑稳定线
~/ws_daily/daily_build.sh all            # 两条线串行（cron 用的就是这个）
FORCE=1 ~/ws_daily/daily_build.sh stable # 强制重建（commit 没变也编）
tail -f ~/ws_daily/logs/daily_dev_$(date +%Y%m%d).log
ls ~/ws_daily/out/latest-dev/ ; cat ~/ws_daily/out/INDEX.md ; cat ~/ws_daily/state/last_run.txt
cat ~/ws_daily/state/health.txt          # 失败看板：最近一次总体状态
~/ws_daily/ack_last_failure.sh           # 消除登录提示
```

可调环境变量：`TA_BRANCH`/`NP_BRANCH`（覆盖默认分支）、`JOBS`（默认 64）、`KEEP_DAYS`/`KEEP_MIN`（14/3）、`FORCE`、
`PUBLISH`（0 关闭发布）、`CONTAINER`、`LLVM_PREBUILT`、`CANN_ROOT`/`CANN_ENV`/`CANN_BISHENG`。

## 发布（GitHub release）

**口径：一个日期一条 release**（tag = 日期，如 `20260924`），当天两条线各一个 wheel asset：

| 变体 | 源码 | asset |
|---|---|---|
| dev | triton-ascend `main-dev` + AscendNPU-IR `master` | `triton_ascend-3.6.0.dev0+git<sha8>-*.whl` |
| stable | triton-ascend `main` + AscendNPU-IR `stable` | `triton_ascend-3.6.0+git<sha8>-*.whl` |

- **为什么合并**（2026-09-24 定）：GitHub 的 release **列表顺序没有任何 API 字段可设置** —— 实测
  `created_at`（其实是 tag 指向 commit 的 committer date）/`updated_at`/`published_at` 都不能决定可见顺序，
  且列表接口有几十秒的索引延迟；两条 release 的 `created_at` 相同时组内顺序未定义，于是同一晚的 dev/stable
  会在页面上翻来覆去（出现过 `stable dev dev stable`）。合并成一条后页面每天一行，顺序天然固定。
  （脚本仍会用合成 commit 把 release 的 `created_at` 设成当天构建时间，跨天顺序也稳定。）
- `all` 模式：两条线都构建完才由父进程发布（子进程带 `PUBLISH_DEFER=1`）；单跑 `dev`/`stable` 时构建完即发布，
  会**并入当天那条 release**（说明按变体分节，`<!-- variant:xxx -->` 标记，只替换本次涉及的分节）
- 说明由 BUILD_INFO 自动生成：头部一张「两条线对照表」，然后每个变体一节（组件 commit + message、子模块指针、
  二合一工具链清单、安装命令、已知问题）
- 凭据二选一：`~/.config/ws_daily/gh_token`（fine-grained PAT，只授权该仓库 Contents 读写）或 **x86 上已登录的 gh**
  （`~/.local/bin/gh`，脚本自动 `gh auth token`；cron 下用绝对路径）。都没有则**优雅跳过**（退出码 2，只记日志）
- 幂等：release 已存在 → 合并更新说明（未涉及变体保持原样）；同名 asset 已存在 → 跳过上传
- 手动补发：`~/ws_daily/publish_release.sh ~/ws_daily/out/<目录> [<另一个目录> ...]`（可一次传两条线）
- ⚠️ 上传 asset 时 `name=` 必须 URL 编码，否则 `+` 被当空格、GitHub 存成 `.`，说明里的下载链接会 404（脚本已处理）

## 已知坑（都已在脚本里处理）

- **换 CANN 版本后必须删 `CMakeCache.txt` 重配**：否则 build.sh 复用旧配置，ninja 里还是旧 ccec 路径。脚本按
  `<build>/.ws_daily_cann` 标记自动检测并删除缓存
- **旧 CANN（<9.3.0）编译设备调试模板会失败**：`CCE_PRINT_CC` 宏在 9.1.1 的 ccec 里没有，而这些 `.bc` 是 `meta_op.*.bc`
  的链接输入 → 9 个模板库全链不出来。脚本兜底：`ninja -k 0` → 从 FAILED 行解析源文件 → 备份并替换成空 TU → 重建 install →
  还原源码（清单写进 BUILD_INFO）。CANN 9.3.0 起该宏已提供，实测 0 失败、无需顶替
- **构建目录不能随便搬家**：CMakeCache/ninja 里是绝对路径，移动工作区会导致全量重编（dev 线因此保留在原路径）
- 容器 `ubuntu20` 重启策略是 `no`，脚本每次先 `docker start` 兜底
