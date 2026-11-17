# Release log —— 缺日期与已知问题

[English](RELEASE_LOG.md) | **中文**

这个仓库每个 release 对应**一天**的自动构建。本文件记录：**哪几天没有包**、**哪几天只出了一条线**、
以及**早期 wheel 的已知缺陷** —— 免得有人拿到老包却不知道坑在哪。

*最后更新：2026-11-17*

---

## 1. 缺日期 / 只有一条线

| 日期 | 状态 | 说明 |
|---|---|---|
| 2026-10-01 – 2026-10-05 | ❌ 无 release | 构建机离线（10-01 … 10-04）；另外当时夜间脚本有个"调用早于定义"的 bug（`set -u` 下直接中止），2026-10-06 已修 |
| 2026-10-07 | ❌ 无 release | 当日未产出 |
| 2026-10-19 | ❌ 无 release | 当日未产出 |
| 2026-11-02 | ❌ 无 release | 当日未产出 |
| 2026-11-07 – 2026-11-08 | ❌ 无 release | 构建容器对构建账户不可用（容器运行权限变化），而夜间任务当时仍依赖容器 → 直接中止；2026-11-09 改成宿主机直接编译后恢复 |
| 2026-11-10 | ✅ dev + stable | 已恢复 —— 两条线都在 `cmake --build` 报 **exit 127**：ccache 被挪位置后，构建缓存里固化的旧工具链绝对路径失效。现在夜间任务在构建前会检测并改写这类失效路径。两个 wheel 都做了 smoke 验证（`max|diff| = 0.0`）|
| 2026-11-09 | ✅ dev + stable | 已恢复；CANN 相关说明见 §2 |
| 2026-10-22 / 2026-10-23 / 2026-10-24 | ⚠️ 仅 stable | dev 线编译失败：`third_party/ascend/lib` 还在用旧 API 名 `mlir::bufferization::ToMemrefOp`，而预编译 LLVM 没打 Ascend 补丁。这些 release 里的 dev 资产已移除（2026-10-23 另有一个重复的 stable 资产，也已移除） |
| 2026-09-26 / 2026-09-27 / 2026-09-28 | ⚠️ 仅 dev | stable 线是**有意跳过**：两个组件都没更新（triton-ascend `main` @ `e3707df2`、AscendNPU-IR `stable` @ `693abf31`），没有新东西可编。dev 线每天重建是因为 AscendNPU-IR `master` 天天在动 |

---

## 2. 已知问题

### ⚠️ **2026-10-25 之前**构建的所有 wheel：`bufferization.to_tensor` 长形式

