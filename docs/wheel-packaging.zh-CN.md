# NPUIR（bishengir 工具链）+ TA（triton-ascend）二合一 wheel 的构建与打包

> 重点讲**打包**：bishengir 是怎么被塞进 `triton-ascend` 的 wheel、最终落在哪、为什么那样落、哪些环节会静默出错。
> 源码依据（当前在用的树）：`triton-ascend/setup.py`、`triton-ascend/third_party/ascend/build/setup_patch.py`、
> `triton-ascend/third_party/ascend/backend/utils.py`；编排脚本见本仓库 `ci/daily_build.sh`。
> 文中的行号随版本会漂移，看函数名即可。

---

## 0. 一句话总览

**NPUIR 只负责产出三件二进制 + 一堆模板库 `.bc`；TA 的 `setup.py` 在 `build_py` 阶段把整个目录树拷进
`build_lib/triton/backends/ascend/bishengir/`，再走正常的 `install_lib → bdist_wheel` 打成 zip。**
所以"合一"不是两个 wheel 拼起来，而是**TA 的 wheel 里多了一个数据目录**。

```
 AscendNPU-IR 源码 ──build.sh──▶ $NP_BUILD/bin/{bishengir-compile, bishengir-opt, hivmc}
                                $NP_BUILD/lib/*.bc（当前 wheel 内 26 个：host.{O0,O2}.bc + meta_op.*.{O0,O2}.bc + *.920r1.* …）
                                        │
                     daily_build.sh 组装（§6）  │  cp 三件 + cp *.bc（过滤 *.linked.bc）
                                        ▼
                              $PAYLOAD/{bin,lib}          ← 也叫 "bishengir payload"
                                        │  export TRITON_ASCEND_BISHENGIR_PATH=$PAYLOAD
                                        ▼
 triton-ascend 源码 ──python setup.py bdist_wheel──▶
        ├─ build_ext：编 triton/_C/*.so（+ triton-opt / triton-mlir-opt，strip）
        ├─ build_py ：先正常收集 python 包 → 再（AscendBuildPy）把 $PAYLOAD 整树拷到
        │              build_lib/triton/backends/ascend/bishengir/
        └─ bdist_wheel：install_lib 整目录 → 打 zip → dist/triton_ascend-<ver>-cp311-cp311-linux_x86_64.whl
                                        │
                                        ▼
                       一个 wheel ≈ triton-ascend + 自带 bishengir 工具链
```

---

## 1. 两个仓库的分工

| 仓库 | 贡献给 wheel 的东西 | 在哪一步 |
|---|---|---|
| **AscendNPU-IR**（bishengir/hivmc） | `bishengir-compile`、`bishengir-opt`、`hivmc` 三件二进制 + `lib/*.bc` 模板库 | **完全独立构建**，TA 只"搬"不"编" |
| **triton-ascend**（TA） | python 包（`triton/`、`triton/backends/ascend/…`）+ `triton/_C/*.so`（含 `libtriton.so`）+ `triton-opt` 等 | `build_ext` 编 C++，`build_py` 收 python，`bdist_wheel` 打包 |

关键点：**TA 不编译 NPUIR**。`TRITON_BUILD_NPUIR` 默认就是 `OFF`（`setup_patch.py::_set_default_env_vars`），
二合一走的是"外部预构建 payload + 环境变量指路"这条路。

---

## 2. wheel 里的最终布局（`unzip -l` 视角）

```
triton_ascend-<版本>-cp311-cp311-linux_x86_64.whl
├── triton/
│   ├── __init__.py, runtime/, language/, compiler/ …        ← TA 的 python 包
│   ├── _C/
│   │   ├── libtriton.so, libentryC.so                       ← build_ext 产物
│   │   └── triton-opt（+ triton-mlir-opt，若该次构建产出）    ← _copy_ascend_tools 拷入 + strip
│   └── backends/ascend/
│       ├── utils.py, compiler.py, driver.py …               ← 运行时；_get_npucompiler_path 在这里
│       └── bishengir/                                       ★ 二合一的部分
│           ├── bin/bishengir-compile     (215 MB，实测 20261125 包)
│           ├── bin/bishengir-opt         (224 MB)
│           ├── bin/hivmc                 (179 MB)
│           └── lib/host.O0.bc, host.O2.bc,
│               meta_op.{aic,aiv,mix}.{c220,c310}.{O0,O2}.bc …（当前 26 个 .bc）
└── triton_ascend-<版本>.dist-info/                          ← METADATA / RECORD / WHEEL
```

