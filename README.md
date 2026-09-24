# triton-ascend-wheels

[triton-ascend](https://github.com/triton-lang/triton-ascend) 的**每日自动构建** wheel 发布点。

每个 release 对应**一天**的构建，产物是**二合一 wheel**：triton-ascend 本体 + AscendNPU-IR 的 bishengir 工具链
（`bishengir-compile` / `bishengir-opt` / `hivmc` + 9 个模板库 `.bc`），装完即自带工具链，
不需要再单独往环境里部署 bishengir。

> 2026-09-25 起不再随包提供 `hivmc-a5`：它只是 `hivmc` 的同内容副本（同一颗二进制两个名字），源码里没有任何
> 调用点（A5 走 `bishengir-compile` 内的 regbase 流水线，A3 只用 `hivmc --version` 做版本探测）。
> **20260924 及更早的 release 里仍带 `hivmc-a5`（wheel 内 13 项），是正常的。**

## 构建方式

| 项 | 值 |
|---|---|
| 触发 | 每天 01:00（CST）自动构建两条线；两个仓库 commit 都没变时跳过 |
| **dev 线** | triton-ascend `main-dev` + AscendNPU-IR `master` |
| **stable 线** | triton-ascend `main` + AscendNPU-IR `stable` |
| 同步 | fetch 到最新、`reset --hard` 保证工作树干净、子模块指针同步更新 |
| 环境 | **Ubuntu 20.04 / glibc 2.31**（x86_64 docker 容器） |
| Python | cp311 |
| 平台 | linux_x86_64 |

每个 release 的说明里都给出**各组件完整 commit id**（含子模块 `llvm-project` / `shmem` / `torch-mlir` 指针）、
构建容器与 **glibc 版本**、wheel 的 **md5**，以及该次构建的已知问题。

## 安装

```bash
pip install --no-deps --force-reinstall <release 中 wheel 的下载地址>
```

外部依赖自行确保：CANN toolkit、torch-npu（当前配套 2.7.1.post8）。

## 命名约定

- release tag：**日期**，例如 `20260924`（一天一条 release，两条线各一个 wheel asset）
- release 标题：`[每日] 2026-09-24 · dev + stable`
- wheel 文件名：`triton_ascend-<版本>+git<8位>-cp311-cp311-linux_x86_64.whl`
  （dev 线带 `.dev0`：`triton_ascend-3.6.0.dev0+git<8位>-...`）
- ⚠️ **2026-09-24 之前**的 release 是**每条线一条**（tag 形如 `20260923-ta7b4ee867-npuir15a14c58-dev`）；
  这批历史已**迁移**成按日期的 release（`20260922`/`20260923`/`20260924`，每条含两个 wheel），旧 tag 已删除

## 校验

```bash
md5sum triton_ascend-*.whl          # 与 release 说明里的 md5 对照
python - <<'PY'
import zipfile, glob
z = zipfile.ZipFile(glob.glob("triton_ascend-*.whl")[0])
n = [x for x in z.namelist() if "bishengir/" in x]
print(len(n), "bishengir entries")   # 12（3 个 bin + 9 个 .bc）；20260924 及更早的包是 13（多一个 hivmc-a5）
PY
```

## 两条产品线

仓库每天（01:00）自动构建两条线，**合并发布在同一条 release 里**（tag = 日期）：

| 线 | 源码 | asset |
|---|---|---|
| dev | triton-ascend `main-dev` + AscendNPU-IR `master` | `triton_ascend-3.6.0.dev0+git<8位>-cp311-cp311-linux_x86_64.whl` |
| stable | triton-ascend `main` + AscendNPU-IR `stable` | `triton_ascend-3.6.0+git<8位>-cp311-cp311-linux_x86_64.whl` |

> 为什么一天一条：GitHub 的 release 列表顺序无法设置（实测 `created_at`/`updated_at`/`published_at` 都不是排序键），
> 一天两条时同一晚的 dev/stable 会在页面上互换位置。合并后页面每天一行，顺序天然固定。

**历史 release 全部保留**（不自动清理），便于回滚到早先的构建；截至 2026-09-24 页面为 `20260922` / `20260923` / `20260924` 三条。下载：

```bash
# 最新一晚（两条线的 wheel 一起下）
gh release download --repo jqran/triton-ascend-wheels

# 指定日期
gh release download 20260924 --repo jqran/triton-ascend-wheels

# 只要某一条线
gh release download 20260924 --repo jqran/triton-ascend-wheels --pattern '*dev0*.whl'   # dev
gh release download 20260924 --repo jqran/triton-ascend-wheels --pattern '*git*.whl'    # 两个都下
```

## 构建脚本

本仓库的包由 `ci/` 里的脚本自动产出，可直接复用：

| 文件 | 作用 |
|---|---|
| `ci/daily_build.sh` | 每日构建主脚本：同步两个仓库 → 容器内构建 AscendNPU-IR（bishengir + hivmc + 9 个模板库 `.bc`）→ 经 `TRITON_ASCEND_BISHENGIR_PATH` 打进 TA wheel（二合一）→ 打包 → 发布。支持 `dev` / `stable` / `all` 两条产品线；`all` 模式下两条线都建完再合并发布 |
| `ci/publish_release.sh` | 把一天（可多个）产物目录里的 wheel 发到**同一条** release（tag = 日期，说明由 BUILD_INFO 自动生成、按变体分节）。幂等：release 已存在则合并更新说明（未涉及的分节保留）、asset 已存在则跳过 |
| `ci/README.md` | 使用说明：目录布局、环境变量、发布口径、已知坑（换 CANN 需删 CMakeCache、构建目录不能搬家、asset 名需 URL 编码等） |

依赖：Linux + docker（Ubuntu 20.04 容器）+ git + python3 + curl；路径都通过 `${HOME}` / 环境变量推导，不绑定具体机器。

## 注意

- 这些包由个人 CI 自动产出，**非官方发布**；正式版本请用 PyPI / 华为云镜像上的 triton-ascend。
- 产物内含 AscendNPU-IR 编译出的工具链二进制，仅供内部验证使用。
