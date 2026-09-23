# triton-ascend-wheels

[triton-ascend](https://github.com/triton-lang/triton-ascend) 的**每日自动构建** wheel 发布点。

每个 release 对应一次构建，产物是**二合一 wheel**：triton-ascend 本体 + AscendNPU-IR 的 bishengir 工具链
（`bishengir-compile` / `bishengir-opt` / `hivmc` / `hivmc-a5` + 9 个模板库 `.bc`），装完即自带工具链，
不需要再单独往环境里部署 bishengir。

## 构建方式

| 项 | 值 |
|---|---|
| 触发 | 每天 01:00（CST）自动构建；两个仓库 commit 都没变时跳过 |
| 源码 | triton-ascend `main-dev` + AscendNPU-IR `master`，fetch 到最新、`reset --hard` 保证工作树干净、子模块同步 |
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

- release tag：`<日期>-ta<8位>-npuir<8位>`，例如 `20260922-taabc8e821-npuire534c923`
- wheel 文件名：`triton_ascend-<版本>+git<8位>-cp311-cp311-linux_x86_64.whl`

## 校验

```bash
md5sum triton_ascend-*.whl          # 与 release 说明里的 md5 对照
python - <<'PY'
import zipfile, glob
z = zipfile.ZipFile(glob.glob("triton_ascend-*.whl")[0])
n = [x for x in z.namelist() if "bishengir/" in x]
print(len(n), "bishengir entries")   # 期望 13（4 个 bin + 9 个 .bc）
PY
```

## 注意

- 这些包由个人 CI 自动产出，**非官方发布**；正式版本请用 PyPI / 华为云镜像上的 triton-ascend。
- 产物内含 AscendNPU-IR 编译出的工具链二进制，仅供内部验证使用。

## 两条产品线与历史包

仓库每天（01:00）自动构建**两条线**，release 标题以 `[dev]` / `[stable]` 开头：

| 线 | 源码 | tag 形如 |
|---|---|---|
| dev | triton-ascend `main-dev` + AscendNPU-IR `master` | `20260923-ta7b4ee867-npuir15a14c58-dev` |
| stable | triton-ascend `main` + AscendNPU-IR `stable` | `20260923-tad1c8b179-npuir85271f87-stable` |

**历史 release 全部保留**（不自动清理），便于回滚到早先的构建。找各线最新包：

```bash
# 需要 gh（或直接用网页筛选 tag 前缀）
gh release list --repo jqran/triton-ascend-wheels | grep '\[dev\]'    | head -1
gh release list --repo jqran/triton-ascend-wheels | grep '\[stable\]' | head -1
```

下载指定 tag 的 wheel：

```bash
gh release download <tag> --repo jqran/triton-ascend-wheels --pattern '*.whl'
```

## 构建脚本

本仓库的包由 `ci/` 里的脚本自动产出，可直接复用：

| 文件 | 作用 |
|---|---|
| `ci/daily_build.sh` | 每日构建主脚本：同步两个仓库 → 容器内构建 AscendNPU-IR（bishengir + hivmc + 9 个模板库 `.bc`）→ 经 `TRITON_ASCEND_BISHENGIR_PATH` 打进 TA wheel（二合一）→ 打包 → 发布。支持 `dev` / `stable` / `all` 两条产品线 |
| `ci/publish_release.sh` | 把产物目录里的 wheel 发到 release（说明由 BUILD_INFO 自动生成），幂等：release 已存在则更新说明、asset 已存在则跳过 |
| `ci/README.md` | 使用说明：目录布局、环境变量、已知坑（换 CANN 需删 CMakeCache、构建目录不能搬家、asset 名需 URL 编码等） |

依赖：Linux + docker（Ubuntu 20.04 容器）+ git + python3 + curl；路径都通过 `${HOME}` / 环境变量推导，不绑定具体机器。
