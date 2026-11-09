# Release log — missing dates & known issues

**English** | [中文](RELEASE_LOG.zh-CN.md)

Every release here is **one day of automated builds**. This file records the days that are missing, the days that only
produced one of the two product lines, and the known defects of earlier wheels — so that nobody picks up an old wheel
without knowing what is in it.

*Last updated: 2026-11-09*

---

## 1. Missing dates / single-line days

| Date | Status | Note |
|---|---|---|
| 2026-10-01 – 2026-10-05 | ❌ no release | build machine was offline (10-01 … 10-04); on top of that the nightly job aborted immediately because of an ordering bug in the build script (`set -u` + a function used before it was defined). Fixed 2026-10-06. |
| 2026-10-07 | ❌ no release | not produced |
| 2026-10-19 | ❌ no release | not produced |
| 2026-11-02 | ❌ no release | not produced |
| 2026-11-07 – 2026-11-08 | ❌ no release | the build container became unusable for the build account (container runtime permissions changed), and the nightly job still required it → aborted. Fixed 2026-11-09 by moving the build to the host (no container). |
| 2026-11-09 | ✅ dev + stable | recovered; see the CANN note in §2 |
| 2026-10-22 / 2026-10-23 / 2026-10-24 | ⚠️ stable only | dev failed to compile: `third_party/ascend/lib` still used the old API name `mlir::bufferization::ToMemrefOp`, while the prebuilt LLVM had not been built with the Ascend patch. The dev assets were removed from those releases (2026-10-23 also had a duplicate stable asset, now removed). |
| 2026-09-26 / 2026-09-27 / 2026-09-28 | ⚠️ dev only | the stable line was **skipped on purpose**: both components were unchanged (triton-ascend `main` @ `e3707df2`, AscendNPU-IR `stable` @ `693abf31`), so there was nothing new to build. The dev line rebuilt every day because AscendNPU-IR `master` moved. |

---

## 2. Known issues

### ⚠️ All wheels built **before 2026-10-25**: `bufferization.to_tensor` long form

* **Symptom** — any kernel that emits `bufferization.to_tensor` (typically from an `scf.if` that returns a tensor value)
  fails during `ConvertLinalgIRToBinary`:
  ```
  error: Dialect `' not found for custom op 'to'
  [ERROR] Failed to parse input file: .../kernel.mlir
  ```
* **Cause** — the bundled `triton-opt` was built with a prebuilt LLVM that lacked the Ascend patch, so it printed the
  *long* form `: memref<...> to tensor<...>`, while the bundled `bishengir-compile` (LLVM 19.1.7) only parses the
  *short* form `: memref<...>`.
* **Scope** — both product lines (they share the same LLVM); most kernels never emit that op, which is why it stayed
  hidden for a while.
* **Fixed** — from 2026-10-25 the LLVM is rebuilt with `llvm_patch_<pin>.patch`, so `triton-opt` prints the short form.
* **Recommendation** — use **20261025 or later**. Older wheels are only safe if you are sure your kernels never emit
  `bufferization.to_tensor`.
* Releases before 2026-10-25 carry a ⚠️ known-issue note on their release page as well.

### ⚠️ Wheels built **before 2026-09-30**: filename has no date → same name, different content

* Version strings only started carrying the date on 2026-09-30 (`3.6.0.dev<YYYYMMDD>+git<sha8>` for dev,
  `3.6.0.post<YYYYMMDD>+git<sha8>` for stable).
* Before that, the `<sha8>` in the filename was the **triton-ascend commit only** — no date, no AscendNPU-IR commit.
  So when AscendNPU-IR moved but triton-ascend did not, the filename stayed identical while the content changed.
* Example (dev, 2026-09-25 … 2026-09-28 — every wheel is named `dev0+gitfdecef82`, but AscendNPU-IR differs):

  | Date | triton-ascend (`main-dev`) | AscendNPU-IR (`master`) |
  |---|---|---|
  | 2026-09-25 | `fdecef82` | `b826066f` |
  | 2026-09-26 | `fdecef82` | `1547caf9` |
  | 2026-09-27 | `fdecef82` | `61726c82` |
  | 2026-09-28 | `fdecef82` | `81fe2a29` |

* When using those old wheels, go by the **release tag (the date)**, not by the filename.

### ℹ️ Since 2026-11-09: the stable line is compiled with an older CANN than the dev line

* CANN 2026-11-04 introduced a new in-process LLC interface (`bisheng-llc.h` +
  `libbisheng-llc.so`), and `bishengir/lib/Tools/hivmc/BishengLlcBridge.cpp` in the AscendNPU-IR **`stable` branch**
  does not compile against it yet:
  ```
  error: use of undeclared identifier 'BISHENG_LLC_OK'; did you mean 'BISHENG_LLC_OBJ'?
  error: use of undeclared identifier 'BISHENG_LLC_BAD_STATE' / '_AUX_ERROR' / '_IO_ERROR'
  ```
  The `master` branch (dev line) was already adapted; `stable` was not.
* Consequence for these wheels: the **stable** wheels are built with the CANN of 2026-09-22, the **dev** wheels with
  the CANN of 2026-11-04. That means the template libraries and the bundled `hivmc` / `bishengir` binaries come from
  slightly different compiler generations.
* This does **not** break either wheel: the binaries do not link against any CANN library — `bishengir-compile` merely
  tries to `dlopen("libbisheng-llc.so")` at run time and falls back to an external `bisheng` process when the target
  machine does not provide it (both paths produce correct results; verified by running both wheels on a machine whose
  CANN predates that library).
* It does mean: when comparing **dev vs stable performance**, do not attribute every difference to triton-ascend or
  AscendNPU-IR source changes — part of it may be the toolchain generation.

### ℹ️ Since 2026-10-10 the wheel is ~39 MB larger (not a defect)

After AscendNPU-IR MR!3967 ("support-O2-O0") the template libraries are provided per optimization level (`.O0` / `.O2`
variants), and `bishengir-compile` picks the matching bitcode at run time based on optimization level and CANN version.
All variants must ship, so `lib/` went from 9 `.bc` files to 27 (later 35–40) and the wheel grew from ~316 MB to
~355 MB (currently ~395 MB).

---

## 3. Notes for users

* Each wheel bundles its own toolchain (`bishengir-compile`, `bishengir-opt`, `hivmc`, template `.bc`); triton uses the
  bundled one first. If you install with `pip install --target` or into an isolated venv and the bundle lookup fails,
  triton silently falls back to whatever `bishengir-compile` is on `PATH` — usually an older one, which then produces
  confusing "attribute layout mismatch" errors.
* Version strings: dev = `3.6.0.dev<YYYYMMDD>+git<sha8>`, stable = `3.6.0.post<YYYYMMDD>+git<sha8>`; `<sha8>` is that
  line's triton-ascend commit for that day.
* Asset digests (sha256) are shown on each release page and can be verified with `sha256sum`.
