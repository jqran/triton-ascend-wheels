#!/bin/bash
# =============================================================================
# daily_build.sh [dev|stable|all]      默认 dev
#   dev    = triton-ascend main-dev + AscendNPU-IR master   （开发线）
#   stable = triton-ascend main     + AscendNPU-IR stable   （稳定线）
#   all    = 先 dev 再 stable，串行（cron 用这个）
#
#   工作区：dev 沿用历史路径 ~/ws_daily/{src,build,payload,state}（保住热构建缓存）；stable 在 ~/ws_daily/stable/ 下
#   共用：~/ws_daily/out（产物 + INDEX.md + latest-<variant> 软链）、~/ws_daily/logs
#
#   流程：同步两个仓库到最新（工作树强制干净、子模块更新）→ 容器 ubuntu20 内构建 AscendNPU-IR
#   （bishengir-compile/opt + hivmc + 9 个模板库 .bc）→ 经上游 TRITON_ASCEND_BISHENGIR_PATH 打进 TA wheel
#   （二合一）→ 打包到 out/<日期>_ta<sha8>_npuir<sha8>_<variant>/ → 发布到 GitHub release
#
#   发布口径（2026-09-24 起）：**一个日期一条 release**（tag = 日期，如 20260924），两条线各一个
#   wheel asset —— GitHub 的 release 列表顺序不可设置，合并后页面每天一行、顺序天然固定。
#   `all` 模式下两条线都构建完才发布（子进程用 PUBLISH_DEFER=1 跳过各自发布）；
#   单跑 dev/stable 时构建完立即发布，会并入当天那条 release（说明按变体分节合并）。
#
#   手动跑：~/ws_daily/daily_build.sh stable        （或 dev / all）
#   日志：  ~/ws_daily/logs/daily_<variant>_<日期>.log（发布日志 logs/publish_<日期>.log）
#   开关： JOBS=64 FORCE=1 PUBLISH=0 KEEP_DAYS=14 KEEP_MIN=3 KEEP_PER_VARIANT=1
# =============================================================================
set -uo pipefail

W=${WS_DAILY_ROOT:-$HOME/ws_daily}
VARIANT=${1:-${VARIANT:-dev}}