- `bishengir/` 下**不再有** `hivmc-a5`（2026-09-25 起不打包，省 ~43 MB；A5 走 `bishengir-compile` 内部的 regbase 流水线，源码里 `hivmc-a5` 0 个调用点）。
- `bishengir/` 下**没有** `backend/` 这一层 —— 这是最容易搞错的地方，见 §3.4。

---

## 3. 合包机制（按执行顺序，全部在 TA 侧）

### 3.1 入口：`setup_patch.py` 把 `build_py` 换成了自己的子类

`triton-ascend/third_party/ascend/build/setup_patch.py` 在 import 期**运行时打补丁**（不改源码文件），它做的事情包括：

```python
class AscendBuildPy(_OrigCMakeBuildPy):     # _OrigCMakeBuildPy = Triton 自带的 CMakeBuildPy
    def run(self):
        super().run()                        # ① 先跑正常流程：收集 python 包进 build_lib
        _copy_bishengir_payload(self.build_lib)   # ② 再把 bishengir payload 拷进去

mod.CMakeBuildPy = AscendBuildPy            # ③ 顶替
```

`setup.py` 里 `cmdclass={"build_py": CMakeBuildPy, ...}`，因为 ③ 已经把 `mod.CMakeBuildPy` 换掉，
所以 `bdist_wheel` 走到 `build_py` 时执行的是**打了补丁的那个**。

> **为什么挂在 `build_py` 而不是 `bdist_wheel`？** `build_py` 是"把文件摆进 `build_lib`"的阶段，
> 此时塞文件正好赶在 `install_lib`（它会把 `build_lib` 整目录搬到 `build/…/install`）之前；
> 挂 `bdist_wheel` 就太晚了 —— 那时 `install_lib` 已经跑过。

### 3.2 定位 payload：环境变量优先，其次仓内

```python
_BISHENGIR_PAYLOAD_ENV = "TRITON_ASCEND_BISHENGIR_PATH"

def _get_bishengir_payload_source():
    raw_path = os.getenv(_BISHENGIR_PAYLOAD_ENV)
    if raw_path:                                   # ① 外部预构建目录（日常构建用这条）
        source = Path(raw_path).expanduser().resolve(); origin = _BISHENGIR_PAYLOAD_ENV
    elif _npuir_build_enabled():                    # ② TRITON_BUILD_NPUIR=ON 时用仓内产物
        source = _REPO_ROOT / "third_party" / "ascend" / "backend" / "bishengir"
    else:
        return None                                 # ③ 两者都没有 → 不出合一包（只出普通 TA wheel）

    # 硬校验：目录必须真的像个 bishengir payload
    required = [source/"bin"/"bishengir-compile", source/"bin"/"bishengir-opt", source/"lib"]
    if not source.is_dir() or any(not p.exists() for p in required):
        raise RuntimeError(f"{origin} must name a BishengIR directory containing "
                           "bin/bishengir-compile, bin/bishengir-opt, and lib")
    return source
```

要点：
- **校验是"必需三项"**，缺任一项直接 `RuntimeError`（不会悄悄出一个"半个工具链"的 wheel）。
  注意它**不校验** `bin/hivmc`，也不校验 `.bc` 的完整性 —— 这些由构建脚本自己查（§6）。
- `lib` 只要求"存在"即可，**里面空不空它不管** → 模板库缺失不会在打包阶段报错（历史事故见 §10）。

### 3.3 拷贝：先删后拷（这一点很关键）

