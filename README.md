# triton-ascend-wheels

**English** | [中文](README.zh-CN.md)

Daily **automated builds** of [triton-ascend](https://github.com/triton-lang/triton-ascend), published as GitHub releases.

Each release corresponds to **one day** of builds. Every wheel is a **self-contained bundle**: triton-ascend itself plus the
AscendNPU-IR bishengir toolchain (`bishengir-compile` / `bishengir-opt` / `hivmc` + 9 template `.bc` libraries). Once the wheel
is installed, the toolchain comes with it — there is no separate bishengir deployment step.

> Since 2026-09-25 `hivmc-a5` is no longer bundled: it was merely a byte-identical copy of `hivmc` (one binary under two names)
> and has no call sites in the source tree (A5 uses the in-process regbase pipeline inside `bishengir-compile`; the A3 path only
> calls `hivmc --version` for version detection).
> **Releases from 20260924 and earlier still ship `hivmc-a5` (13 entries inside the wheel) — that is expected.**

## How the builds are made

| Item | Value |
|---|---|
| Trigger | Automatically every day at 01:00 (CST), building two product lines; skipped when neither repository has new commits |
| **dev line** | triton-ascend `main-dev` + AscendNPU-IR `master` |
| **stable line** | triton-ascend `main` + AscendNPU-IR `stable` |
| Source sync | `fetch` to the latest, `reset --hard` for a clean worktree, submodule pointers updated accordingly |
| Build environment | **Ubuntu 20.04 / glibc 2.31** (x86_64 Docker container) |
| Python | cp311 |
| Platform | linux_x86_64 |

Every release page lists the **full commit ids** of all components (including the `llvm-project` / `shmem` / `torch-mlir`
submodule pointers), the build container and **glibc version**, the wheel **md5**, and any known issues for that build.

## Install

```bash
pip install --no-deps --force-reinstall <download URL of the wheel in the release>
```

External dependencies you have to provide yourself: the CANN toolkit and torch-npu (currently paired with 2.7.1.post8).

Runtime requirements of the wheels themselves: Linux x86_64, CPython 3.11, **glibc >= 2.29**, **libstdc++ >= GLIBCXX_3.4.26**
(built on Ubuntu 20.04).

## Naming conventions

- Release tag: the **date**, e.g. `20260924` (one release per day, one wheel asset per product line)
- Release title: `2026-09-28 · dev + stable` (the `[每日] ` prefix was dropped on 2026-09-28)
- Wheel file name: `triton_ascend-<version>+git<8 hex>-cp311-cp311-linux_x86_64.whl`, and the **version string carries the build date**
  (dev line `triton_ascend-3.6.0.dev<YYYYMMDD>+git<8 hex>-...whl`, stable line `triton_ascend-3.6.0.post<YYYYMMDD>+git<8 hex>-...whl`)
- ⚠️ Wheels built **before 2026-09-30** do not have the date in the file name (`3.6.0.dev0+git<8 hex>` / `3.6.0+git<8 hex>`)
- ⚠️ Releases **before 2026-09-24** had **one release per product line** (tags like `20260923-ta7b4ee867-npuir15a14c58-dev`);
  those have been **migrated** into per-date releases (`20260922` / `20260923` / `20260924`, each holding two wheels) and the old tags were deleted

## Verifying a download

```bash
md5sum triton_ascend-*.whl          # compare with the md5 printed on the release page
python - <<'PY'
import zipfile, glob
z = zipfile.ZipFile(glob.glob("triton_ascend-*.whl")[0])
n = [x for x in z.namelist() if "bishengir/" in x]
print(len(n), "bishengir entries")   # 12 (3 binaries + 9 .bc); releases from 20260924 and earlier have 13 (one extra hivmc-a5)
PY
```

## The two product lines

The repository builds both lines every day at 01:00 and **publishes them in a single release** (tag = the date):

| Line | Sources | Asset |
|---|---|---|
| dev | triton-ascend `main-dev` + AscendNPU-IR `master` | `triton_ascend-3.6.0.dev<YYYYMMDD>+git<8 hex>-cp311-cp311-linux_x86_64.whl` |
| stable | triton-ascend `main` + AscendNPU-IR `stable` | `triton_ascend-3.6.0.post<YYYYMMDD>+git<8 hex>-cp311-cp311-linux_x86_64.whl` |

> Why one release per day: the GitHub release list has no sortable field (measured: `created_at` / `updated_at` / `published_at`
> are none of them a usable sort key), so with two releases per night the dev/stable pair swapped places on the page. Merging
> gives exactly one row per day and a stable order.

**All historical releases are kept** (nothing is pruned automatically), so you can roll back to an earlier build
(as of 2026-09-30 the page lists nine releases, `20260922` … `20260930`). Downloading:

```bash
# latest night (both product lines)
gh release download --repo jqran/triton-ascend-wheels

# a specific date
gh release download 20260930 --repo jqran/triton-ascend-wheels

# only one line
gh release download 20260930 --repo jqran/triton-ascend-wheels --pattern '*.dev*.whl'    # dev (older names *.dev0*.whl match too)
gh release download 20260930 --repo jqran/triton-ascend-wheels --pattern '*.post*.whl'   # stable (older wheels have no 'post'; drop --pattern to get everything)
```

## Build scripts

The wheels in this repository are produced by the scripts in `ci/`, which you can reuse directly:

| File | Purpose |
|---|---|
| `ci/daily_build.sh` | Main daily build script: sync both repositories → build AscendNPU-IR inside a container (bishengir + hivmc + 9 template `.bc` libraries) → inject them into the triton-ascend wheel through `TRITON_ASCEND_BISHENGIR_PATH` (the self-contained bundle) → package → publish. Supports the `dev` / `stable` / `all` modes; in `all` mode both lines are built before a single merged release is published |
| `ci/publish_release.sh` | Publishes the wheels of one day (possibly several directories) into **one** release (tag = the date, release notes generated from BUILD_INFO and split into per-variant sections). Idempotent: an existing release gets its notes merged/updated (sections that are not part of this run are preserved), existing assets are skipped |
| `ci/README.md` | Usage notes: directory layout, environment variables, publishing rules, known pitfalls (delete the CMake cache when switching CANN, never move the build directory, asset names must be URL-encoded, ...) |

Requirements: Linux + Docker (Ubuntu 20.04 container) + git + python3 + curl. All paths are derived from `${HOME}` /
environment variables, so the scripts are not tied to a specific machine.