# all：串行跑两个变体（互不干扰，各自加锁）；两条线都建完后**一次性**发布成同一条 release
if [ "$VARIANT" = "all" ]; then
  rc=0
  PUBLISH_DEFER=1          # 子进程只构建不发布，否则会变成两条 release（旧口径）
  export PUBLISH_DEFER
  for v in dev stable; do
    echo "[$(date '+%F %T')] ========== 变体 $v =========="
    "$0" "$v" || rc=1
    echo "[$(date '+%F %T')] ========== 变体 $v 结束（rc=$?） =========="
  done

  # ---- 发布：一个日期一条 release，把当天两条线的 wheel 一起发上去 ----
  if [ "${PUBLISH:-1}" = "1" ] && [ -x "$W/publish_release.sh" ]; then
    PDIRS=()
    for st in "$W/state/last_run.txt" "$W/stable/state/last_run.txt"; do
      [ -f "$st" ] || continue
      line=$(tail -1 "$st")
      stat=$(printf '%s' "$line" | sed -n 's/.* status=\([^ ]*\).*/\1/p')
      case "$stat" in
        OK|PARTIAL_TA_ONLY) ;;                 # 本次真的产出了新东西
        *) continue ;;                         # SKIPPED_UNCHANGED / FAIL：别把上一版当本次产物重复发布
      esac
      d=$(printf '%s' "$line" | sed -n 's/.* out=\([^ ]*\).*/\1/p')
      if [ -n "$d" ] && [ -d "$d" ] && ls "$d"/*.whl >/dev/null 2>&1; then PDIRS+=("$d"); fi
    done
    if [ ${#PDIRS[@]} -gt 0 ]; then
      PLOG=$W/logs/publish_$(date +%Y%m%d).log
      echo "[$(date '+%F %T')] ========== 发布 release（${#PDIRS[@]} 条线：$(basename -a "${PDIRS[@]}" | tr '\n' ' ')） =========="
      if "$W/publish_release.sh" "${PDIRS[@]}" >"$PLOG" 2>&1; then
        echo "[$(date '+%F %T')] ========== 发布完成（日志 $PLOG） =========="
      else
        pv=$?
        echo "[$(date '+%F %T')] ========== 发布退出码=$pv（未配凭据=2 属预期；细节见 $PLOG） =========="
      fi
      grep -E "^publish:" "$PLOG" 2>/dev/null | tail -6
    else
      echo "[$(date '+%F %T')] ========== 没有可发布的产物，跳过发布 =========="
    fi
  fi
  exit $rc
fi

case "$VARIANT" in
  dev)    ROOT=$W;        DEF_TA=main-dev; DEF_NP=master ;;   # dev 工作区沿用历史路径（~/ws_daily/{src,build,payload,state}），保留热构建缓存
  stable) ROOT=$W/stable; DEF_TA=main;     DEF_NP=stable ;;
  *) echo "未知变体 '$VARIANT'（可选 dev / stable / all）"; exit 2 ;;
esac
TA_BRANCH=${TA_BRANCH:-$DEF_TA}
NP_BRANCH=${NP_BRANCH:-$DEF_NP}
TA_REPO=$ROOT/src/triton-ascend
NP_REPO=$ROOT/src/AscendNPU-IR
NP_BUILD=$ROOT/build/npuir
PAYLOAD=$ROOT/payload
STATE=$ROOT/state
OUT=$W/out
LOGDIR=$W/logs

CONTAINER=${CONTAINER:-ubuntu20}
CONTAINER_USER=${CONTAINER_USER:-$(id -un)}   # 容器内以当前用户执行
JOBS=${JOBS:-64}
KEEP_DAYS=${KEEP_DAYS:-14}
KEEP_MIN=${KEEP_MIN:-3}
LLVM_PREBUILT=${LLVM_PREBUILT:-$HOME/workspace/llvm}
CANN_ROOT=${CANN_ROOT:-$(readlink -f "$HOME/Ascend/cann")}   # 安装器维护的软链；2026-09-22 起 -> cann-9.3.0
CANN_ENV=${CANN_ENV:-$CANN_ROOT/set_env.sh}
CANN_BISHENG=${CANN_BISHENG:-$CANN_ROOT/tools/bisheng_compiler/bin}
LLVM_SEED=${LLVM_SEED:-$HOME/workspace/AscendNPU-IR/third-party/llvm-project}
PY311=${PY311:-$HOME/miniconda3/envs/py311/bin}

STAMP=$(date +%Y%m%d)
LOG=$LOGDIR/daily_${VARIANT}_$STAMP.log
OUTDIR=""
mkdir -p "$LOGDIR" "$OUT" "$STATE" "$ROOT/src" "$ROOT/build"

# 单实例锁（按变体；all 模式下两个变体各自加锁、串行执行）
exec 9>"$STATE/lock"
flock -n 9 || { echo "[$(date '+%F %T')] [$VARIANT] 已有实例在运行，本轮跳过"; exit 0; }

log() { echo "[$(date '+%F %T')] [$VARIANT] $*" | tee -a "$LOG"; }
in_container() { docker exec -u "$CONTAINER_USER" "$CONTAINER" nice -n 10 bash -lc "$1"; }
: > "$STATE/stubbed_srcs.txt"

# 容器兜底：distrobox 容器重启策略是 no，机器重启后不一定在跑
ensure_container() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    log "容器 $CONTAINER 未运行 → 尝试 docker start"
    docker start "$CONTAINER" >>"$LOG" 2>&1 || log "⚠️ docker start 失败（重启后若用户会话未建立，挂载点可能缺失）"
    for _ in $(seq 1 12); do
      docker exec -u "$CONTAINER_USER" "$CONTAINER" true >>"$LOG" 2>&1 && break
      sleep 5
    done
  fi
  if docker exec -u "$CONTAINER_USER" "$CONTAINER" true >>"$LOG" 2>&1; then
    log "容器 $CONTAINER 可用 ✅"
  else
    log "❌ 容器 $CONTAINER 不可用，终止（手动 docker start $CONTAINER 后重跑）"
    echo "$(date '+%F %T') variant=$VARIANT status=CONTAINER_DOWN log=$LOG" > "$STATE/last_run.txt"
    exit 1
  fi
}

NPUIR_OK=1
TA_OK=1
log "==================== ws_daily 开始（$VARIANT） ===================="
log "TA=$TA_BRANCH  NPUIR=$NP_BRANCH  容器=$CONTAINER  -j $JOBS  保留 ${KEEP_DAYS}天/最少${KEEP_MIN}份"
log "CANN=$CANN_ROOT  工作区=$ROOT"
ensure_container

# ---------------------------------------------------------------- 1. 同步仓库
# 首次运行（克隆）：dev 变体通常已有；stable 变体第一次会自动克隆
bootstrap_repo() {  # bootstrap_repo <repo> <url> <branch> <name>
  local repo=$1 url=$2 br=$3 name=$4
  [ -d "$repo/.git" ] && return 0
  log "[$name] 首次：克隆 $url ($br)"
  git clone --branch "$br" --single-branch "$url" "$repo" >>"$LOG" 2>&1 || { log "[$name] ❌ 克隆失败"; return 1; }
}

sync_repo() {
  local repo=$1 br=$2 name=$3 ok=0
  log "[$name] fetch origin/$br"
  for i in 1 2 3; do
    if git -C "$repo" fetch --prune origin "$br" >>"$LOG" 2>&1; then ok=1; break; fi
    log "[$name] fetch 失败（第 $i 次），10s 后重试"; sleep 10
  done
  [ $ok -eq 1 ] || { log "[$name] ❌ fetch 连续失败"; return 1; }
  git -C "$repo" checkout -f -B "$br" "origin/$br" >>"$LOG" 2>&1 || { log "[$name] ❌ checkout 失败"; return 1; }
  git -C "$repo" reset --hard "origin/$br" >>"$LOG" 2>&1
  git -C "$repo" clean -fd >>"$LOG" 2>&1          # 丢未跟踪文件；.gitignore 的构建产物保留→增量编译
  local n; n=$(git -C "$repo" status --porcelain | wc -l)
  log "[$name] HEAD=$(git -C "$repo" rev-parse --short=8 HEAD) 本地改动/未跟踪=$n $([ "$n" -eq 0 ] && echo '✅ 干净' || echo '⚠️ 仍有脏项')"
  return 0
}

has_submodule() {
  git -C "$1" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk '{print $2}' | grep -qx "$2"
}

update_submodules() {
  local repo=$1 name=$2
  log "[$name] 更新 submodule"
  git -C "$repo" submodule sync --recursive >>"$LOG" 2>&1
  if has_submodule "$repo" "third-party/llvm-project" && [ -e "$LLVM_SEED/.git" ]; then
    # 只有种子缺 pin 时才刷新种子：pin 不变 → 零网络开销；pin 变了 → 种子吸收一次增量（几百 MB），
    # 两条产品线共用（本地硬链接），避免各自去 gitcode 重复拉
    PIN=$(git -C "$repo" ls-tree HEAD third-party/llvm-project 2>/dev/null | awk '{print $3}')
    if [ -n "$PIN" ] && git -C "$LLVM_SEED" cat-file -e "${PIN}^{commit}" 2>/dev/null; then
      log "[$name] llvm 种子已含 pin ${PIN:0:12} → 跳过种子 fetch（省流量）"
    else
      log "[$name] llvm 种子缺 pin ${PIN:0:12} → 刷新种子（fetch --all，可能几百 MB）"
      git -C "$LLVM_SEED" fetch --all --prune >>"$LOG" 2>&1 || log "[$name] ⚠️ llvm 种子 fetch 失败（继续）"
    fi
    git -C "$repo" config submodule.third-party/llvm-project.url "$LLVM_SEED" >>"$LOG" 2>&1
    if git -C "$repo" -c protocol.file.allow=always submodule update --init third-party/llvm-project >>"$LOG" 2>&1; then
      log "[$name] llvm-project ← 本地种子 ✅"
    else
      log "[$name] ⚠️ 本地种子不够新，回退 gitcode 网络拉 llvm-project"
      git -C "$repo" submodule sync --recursive >>"$LOG" 2>&1
      git -C "$repo" submodule update --init third-party/llvm-project >>"$LOG" 2>&1 \
        || log "[$name] ❌ llvm-project 更新失败"
    fi
  else
    has_submodule "$repo" "third-party/llvm-project" \
      && git -C "$repo" submodule update --init third-party/llvm-project >>"$LOG" 2>&1 \
      || true
  fi
  # 其余顶层子模块；不做 --recursive，避免 torch-mlir 里嵌套 llvm-project 巨量下载（bishengir 构建不需要它）
  git -C "$repo" submodule update --init >>"$LOG" 2>&1 || log "[$name] ⚠️ 部分顶层子模块更新失败"
  git -C "$repo" submodule status >>"$LOG" 2>&1
  log "[$name] submodule 状态：$(git -C "$repo" submodule status 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
}

TA_SYNC=0; NP_SYNC=0
bootstrap_repo "$TA_REPO" https://github.com/triton-lang/triton-ascend.git "$TA_BRANCH" "triton-ascend"
bootstrap_repo "$NP_REPO" https://gitcode.com/Ascend/AscendNPU-IR.git "$NP_BRANCH" "AscendNPU-IR"
[ -d "$TA_REPO/.git" ] && sync_repo "$TA_REPO" "$TA_BRANCH" "triton-ascend" && TA_SYNC=1
[ -d "$NP_REPO/.git" ] && sync_repo "$NP_REPO" "$NP_BRANCH" "AscendNPU-IR" && NP_SYNC=1
[ "$NP_SYNC" -eq 1 ] && update_submodules "$NP_REPO" "AscendNPU-IR"
[ "$TA_SYNC" -eq 1 ] && update_submodules "$TA_REPO" "triton-ascend"

# 与上次成功构建完全同 commit 时跳过（FORCE=1 强制重建）
if [ "${FORCE:-0}" != "1" ] && [ "$TA_SYNC" -eq 1 ] && [ "$NP_SYNC" -eq 1 ] && [ -f "$STATE/last_success.txt" ]; then
  read -r LAST_TA LAST_NP < "$STATE/last_success.txt" 2>/dev/null || true
  CUR_TA=$(git -C "$TA_REPO" rev-parse HEAD); CUR_NP=$(git -C "$NP_REPO" rev-parse HEAD)
  if [ "${LAST_TA:-}" = "$CUR_TA" ] && [ "${LAST_NP:-}" = "$CUR_NP" ]; then
    log "两仓库 commit 与上次成功构建相同（TA ${CUR_TA:0:8} / NPUIR ${CUR_NP:0:8}），跳过本轮；要强制重建用 FORCE=1"
    echo "$(date '+%F %T') variant=$VARIANT status=SKIPPED_UNCHANGED out=$(readlink -f "$OUT/latest-$VARIANT" 2>/dev/null) log=$LOG" > "$STATE/last_run.txt"
    exit 0
  fi
fi

# ------------------------------------------------------ 2. 构建 AscendNPU-IR
if [ "${NP_SYNC:-0}" -eq 1 ]; then
  log "[NPUIR] 开始构建（bishengir + hivmc + 模板库 .bc）"
  # bisheng/ccec 路径变了必须重配：否则 build.sh 复用已配置的 build 目录，ninja 里仍指向旧 ccec
  CANN_MARK=$NP_BUILD/.ws_daily_cann
  mkdir -p "$NP_BUILD"   # 首次运行时目录还不存在，否则下面的标记文件写不进去（下一轮会误判"编译器变化"→白删 cache 全量重配）
  if [ -f "$NP_BUILD/CMakeCache.txt" ] && [ "$(cat "$CANN_MARK" 2>/dev/null)" != "$CANN_BISHENG" ]; then
    log "[NPUIR] bisheng 编译器变化（$(cat "$CANN_MARK" 2>/dev/null || echo 无记录) → $CANN_BISHENG）→ 删 CMakeCache 强制重配"
    rm -f "$NP_BUILD/CMakeCache.txt"
  fi
  echo "$CANN_BISHENG" > "$CANN_MARK"
  NP_CMD="export PATH=$PY311:$HOME/.local/bin:\$PATH; source $CANN_ENV >/dev/null 2>&1; cd $NP_REPO && ./build-tools/build.sh \
--c-compiler $LLVM_PREBUILT/bin/clang --cxx-compiler $LLVM_PREBUILT/bin/clang++ \
'--add-cmake-options=-DLLVM_ENABLE_LLD=ON' --build-type Release -j $JOBS --enable-assertion \
-o $NP_BUILD -t --bisheng-compiler $CANN_BISHENG"
  in_container "$NP_CMD" >>"$LOG" 2>&1
  NP_BUILD_RC=$?
  log "[NPUIR] build.sh 退出码=$NP_BUILD_RC"

  if [ $NP_BUILD_RC -ne 0 ]; then
    # 回退模式：ninja 在第一个失败目标处停住（且失败会删输出）。已知场景：设备调试模板需要的宏
    # CCE_PRINT_CC 在旧 CANN（<9.3.0）的 ccec 里没有；它们又是 meta_op.*.bc 的链接输入，
    # 不处理会让 9 个模板库 .bc 全链不出来。做法：把这些源文件临时替换成空 TU，跑完链接/install 再还原。
    RESCUE_LOG=$STATE/npuir_rescue.log
    FAILED_SRCS=$STATE/failed_srcs.txt
    log "[NPUIR] ↻ 回退模式：ninja -k 0 → 空 TU 顶替编不过的模板 → 重新链接"
    in_container "export PATH=$PY311:$HOME/.local/bin:\$PATH; cd $NP_BUILD && ninja -k 0 -j $JOBS" >"$RESCUE_LOG" 2>&1
    log "[NPUIR] ninja -k 0 退出码=$?（失败目标见 $RESCUE_LOG）"
    awk '/^FAILED:/{getline c; n=split(c,a," "); for(i=1;i<=n;i++) if (a[i] ~ /\.cpp$/) print a[i]}' "$RESCUE_LOG" | sort -u > "$FAILED_SRCS"
    if [ -s "$FAILED_SRCS" ]; then
      while read -r s; do
        [ -f "$s" ] || continue
        cp -a "$s" "$s.ws_daily_bak" && printf 'extern "C" { }\n' > "$s" && echo "$s" >> "$STATE/stubbed_srcs.txt"
      done < "$FAILED_SRCS"
      log "[NPUIR] 顶替 $(wc -l < "$STATE/stubbed_srcs.txt") 个源文件（设备调试模板，缺 ccec 宏）：$(tr '\n' ' ' < "$FAILED_SRCS")"
      in_container "export PATH=$PY311:$HOME/.local/bin:\$PATH; cd $NP_BUILD && ninja -k 0 -j $JOBS" >>"$LOG" 2>&1
      log "[NPUIR] 顶替后 ninja 退出码=$?"
      in_container "export PATH=$PY311:$HOME/.local/bin:\$PATH; cd $NP_BUILD && ninja -k 0 install" >>"$LOG" 2>&1
      log "[NPUIR] ninja install 退出码=$?"
      while read -r s; do [ -f "$s.ws_daily_bak" ] && mv -f "$s.ws_daily_bak" "$s"; done < "$STATE/stubbed_srcs.txt"
      log "[NPUIR] 源码已还原（$(wc -l < "$STATE/stubbed_srcs.txt") 个）"
    else
      log "[NPUIR] 未从日志解析到失败源文件，跳过顶替"
    fi
    mkdir -p "$NP_BUILD/bin" "$NP_BUILD/lib"
    for f in bishengir-compile bishengir-opt hivmc; do
      [ -f "$NP_BUILD/bin/$f" ] || cp -f "$NP_BUILD/install/bin/$f" "$NP_BUILD/bin/$f" 2>/dev/null
    done
    if ! ls "$NP_BUILD"/lib/*.bc >/dev/null 2>&1; then
      cp -f "$NP_BUILD"/install/lib/*.bc "$NP_BUILD/lib/" 2>/dev/null
    fi
    log "[NPUIR] 回退收集后：bin=$(ls "$NP_BUILD/bin" 2>/dev/null | wc -l) 个文件，lib 下 .bc=$(ls "$NP_BUILD"/lib/*.bc 2>/dev/null | wc -l) 个"
  fi

  for f in bin/bishengir-compile bin/bishengir-opt bin/hivmc; do
    [ -f "$NP_BUILD/$f" ] || { log "[NPUIR] ❌ 缺 $NP_BUILD/$f"; NPUIR_OK=0; }
  done
  ls "$NP_BUILD"/lib/*.bc >/dev/null 2>&1 || { log "[NPUIR] ❌ $NP_BUILD/lib 下没有 .bc"; NPUIR_OK=0; }

  # 新鲜度自检：要打包的目标是否都已最新（ninja -n 无待办）。
  # 起因：$NP_BUILD/lib 下的 .bc 是"覆盖不删除"，若某目标本次没编成功，上一轮旧产物会被静默打进包。
  STALE_WARN=""
  if [ $NPUIR_OK -eq 1 ]; then
    BC_TARGETS=$(ls "$NP_BUILD"/lib/host.bc "$NP_BUILD"/lib/meta_op.*.bc 2>/dev/null | xargs -r -n1 basename | sed 's|^|lib/|' | tr '\n' ' ')
    # 排除 CMake 每次都会跑的 "Re-checking globbed directories" / "Re-running CMake"，它们不是我们的产物
    PENDING=$(in_container "export PATH=$PY311:$HOME/.local/bin:\$PATH; cd $NP_BUILD && ninja -n bin/bishengir-opt bin/bishengir-compile bin/hivmc $BC_TARGETS 2>/dev/null | grep -E '^\[' | grep -vE 'Re-checking globbed directories|Re-running CMake' | wc -l" || echo "?")
    if [ "${PENDING:-?}" = "0" ]; then
      log "[NPUIR] 新鲜度自检 ✅ 要打包的目标均为最新（ninja 无待办）"
    else
      STALE_WARN="ninja 待办 ${PENDING} 项（可能有旧产物残留）"
      log "[NPUIR] ⚠️ $STALE_WARN —— 请用 bishengir-opt --version / .bc 大小核对"
    fi
  fi
  [ $NPUIR_OK -eq 1 ] && log "[NPUIR] ✅ 产物齐全：$("$NP_BUILD/bin/bishengir-opt" --version 2>&1 | head -1)"
else
  log "[NPUIR] ❌ 源码同步失败，跳过构建"
  NPUIR_OK=0
fi

# ------------------------------------------------------- 3. 整理 bishengir payload
MISSING_BC=""
if [ $NPUIR_OK -eq 1 ]; then
  rm -rf "$PAYLOAD"
  mkdir -p "$PAYLOAD/bin" "$PAYLOAD/lib"
  cp -f "$NP_BUILD/bin/bishengir-compile" "$NP_BUILD/bin/bishengir-opt" "$NP_BUILD/bin/hivmc" "$PAYLOAD/bin/"
  # 不再打包 hivmc-a5（2026-09-24 决定，2026-09-25 起的包生效）——它是 hivmc 的同内容副本，实测没人调用：
  #   · A5（Ascend950PR，我们的 target）走 `bishengir-compile` 内的 **regbase 流水线**
  #     （`regbase/Driver.cpp: runRegBaseCompile` → `runRegBasePipeline`，in-process）；那条会起子进程
  #     `bishengir-compile-a5` 的分支**在源码里被注释掉了** → 整条 A5 路径不碰任何外部 hivmc
  #   · A3/910B 路径（`runBiShengIRPipeline`）也只把 `hivmc` 用于**版本探测**（`detectHIVMCVersion("hivmc")` →
  #     `$BISHENG_INSTALL_PATH` → `$PATH`，失败仅 warning、可用 --hivmc-version 指定），流水线同样 in-process
  #   · 源码里 `hivmc-a5` 有 **0 个调用点**（只有闭源时代遗留的子工程 target 名、测试 RUN 行、上游 packaging 的 cp）
  #   · a5 实测（2026-09-24，包 79d156db）：包内删掉 hivmc-a5 后 chunk_gla_fwd_o_gk 10/10 通过，
  #     且 PATH 金丝雀 0 次拦截（连 CANN 那份都没被回退调用）
  #   · 收益：wheel 里少一份独立压缩 ≈43MB（zip 不做内容去重）
  # 只收最终产物：排除 *.bc.linked.bc（llvm-link 的中间文件，正常构建会自己删，异常时会残留在 lib/ 下）
  for f in "$NP_BUILD"/lib/*.bc; do
    case "$(basename "$f")" in *.linked.bc) continue;; esac
    cp -f "$f" "$PAYLOAD/lib/" 2>/dev/null
  done
  chmod 755 "$PAYLOAD"/bin/*
  EXPECT_BC="host.bc meta_op.aic.c220.bc meta_op.aic.c310.bc meta_op.aiv.c220.bc meta_op.aiv.c310.bc meta_op.mix.aic.c220.bc meta_op.mix.aic.c310.bc meta_op.mix.aiv.c220.bc meta_op.mix.aiv.c310.bc"
  for b in $EXPECT_BC; do [ -f "$PAYLOAD/lib/$b" ] || MISSING_BC="$MISSING_BC $b"; done
  log "[payload] bin=$(ls "$PAYLOAD/bin" | tr '\n' ' ') | lib=$(ls "$PAYLOAD/lib"/*.bc | wc -l) 个 .bc | 体积=$(du -sh "$PAYLOAD" | cut -f1)"
  [ -n "$MISSING_BC" ] && log "[payload] ⚠️ 缺模板库:$MISSING_BC（已记入 BUILD_INFO）" || log "[payload] ✅ 模板库 9 个齐全"
else
  log "[payload] 跳过（NPUIR 构建失败，将只出不含 bishengir 的 TA wheel）"
fi

# --------------------------------------------------------- 4. 构建 TA wheel
WHL=""
if [ "${TA_SYNC:-0}" -eq 1 ]; then
  ENTRY=setup.py
  [ -f "$TA_REPO/setup_ascend.py" ] && ENTRY=setup_ascend.py     # 9/21 前的老入口
  rm -f "$TA_REPO"/dist/*.whl 2>/dev/null
  BISH=""
  [ $NPUIR_OK -eq 1 ] && BISH="export TRITON_ASCEND_BISHENGIR_PATH=$PAYLOAD;"
  log "[TA] 构建 wheel（入口 $ENTRY，bishengir 注入=$([ $NPUIR_OK -eq 1 ] && echo 是 || echo 否)）"
  TA_CMD="source $CANN_ENV >/dev/null 2>&1; cd $TA_REPO && export PATH=$PY311:\$PATH LLVM_SYSPATH=$LLVM_PREBUILT \
TRITON_BUILD_WITH_CCACHE=true TRITON_BUILD_WITH_CLANG_LLD=true TRITON_BUILD_PROTON=OFF \
TRITON_APPEND_CMAKE_ARGS='-DTRITON_BUILD_UT=OFF'; $BISH python $ENTRY bdist_wheel"
  in_container "$TA_CMD" >>"$LOG" 2>&1
  log "[TA] bdist_wheel 退出码=$?"
  WHL=$(ls -t "$TA_REPO"/dist/*.whl 2>/dev/null | head -1)
  if [ -n "$WHL" ]; then
    log "[TA] ✅ 产出 $(basename "$WHL") $(du -h "$WHL" | cut -f1)"
  else
    log "[TA] ❌ dist/ 下没有 wheel"
    TA_OK=0
  fi
else
  log "[TA] ❌ 源码同步失败，跳过构建"
  TA_OK=0
fi

# ------------------------------------------------------------ 5. 打包与留存
if [ $TA_OK -eq 1 ] && [ -n "$WHL" ]; then
  TA8=$(git -C "$TA_REPO" rev-parse --short=8 HEAD)
  NP8=$(git -C "$NP_REPO" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
  SUF=""; [ $NPUIR_OK -eq 1 ] || SUF="_npuirFAILED"
  OUTDIR=$OUT/${STAMP}_ta${TA8}_npuir${NP8}_${VARIANT}${SUF}
  mkdir -p "$OUTDIR"
  cp -f "$WHL" "$OUTDIR"/
  [ $NPUIR_OK -eq 1 ] && tar -czf "$OUTDIR/bishengir-payload-npuir${NP8}.tar.gz" -C "$PAYLOAD" .
  BUNDLED=$(python3 - "$WHL" <<'PY' 2>/dev/null || echo "?"
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
n = [x for x in z.namelist() if "bishengir/" in x]
print(f"{len(n)} 项")
PY
)
  {
    echo "=== ws_daily BUILD INFO ==="
    echo "date: $(date '+%F %T %Z')"
    echo "variant: $VARIANT (triton-ascend $TA_BRANCH + AscendNPU-IR $NP_BRANCH)"
    echo "triton-ascend: branch=$TA_BRANCH commit=$(git -C "$TA_REPO" rev-parse HEAD)"
    echo "AscendNPU-IR:  branch=$NP_BRANCH commit=$(git -C "$NP_REPO" rev-parse HEAD 2>/dev/null) (build_ok=$NPUIR_OK)"
    echo "wheel: $(basename "$WHL")  size=$(du -h "$WHL" | cut -f1)"
    echo "wheel 内 bishengir 条目: $BUNDLED"
    echo "NPUIR 构建: build.sh 退出码=${NP_BUILD_RC:-?}$([ "${NP_BUILD_RC:-1}" -ne 0 ] && [ $NPUIR_OK -eq 1 ] && echo '（已用 ninja -k 0 + 空 TU 顶替回退）')"
    echo "空 TU 顶替的模板源文件: $([ -s "$STATE/stubbed_srcs.txt" ] && tr '\n' ' ' < "$STATE/stubbed_srcs.txt" || echo 无)"
    echo "模板库缺失: ${MISSING_BC:-无}"
    echo "模板库条目: $(ls "$PAYLOAD/lib"/*.bc 2>/dev/null | wc -l) 个 .bc"
    echo "产物新鲜度: ${STALE_WARN:-全新（ninja 无待办）}"
    echo "payload: $([ $NPUIR_OK -eq 1 ] && echo "bishengir-payload-npuir${NP8}.tar.gz ($(du -sh "$PAYLOAD" | cut -f1))" || echo "无")"
    echo "容器: $CONTAINER (Ubuntu 20.04/glibc 2.31)  jobs=$JOBS  log=$LOG"
    echo "cann: $CANN_ROOT ($("$CANN_BISHENG/ccec" --version 2>/dev/null | grep -oE 'clang version [0-9.]+' | head -1))"
    echo
    echo "--- triton-ascend commit ---"; git -C "$TA_REPO" log -1 --format='%H%n%cd%n%s%n%n%B'
    echo "--- AscendNPU-IR commit ---"; git -C "$NP_REPO" log -1 --format='%H%n%cd%n%s%n%n%B' 2>/dev/null
    echo "--- triton-ascend submodules ---"; git -C "$TA_REPO" submodule status
    echo "--- AscendNPU-IR submodules ---"; git -C "$NP_REPO" submodule status 2>/dev/null
    echo "--- bishengir 版本 ---"; "$PAYLOAD/bin/bishengir-opt" --version 2>&1 | head -3
    echo "--- 产物 md5 ---"; (cd "$OUTDIR" && md5sum ./* 2>/dev/null)
  } > "$OUTDIR/BUILD_INFO.txt"
  ln -sfn "$OUTDIR" "$OUT/latest-$VARIANT"
  log "[打包] $OUTDIR（wheel + payload + BUILD_INFO）"

  # INDEX.md（含变体列）
  {
    echo "# ws_daily 产物索引（自动生成）"
    echo
    echo "更新: $(date '+%F %T %Z')"
    echo
    echo "| 目录 | 变体 | TA commit | NPUIR commit | wheel 内 bishengir |"
    echo "|---|---|---|---|---|"
    for d in "$OUT"/*/; do
      [ -L "${d%/}" ] && continue
      [ -f "$d/BUILD_INFO.txt" ] || continue
      printf '| `%s` | %s | %s | %s | %s |\n' "$(basename "$d")" \
        "$(sed -n 's/^variant: \([^ ]*\).*/\1/p' "$d/BUILD_INFO.txt" | head -1)" \
        "$(sed -n 's/^triton-ascend: branch=.* commit=\([0-9a-f]\{8\}\).*/\1/p' "$d/BUILD_INFO.txt")" \
        "$(sed -n 's/^AscendNPU-IR:  branch=.* commit=\([0-9a-f]\{8\}\).*/\1/p' "$d/BUILD_INFO.txt")" \
        "$(sed -n 's/^wheel 内 bishengir 条目: //p' "$d/BUILD_INFO.txt")"
    done
  } > "$OUT/INDEX.md"

  # 发布到 GitHub release（best-effort：没配凭据 / 上传失败都不影响构建结果）
  # all 模式下子进程被父进程设了 PUBLISH_DEFER=1：两条线都建完由父进程合并发布成一条 release
  if [ "${PUBLISH:-1}" = "1" ] && [ "${PUBLISH_DEFER:-0}" != "1" ] && [ -x "$W/publish_release.sh" ]; then
    log "[发布] 上传 wheel 到 GitHub release（repo=${GH_RELEASE_REPO:-jqran/triton-ascend-wheels}）"
    if "$W/publish_release.sh" "$OUTDIR" >>"$LOG" 2>&1; then
      log "[发布] ✅ 完成"
    else
      log "[发布] ⚠️ 退出码=$?（未配置凭据会走到这里，属预期；细节见日志）"
    fi
  fi

  # 清理旧产物：超过 KEEP_DAYS 天且不是最新 KEEP_MIN 份
  find "$OUT" -maxdepth 1 -mindepth 1 -type d -mtime +"$KEEP_DAYS" 2>/dev/null | sort | head -n -"$KEEP_MIN" | xargs -r rm -rf
fi

# ------------------------------------------------------------------ 6. 收尾
if [ $TA_OK -eq 1 ] && [ $NPUIR_OK -eq 1 ]; then STATUS=OK
elif [ $TA_OK -eq 1 ]; then STATUS=PARTIAL_TA_ONLY
else STATUS=FAIL; fi
log "==================== ws_daily 结束（$VARIANT） status=$STATUS ===================="
echo "$(date '+%F %T') variant=$VARIANT status=$STATUS out=${OUTDIR:-none} log=$LOG" > "$STATE/last_run.txt"
if [ "$STATUS" = OK ]; then
  echo "$(git -C "$TA_REPO" rev-parse HEAD) $(git -C "$NP_REPO" rev-parse HEAD)" > "$STATE/last_success.txt"
else
  exit 1
fi
