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