```python
def _copy_bishengir_payload(build_lib):
    source = _get_bishengir_payload_source()
    if source is None: return
    destination = Path(build_lib) / "triton" / "backends" / "ascend" / "bishengir"
    if destination.exists():
        shutil.rmtree(destination)                 # ★ 先整目录删掉
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    print(f"Bundled BishengIR payload from {source} into {destination}")
```

- **`rmtree` 先删**：避免上一轮的旧文件（比如已被上游删掉的 `hivmc-a5`、旧命名的 `.bc`）残留在 `build_lib` 里
  被一起打进 wheel。`build_lib` 是跨次复用的。
- `symlinks=True`：payload 里的符号链接原样保留（不展开成副本）。

### 3.4 目标路径为什么是 `triton/backends/ascend/bishengir`（而不是多一层 `backend/`）

因为运行时的查找逻辑写死了这个相对位置（`triton/backends/ascend/utils.py`）：

```python
def _get_npucompiler_path():
    ascend_dir = os.path.dirname(os.path.abspath(__file__))     # …/triton/backends/ascend
    npu_compiler_path = os.path.join(ascend_dir, "bishengir", "bin", "bishengir-compile")
    if os.path.exists(npu_compiler_path):
        env["PATH"] = os.path.dirname(npu_compiler_path) + ":" + env["PATH"]   # 顺带把 bin 前置进 PATH
    else:
        npu_compiler_path = shutil.which("bishengir-compile")   # 退 1：PATH
        if npu_compiler_path is None:
            … knobs.ascend.npu_compiler_path …                  # 退 2：TRITON_NPU_COMPILER_PATH
            npu_compiler_path = os.path.join(npu_compiler_root, "npuc")
    return npu_compiler_path, env
```

源码树里 bishengir 住在 `third_party/ascend/backend/bishengir`，但打包时 `backend/` 这层会被"压平"
（`backend/*` 直接成为 `triton/backends/ascend/*`），所以 payload 也必须按**压平后的位置**放 —— 多一层就找不到，
运行时就会静默回落到 PATH 上的别的 `bishengir-compile`（典型后果：`FixpipeDualDstModeAttr` 之类的属性错配）。

### 3.5 为什么拷进 `build_lib` 就一定会进 wheel

- `setup.py` 有 `include_package_data=True`、`packages=get_packages()`；
- 但真正决定的是执行顺序：`build_py` 结束后 `build_lib` 里已经有 `triton/backends/ascend/bishengir/**`，
  随后 `install_lib` **整目录拷贝**（不是按 `package_data` 白名单挑），`bdist_wheel` 再把 `install` 目录 zip 起来。
- 所以：**不需要**改 `MANIFEST.in`、**不需要**在 `package_data` 里列 `*.bc`/二进制。
  反过来，如果你把拷贝放在 `build_py` 之前（或用 `package_data`），就会受"数据文件白名单"限制。

### 3.6 其它打包细节

| 环节 | 行为 |
|---|---|
| `build_ext` | 编 `triton/_C/{libtriton.so, libentryC.so}`；`subprocess.check_call` 被 `setup_patch` 包了一层（`patched_check_call`），用于在 cmake 失败时给更明确的报错 |
| `_copy_ascend_tools` | 把 `bin/triton-opt`、`third_party/ascend/bin/triton-mlir-opt`（存在才拷）拷进 `triton/_C/`，`chmod 755` + **`strip --strip-all`**（只为这两个减体积，**bishengir payload 不做 strip**） |
| manylinux | `IS_MANYLINUX=FALSE` 时按 `linux_x86_64` 出包；置 `TRUE` 会走 `auditwheel repair`，目标策略固定 `manylinux_2_34_<arch>`（日常构建用 `linux_x86_64`） |
| `zip_safe=False` | wheel 解压安装，不 zipimport |

---

## 4. 环境变量全表（构建 TA wheel 时）