* **现象** —— 任何会生成 `bufferization.to_tensor` 的 kernel（典型来源：返回 tensor 值的 `scf.if`）在
  `ConvertLinalgIRToBinary` 阶段失败：
  ```
  error: Dialect `' not found for custom op 'to'
  [ERROR] Failed to parse input file: .../kernel.mlir
  ```
* **原因** —— 包里的 `triton-opt` 是用**未打 Ascend 补丁**的预编译 LLVM 编出来的，打印成**长形式**
  `: memref<...> to tensor<...>`；而包里的 `bishengir-compile`（LLVM 19.1.7）只认**短形式** `: memref<...>`。
* **影响面** —— dev / stable 两条线都受影响（共用同一份 LLVM）；只是多数 kernel 不生成该 op，所以长期没暴露。
* **修复** —— 2026-10-25 起 LLVM 改为打 `llvm_patch_<pin>.patch` 重编，`triton-opt` 打印短形式。
* **建议** —— 用 **20261025 及以后**的包；更早的包只在确认 kernel 不生成 `bufferization.to_tensor` 时才安全。
* 2026-10-25 之前的 release 页面上也加了 ⚠️ known-issue 标注。

### ⚠️ **2026-09-30 之前**构建的 wheel：文件名不带日期 → 同名但内容不同

* 版本号从 2026-09-30 起才带日期（dev `3.6.0.dev<YYYYMMDD>+git<sha8>`、stable `3.6.0.post<YYYYMMDD>+git<sha8>`）。
* 在那之前，文件名里的 `<sha8>` **只是 triton-ascend 的 commit** —— 没有日期，也没有 AscendNPU-IR 的 commit。
  所以 AscendNPU-IR 动了、triton-ascend 没动时，**文件名不变但内容是新的**。
* 实例（dev，2026-09-25 … 2026-09-28 —— 文件名都叫 `dev0+gitfdecef82`，实际 AscendNPU-IR 各不相同）：

  | 日期 | triton-ascend（`main-dev`） | AscendNPU-IR（`master`） |
  |---|---|---|
  | 2026-09-25 | `fdecef82` | `b826066f` |
  | 2026-09-26 | `fdecef82` | `1547caf9` |
  | 2026-09-27 | `fdecef82` | `61726c82` |
  | 2026-09-28 | `fdecef82` | `81fe2a29` |

* 取这些老包时，请以**release tag（日期）**为准，不要按文件名判断是不是同一份。

### ℹ️ 2026-11-09 起：stable 线用的 CANN 比 dev 线旧

* CANN 2026-11-04 引入了新的 in-process LLC 接口（`bisheng-llc.h` + `libbisheng-llc.so`），而 AscendNPU-IR
  **`stable` 分支**的 `bishengir/lib/Tools/hivmc/BishengLlcBridge.cpp` 还没适配：
  ```
  error: use of undeclared identifier 'BISHENG_LLC_OK'; did you mean 'BISHENG_LLC_OBJ'?
  error: use of undeclared identifier 'BISHENG_LLC_BAD_STATE' / '_AUX_ERROR' / '_IO_ERROR'
  ```
  `master` 分支（dev 线）已适配，`stable` 还没。
* 对这批 wheel 的影响：**stable** 包用 2026-09-22 的 CANN 编、**dev** 包用 2026-11-04 的 CANN 编 →
  模板库和包内的 `hivmc` / `bishengir` 二进制来自略有差异的编译器代。
* **不会导致包不能用**：这些二进制不链接任何 CANN 库 —— `bishengir-compile` 运行期只是尝试
  `dlopen("libbisheng-llc.so")`，目标机没有该库时回退到外部 `bisheng` 进程（两条路径都出正确结果；
  已用两台环境实测：包在 CANN 版本更旧、没有该库的机器上跑最小 kernel，结果一致）。
* 但请注意：**做 dev 与 stable 的性能对比时**，差异不能全部归给 triton-ascend / AscendNPU-IR 的源码 ——
  有一部分可能来自工具链代次。

### ✅ 已修复并重发 —— 2026-11-10 ～ 2026-11-15 的 stable 包曾冻结工具链（自报 2026-11-09）

* **现象（字节级核对）** —— 这些 stable 包里的 `bishengir-compile`：

  | 日期 | 包内 `bishengir-compile` md5 | 大小 | 自报版本 |
  |---|---|---|---|
  | 2026-11-09 | `a5adef892525` | 207.87 MB | `0c87c174`（2026-11-09） |
  | **2026-11-10 … 2026-11-15**（6 个包） | **全部 `f03ca847199e`** | 207.87 MB | `0c87c174`（2026-11-09） |
  | 2026-11-17（修复后） | `96ece04f1e21` | 210.16 MB | `1389120d`（2026-11-17） |

  **dev** 线每天都不一样（如 11-14 `5ad6374ff2b3`、11-15 `449c4a684c07`、11-16 `46c1e12eb1d5`、11-17 `74b27984791c`）。
  也就是说：这些 stable 包的 **triton-ascend 部分是新编的**，只有 AscendNPU-IR / bishengir 这一层冻在 2026-11-10 那次链接结果上
  （比 dev 小约 2.3 MB）。
* **原因** —— 一个工具链兼容性 pin 让 stable 线用更旧的 CANN 构建，而它编不了更新的 AscendNPU-IR 代码；
  链接失败被"回退收集"处理成了"把安装目录里上一次的二进制拷回来"，构建仍打成功日志 → 11-09 的二进制被**
  静默**重复发出去。
* **影响** —— 这些 stable 包**不含** 2026-11-10 之后 AscendNPU-IR 的任何改动（md5 与版本号双重佐证）；triton-ascend 部分是新的，缺的只是 AscendNPU-IR / bishengir 这一层。
* **2026-11-17 已修复** —— 去掉该 pin（两条产品线现在用同一个 CANN 版本）、构建目录全量重配
  （`build.sh` 退出码 0，无被顶替的源文件），包内三件工具全部变成 `1389120d7732 2026-11-17`。
  daily 构建还新增了**版本自检**：比对"包内工具自报的 commit"与"源码 commit"，不一致就报错（并让下次运行强制重配），
  结论写进 `BUILD_INFO.txt`。2026-11-17 的 stable asset 已重建并替换。
* **已于 2026-11-17 21:48 重发** —— 这 6 天都按各自当天的 commit 对重新构建并替换了 asset（与发布 digest 逐字节一致）：

  | 日期 | 重编后工具链自报的 AscendNPU-IR | 新 sha256（前 12） |
  |---|---|---|
  | 2026-11-10 | `ec72093ae9f9` | `60fa72eb4499` |
  | 2026-11-11 | `ec72093ae9f9` | `049a1a4ef627` |
  | 2026-11-12 | `8dc16e1d5530` | `fac8f7028e83` |
  | 2026-11-13 | `395c9c5646f9` | `9b67f03ee3b1` |
  | 2026-11-14 | `0bfb79a16bee` | `de9c8b21eebf` |
  | 2026-11-15 | `af999e735d8e` | `ccaac0c901f1` |

  这几个包现在可以放心用；只关心最新工具链的话，用 2026-11-17 之后的构建即可。

### ℹ️ 2026-10-10 起包体 +~39 MB（不是缺陷）

AscendNPU-IR MR!3967（"support-O2-O0"）之后，模板库按优化级别提供（`.O0` / `.O2` 各一套），
`bishengir-compile` 运行期按优化级别和 CANN 版本挑对应位码，所以所有变体都要随包发：
`lib/` 从 9 个 `.bc` 变成 27 个（后续 35–40 个），wheel 从 ~316 MB 涨到 ~355 MB（现在 ~395 MB）。

---

## 3. 使用提示

* 每个 wheel 都自带工具链（`bishengir-compile` / `bishengir-opt` / `hivmc` + 模板库 `.bc`），triton 优先用包内的。
  如果用 `pip install --target` 或隔离 venv 导致找不到包内的 bishengir，triton 会**静默回退**到 `PATH` 上的旧版本 ——
  这类"属性布局不匹配"的错误大多是这个原因。
* 版本号：dev = `3.6.0.dev<YYYYMMDD>+git<sha8>`，stable = `3.6.0.post<YYYYMMDD>+git<sha8>`；`<sha8>` 是该线当天的
  triton-ascend commit。
* 每个 release 页面都列了 asset 的 sha256，可用 `sha256sum` 校验。