| 变量 | 谁设 | 作用 |
|---|---|---|
| `TRITON_ASCEND_BISHENGIR_PATH` | `daily_build.sh`（`BISH=`） | **payload 目录**（含 `bin/`、`lib/`）；设了才有合一包 |
| `TRITON_WHEEL_NAME` | `setup_patch.py` 默认 `triton_ascend` | wheel/包名前缀 → `triton_ascend-*.whl` |
| `TRITON_WHEEL_VERSION_SUFFIX` | `daily_build.sh` | 版本后缀：dev 线 `<YYYYMMDD>`、stable 线 `.post<YYYYMMDD>` |
| `TRITON_BUILD_NPUIR` | 默认 `OFF` | 置 `ON` 则改为**在 TA 里编 NPUIR**（`build_npuir.py`），产物同样落到 `third_party/ascend/backend/bishengir` |
| `TRITON_BUILD_WITH_CCACHE` | 默认 `true` | 让 cmake 用 ccache（系统里有 `ccache` 即可；没有就装一个，或在 PATH 上放个透传脚本） |
| `TRITON_BUILD_WITH_CLANG_LLD` | 默认 `true` | 用 clang + lld 编 `_C` |
| `TRITON_BUILD_PROTON` / `TRITON_BUILD_TD` | 默认 `OFF` | 关掉 proton / TD，减少构建面 |
| `TRITON_APPEND_CMAKE_ARGS` | `daily_build.sh` | 追加 `-DTRITON_BUILD_UT=OFF`（不编单测） |
| `LLVM_SYSPATH` | `ci/daily_build.sh` | 指向**预编译 LLVM**（版本按 `cmake/llvm-hash.txt` 的 pin，并打好 `third_party/ascend/patch/llvm_patch_<pin>.patch`）；缺它或版本不对 → `ToMemrefOp`/`to_tensor` 那类问题 |
| `MAX_JOBS` | `daily_build.sh` | 限制 Triton 自身 cmake 的并行度（默认按 CPU 数，256 核会开 `-j512`，在多用户机上反而更慢） |

---

## 5. 版本号与文件名

```
triton_ascend-<base><suffix>+git<sha8>-cp311-cp311-linux_x86_64.whl
   base   = triton-ascend/version.txt 的内容（现在 3.6.0 / 3.6.0-dev）
   suffix = dev 线：<YYYYMMDD>        → setuptools 归一化成 .dev<YYYYMMDD>
            stable 线：.post<YYYYMMDD>
   +git<sha8> = 该线当天的 triton-ascend commit
```

- 从 2026-09-30 起版本号才带日期；**在那之前文件名不含日期**，而 `<sha8>` 只是 TA 的 commit →
  可能出现"同一天不同内容但同名"（NPUIR 变了、TA 没变）。这份历史包袱见 `RELEASE_LOG.md`。
- **suffix 里不能带 `+`**：会和追加的 `+git` 组成两个加号，非法 PEP 440。
- wheel 的 python/ABI 标签固定 `cp311-cp311`（构建环境是 conda `py311`）。
- 校验口径：`python -c "import importlib.metadata as m; print(m.version('triton-ascend'))"`。

---

## 6. payload 侧：`daily_build.sh` 怎么组装（打包前）

```bash
PAYLOAD=$ROOT/payload                        # 每次重建前 rm -rf

rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD/bin" "$PAYLOAD/lib"
cp -f "$NP_BUILD/bin/bishengir-compile" "$NP_BUILD/bin/bishengir-opt" "$NP_BUILD/bin/hivmc" "$PAYLOAD/bin/"
for f in "$NP_BUILD"/lib/*.bc; do                    # 只收最终产物
  case "$(basename "$f")" in *.linked.bc) continue;; esac   # 排除 llvm-link 中间文件
  cp -f "$f" "$PAYLOAD/lib/"
done
chmod 755 "$PAYLOAD"/bin/*

# 模板库完整性：每个基名至少要有 O0 或 O2 变体（2026-10-10 起上游按优化级别生成）
EXPECT_BC="host meta_op.aic.c220 meta_op.aic.c310 meta_op.aiv.c220 meta_op.aiv.c310 \
           meta_op.mix.aic.c220 meta_op.mix.aic.c310 meta_op.mix.aiv.c220 meta_op.mix.aiv.c310"
for b in $EXPECT_BC; do
  [ -f "$PAYLOAD/lib/$b.bc" ] || [ -f "$PAYLOAD/lib/$b.O0.bc" ] || [ -f "$PAYLOAD/lib/$b.O2.bc" ] || MISSING_BC="$MISSING_BC $b.bc"
done
```

然后：

```bash
ENTRY=setup.py
BISH="export TRITON_ASCEND_BISHENGIR_PATH=$PAYLOAD;"
(cd "$TA_REPO" && export LLVM_SYSPATH=… MAX_JOBS=64 \
   TRITON_WHEEL_VERSION_SUFFIX='.post20261125' \
   TRITON_BUILD_WITH_CCACHE=true TRITON_BUILD_WITH_CLANG_LLD=true TRITON_BUILD_PROTON=OFF \
   TRITON_APPEND_CMAKE_ARGS='-DTRITON_BUILD_UT=OFF'
 eval "$BISH python $ENTRY bdist_wheel")

# 落盘记录（BUILD_INFO.txt）里会写：
#   wheel 内 bishengir 条目: <解 wheel 数出来的条数>
#   模板库条目: <payload/lib 下 .bc 个数>
#   bishengir 版本: <$PAYLOAD/bin/bishengir-opt --version 的前几行>
# 另外把 payload 单独打一份 tar.gz（排查/回滚用，不随 wheel 发布也可以）
tar -czf "$OUTDIR/bishengir-payload-npuir${NP8}.tar.gz" -C "$PAYLOAD" .
```

**为什么要单独留一份 payload tar.gz**：wheel 是 zip，不能直接看里面二进制的 mtime；payload tar 能证明
"这次到底是哪次编的"。历史事故（2026-11-17）就是靠比 `bin/bishengir-compile` 的 md5/`--version` 才发现
包里塞的是 6 天前的产物。

---

## 7. 装完之后，运行时怎么用到包内工具链

1. `triton/backends/ascend/utils.py::_get_npucompiler_path()` 先看
   `<site-packages>/triton/backends/ascend/bishengir/bin/bishengir-compile` 在不在 → 在就用它，并把它所在目录**前置进 `PATH`**；
2. 不在才 `shutil.which("bishengir-compile")`（PATH）；
3. 再不行看 `TRITON_NPU_COMPILER_PATH`（`knobs.ascend.npu_compiler_path`）。

自检一行：
```bash
python -c "from triton.backends.ascend.utils import _get_npucompiler_path as f; print(f()[0])"
# 期望：…/site-packages/triton/backends/ascend/bishengir/bin/bishengir-compile
```

⚠️ **两个常见误判**
- `pip install --target <dir>` 或"复制 python 目录"的操作**可能不带 `bishengir/`**（它不在 `package_data` 白名单里，
  是 build_py 后追加的），于是静默回落到 PATH 上的旧 `bishengir-compile` → 报 `expected mlir::hivm::FixpipeDualDstModeAttr`
  这类属性错配，看着像用例写错，其实是工具链版本不对。
- `BISHENG_INSTALL_PATH` **与 bishengir 目录无关**：它是 **ccec（bisheng 编译器）** 的路径，只在"编模板库"时用。

另外：`bishengir-compile` 运行期会尝试 `dlopen("libbisheng-llc.so")`（CANN 2026-11-04 起提供）；
目标机没有就打 `[INFO] libbisheng-llc.so not found` 并回退到外部 `bisheng` 进程 —— 两条路都出正确结果。

---

## 8. 体积构成（为什么 340~400 MB）

| 组成 | 未压缩 | 说明 |
|---|---|---|
| `bishengir/bin/bishengir-compile` | 215 MB | 大头（实测 20261125 包） |
| `bishengir/bin/bishengir-opt` | 224 MB | 与 compile 共享大量代码，但 zip **不做内容去重** |
| `bishengir/bin/hivmc` | 179 MB | A5/A3 流水线在同一颗 binary 里 |
| `bishengir/lib/*.bc` | 数十 MB | 26 个（`host` + `meta_op.*` 各自的 `O0`/`O2`，含 `920r1` 变体） |
| `triton/_C/*.so` + python | 数十 MB | `libtriton.so` 较大 |
| **合计（zip 压缩后）** | **342 MB**（近期 340–400 MB） | payload 目录未压缩约 880 MB |

2026-10-10 起 wheel 大了 ~39 MB，是因为上游 MR!3967「support-O2-O0」让模板库按优化级别各出一套
（`bishengir-compile` 运行期按优化级别/CANN 版本挑位码），三套都必须随包发 —— 不是打包 bug。

---

## 9. 一个 wheel 是否"合格"：四步自检

```bash
W=triton_ascend-3.6.0.post20261125+gitXXXXXXX-cp311-cp311-linux_x86_64.whl

# ① 顶层布局对不对（应该有 backends/ascend/bishengir/{bin,lib}，且没有 backend/ 这层）
unzip -l "$W" | grep -E "backends/ascend/bishengir/(bin|lib)/" | head

# ② 三件二进制都在，且 .bc 数量正常（当前 26，历史区间 20~40）
unzip -l "$W" | grep -c "backends/ascend/bishengir/bin/"
unzip -l "$W" | grep -c "backends/ascend/bishengir/lib/.*\.bc"

# ③ 包内工具链自报的 commit **必须等于** 当天的 AscendNPU-IR commit
python3 - "$W" <<'PY'
import sys, zipfile, os, tempfile
w = sys.argv[1]; d = tempfile.mkdtemp()
with zipfile.ZipFile(w) as zf:
    for n in zf.namelist():
        if n.endswith("/bishengir/bin/bishengir-opt"):
            p = os.path.join(d, "bishengir-opt"); open(p,"wb").write(zf.read(n)); os.chmod(p, 0o755)
os.system(f"{d}/bishengir-opt --version | head -1")
PY

# ④ 装到隔离 venv，确认运行时用的是**包内**那份
python -m venv --system-site-packages /tmp/v && /tmp/v/bin/pip install --no-deps "$W"
/tmp/v/bin/python -c "from triton.backends.ascend.utils import _get_npucompiler_path as f; print(f()[0])"
```

判据口径（很重要）：**"日志打了 ✅ 产物齐全" 不等于产物是这次的**。唯一可信的是 ③ ——
把 wheel 里的二进制跑 `--version`，看它自报的 commit 是否等于源码 HEAD（当天的 NPUIR commit）。

---

## 10. 常见坑（都踩过）

| 坑 | 现象 | 原因 / 处理 |
|---|---|---|
| **包里塞的是旧二进制** | `✅ 产物齐全`，但 `--version` 里的 commit/日期偏旧；连续几天 md5 相同 | 构建失败时"回退收集"会把 `install/bin/` 的旧二进制拷进 `bin/`。已在 `daily_build.sh` 加**版本自检**（自报 commit ≠ 源码 HEAD → 告警 + 强制下次重配） |
| `.bc` 缺失不报错 | wheel 里 `bishengir/lib` 条目变少（当前正常值 26），或用例编译期报找不到位码 | `_get_bishengir_payload_source` 只校验 `lib` 目录存在，**不校验内容** → 靠 `daily_build.sh` 的 `EXPECT_BC` 兜底 |
| `lib/*.bc` 只增不减（旧产物残留） | 同一目录里出现两种命名/多代 `.bc` | payload 每次 `rm -rf` 重建 ✓；但 `$NP_BUILD/lib` 是"覆盖不删除"，异常时会残留 → 打包时已过滤 `*.linked.bc`，仍建议核对条目数 |
| 多一层 `backend/` | 运行时找不到包内 `bishengir-compile`，静默用 PATH 上的旧版本 | payload 必须落到 `triton/backends/ascend/bishengir`（压平后路径），见 §3.4 |
| 文件名不带日期（2026-09-30 之前） | 不同内容同名 | 现在版本号带日期 ✓ |
| `TRITON_WHEEL_VERSION_SUFFIX` 带 `+` | `Invalid version` / 打包失败 | suffix 只能是 `<YYYYMMDD>` 或 `.post<YYYYMMDD>` |
| 单测/额外子项目把 wheel 撐大或编挂 | 编得慢、依赖多 | `TRITON_APPEND_CMAKE_ARGS=-DTRITON_BUILD_UT=OFF`、`TRITON_BUILD_PROTON=OFF`、`TRITON_BUILD_TD=OFF` |
| `-j512` 反而慢 | 全量重编耗时数小时 | 机器是多用户共用，`MAX_JOBS=64` |

---

## 11. 手工复现一个合一包（最短路径）

```bash
# 0) 前置：CANN + 预编译 LLVM + ccache
source <CANN>/set_env.sh
export LLVM_SYSPATH=/path/to/prebuilt-llvm     # 版本按 cmake/llvm-hash.txt，并打好 Ascend 的 llvm patch
export PATH=$HOME/.local/bin:$PATH

# 1) 编 NPUIR（产物在 $NP_BUILD/bin、$NP_BUILD/lib）—— 具体参数见 ci/daily_build.sh 里的 NP_CMD
cd <AscendNPU-IR> && ./build-tools/build.sh --c-compiler $LLVM_SYSPATH/bin/clang \
  --cxx-compiler $LLVM_SYSPATH/bin/clang++ '--add-cmake-options=-DLLVM_ENABLE_LLD=ON' \
  --build-type Release -j 64 --enable-assertion -o <NP_BUILD> -t --bisheng-compiler <CANN>/tools/bisheng_compiler/bin

# 2) 组 payload
P=/tmp/bishengir-payload; rm -rf $P; mkdir -p $P/bin $P/lib
cp -f <NP_BUILD>/bin/{bishengir-compile,bishengir-opt,hivmc} $P/bin/
for f in <NP_BUILD>/lib/*.bc; do case "$(basename $f)" in *.linked.bc) continue;; esac; cp -f $f $P/lib/; done
chmod 755 $P/bin/*

# 3) 出 wheel
cd <triton-ascend>
TRITON_ASCEND_BISHENGIR_PATH=$P TRITON_WHEEL_VERSION_SUFFIX=.post20261125 \
TRITON_BUILD_WITH_CCACHE=true TRITON_BUILD_WITH_CLANG_LLD=true TRITON_BUILD_PROTON=OFF \
TRITON_APPEND_CMAKE_ARGS=-DTRITON_BUILD_UT=OFF MAX_JOBS=64 \
python setup.py bdist_wheel

# 4) 自检（§9 的四步，尤其是 ③ 版本对齐）
```

---

## 12. 相关文件一览

| 作用 | 文件 |
|---|---|
| 打包补丁（合包逻辑都在这里） | `triton-ascend/third_party/ascend/build/setup_patch.py`（`_get_bishengir_payload_source`、`_copy_bishengir_payload`、`AscendBuildPy`、`_copy_ascend_tools`） |
| 打包入口 | `triton-ascend/setup.py`（`cmdclass`、`include_package_data`、`get_triton_version_suffix`） |
| 运行时查找 | `triton-ascend/third_party/ascend/backend/utils.py::_get_npucompiler_path` |
| 仓内编 NPUIR（可选路径） | `triton-ascend/third_party/ascend/build/build_npuir.py`（`TRITON_BUILD_NPUIR=ON`） |
| 生产编排 | `ci/daily_build.sh`（NPUIR 构建 → payload → wheel → 发布 → 同步） |
| 问题日期/已知缺陷 | 仓库 `RELEASE_LOG.md` / `RELEASE_LOG.zh-CN.md` |
