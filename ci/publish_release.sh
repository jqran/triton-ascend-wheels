#!/bin/bash
# =============================================================================
# publish_release.sh <outdir> [<outdir> ...]
#
#   把一个或多个 out/<日期>_ta<sha8>_npuir<sha8>_<variant>/ 目录里的 wheel 发布到
#   GitHub release。**一个日期一个 release**：同一天的 dev / stable 作为两个 asset
#   放在同一个 release 里（tag = 日期，如 20260924）→ 页面每天一行，顺序天然固定。
#
#   为什么合并成一条：GitHub 的 release 列表顺序**没有任何 API 字段可设置**，实测
#   created_at（其实是 tag 指向 commit 的 committer date）/ updated_at / published_at
#   都不能决定可见顺序 —— 同一晚两条 release 会 dev/stable 互换、甚至出现
#   "stable dev dev stable"。合并后不存在成对顺序问题（2026-09-24 决定）。
#
#   说明（release body）由各目录的 BUILD_INFO.txt 自动生成，按变体分节，分节用
#   <!-- variant:xxx --> 标记包裹，以便增量更新：
#     - release 已存在 → 合并更新：本次涉及的变体分节被替换，未涉及的分节原样保留
#     - asset 同名已存在 → 跳过上传（可以对同一目录反复调用，幂等）
#
#   鉴权（按顺序）：$GH_TOKEN_FILE（默认 ~/.config/ws_daily/gh_token）> gh auth token
#   退出码：0 成功/已存在；1 用法或产物问题；2 未配置凭据（调用方按 best-effort 处理）
# =============================================================================
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: publish_release.sh <outdir> [<outdir> ...]"; exit 1; }

REPO=${GH_RELEASE_REPO:-jqran/triton-ascend-wheels}
TOKEN_FILE=${GH_TOKEN_FILE:-$HOME/.config/ws_daily/gh_token}
API=https://api.github.com

# ---------- 收集入参目录（入参顺序无关，输出按变体固定顺序）----------
DIRS=()
for d in "$@"; do
  D=$(readlink -f "$d")          # 解析软链：out/latest-dev -> out/<日期>_ta.._npuir.._dev
  [ -d "$D" ] || { echo "publish: 目录不存在：$d"; exit 1; }
  [ -f "$D/BUILD_INFO.txt" ] || { echo "publish: 缺 $D/BUILD_INFO.txt"; exit 1; }
  ls "$D"/*.whl >/dev/null 2>&1 || { echo "publish: $D 下没有 wheel"; exit 1; }
  case " ${DIRS[*]-} " in *" $D "*) continue ;; esac      # 去重
  DIRS+=("$D")
done

# ---------- 凭据 ----------
TOKEN=""; TOKEN_SRC=""
if [ -f "$TOKEN_FILE" ]; then TOKEN=$(tr -d '\n\r' < "$TOKEN_FILE"); TOKEN_SRC="$TOKEN_FILE"; fi
if [ -z "$TOKEN" ]; then
  GH_BIN=${GH_BIN:-$HOME/.local/bin/gh}
  if [ -x "$GH_BIN" ] && "$GH_BIN" auth status >/dev/null 2>&1; then
    TOKEN=$("$GH_BIN" auth token 2>/dev/null)
    TOKEN_SRC="$GH_BIN 登录态（$("$GH_BIN" api user --jq .login 2>/dev/null)）"
  fi
fi
if [ -z "$TOKEN" ]; then
  echo "publish: 没有可用凭据 —— 跳过发布"
  echo "publish: ① umask 077; printf '%s' '<fine-grained PAT>' > $TOKEN_FILE"
  echo "publish: ② ~/.local/bin/gh auth login   （已登录则自动取 gh auth token）"
  exit 2
fi

# ---------- 逐个目录抽字段 ----------
get() { sed -n "s/^$1: //p" "$INFO" | head -1; }
# commit message 的 subject：commit 段里第 4 行（1=marker, 2=sha, 3=date, 4=subject）
subject_of() { sed -n "/^--- $1 commit ---/,/^--- /p" "$INFO" | sed -n '4p'; }

VARS=(); DATES=(); WHLS=(); MD5S=(); SIZES=(); BTSS=(); BTS_EPOCH=()
for D in "${DIRS[@]}"; do
  INFO=$D/BUILD_INFO.txt
  B=$(basename "$D")
  DT=$(printf '%s' "$B" | cut -c1-8)
  case "$DT" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) echo "publish: 目录名不是 <日期>_ta.. 形式：$B"; exit 1 ;;
  esac
  V=$(get variant | awk '{print $1}'); V=${V:-unknown}
  W=$(ls -t "$D"/*.whl | head -1)
  BT=$(get date)                                  # 2026-09-24 01:15:14 CST
  EP=$(date -u -d "${BT% CST} +0800" +%s 2>/dev/null || echo "")
  VARS+=("$V"); DATES+=("$DT"); WHLS+=("$W")
  MD5S+=("$(md5sum "$W" | cut -d' ' -f1)"); SIZES+=("$(du -h "$W" | cut -f1)")
  BTSS+=("$BT"); BTS_EPOCH+=("${EP:-0}")
done

# ---------- release 标识：tag = 日期（取最新那天）----------
TAG=""
for dt in "${DATES[@]}"; do
  if [ -z "$TAG" ] || [ "$dt" \> "$TAG" ]; then TAG=$dt; fi
done
DATE_DISPLAY="${TAG:0:4}-${TAG:4:2}-${TAG:6:2}"
DATE_MIXED=0
for dt in "${DATES[@]}"; do [ "$dt" = "$TAG" ] || DATE_MIXED=1; done

# 变体固定顺序：dev 在前、stable 其次、其余按字典序（标题与分节都用这个顺序）
ORDER=()
for want in dev stable; do
  for i in "${!VARS[@]}"; do [ "${VARS[$i]}" = "$want" ] && ORDER+=("$i"); done
done
for i in "${!VARS[@]}"; do
  case "${VARS[$i]}" in dev|stable) continue ;; esac
  ORDER+=("$i")
done
VARIANT_LIST=""; for i in "${ORDER[@]}"; do VARIANT_LIST="$VARIANT_LIST${VARIANT_LIST:+, }${VARS[$i]}"; done

# ---------- 排序键：取本批最早的构建时间（跨天单调递增，天与天顺序恒定）----------
SORT_EPOCH=""
for ep in "${BTS_EPOCH[@]}"; do
  case "$ep" in ''|0) continue ;; esac
  if [ -z "$SORT_EPOCH" ] || [ "$ep" -lt "$SORT_EPOCH" ]; then SORT_EPOCH=$ep; fi
done
SORT_DATE=""
[ -n "$SORT_EPOCH" ] && SORT_DATE=$(date -u -d "@$SORT_EPOCH" +%Y-%m-%dT%H:%M:%SZ)

TITLE_HINT="[每日] $DATE_DISPLAY · $VARIANT_LIST"    # 仅供参考；实际标题在 Python 里按合并后的变体集合生成
echo "publish: repo=$REPO tag=$TAG 变体=$VARIANT_LIST 排序键=${SORT_DATE:-未设置} 凭据=$TOKEN_SRC"
[ "$DATE_MIXED" = 1 ] && echo "publish: ⚠️ 入参目录日期不一致（${DATES[*]}）→ 统一发到 $TAG 这条 release"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------- 头部：一眼看清这一天两条线各自是什么 ----------
HEAD=$TMP/head.md
{
  echo "**构建日期**：$DATE_DISPLAY（本 release 含 ${#DIRS[@]} 条线：$VARIANT_LIST）｜ **Python**：cp311 / linux_x86_64"
  [ "$DATE_MIXED" = 1 ] && echo "⚠️ 这两条产物不是同一天构建的（${DATES[*]}），按最新日期归档。"
  echo
  echo "| 变体 | 构建时间 | triton-ascend | AscendNPU-IR | 包 | wheel md5 |"
  echo "|---|---|---|---|---|---|"
  for i in "${ORDER[@]}"; do
    INFO=${DIRS[$i]}/BUILD_INFO.txt
    TAS=$(sed -n 's/^triton-ascend: branch=.* commit=\([0-9a-f]*\).*/\1/p' "$INFO" | head -1)
    NPS=$(sed -n 's/^AscendNPU-IR:  branch=.* commit=\([0-9a-f]*\).*/\1/p' "$INFO" | head -1)
    TAB=$(sed -n 's/^triton-ascend: branch=\([^ ]*\).*/\1/p' "$INFO" | head -1)
    NPB=$(sed -n 's/^AscendNPU-IR:  branch=\([^ ]*\).*/\1/p' "$INFO" | head -1)
    printf '| **%s** | %s | `%s` (%s) | `%s` (%s) | `%s` %s | `%s` |\n' \
      "${VARS[$i]}" "${BTSS[$i]}" "${TAS:0:8}" "$TAB" "${NPS:0:8}" "$NPB" \
      "$(basename "${WHLS[$i]}")" "${SIZES[$i]}" "${MD5S[$i]}"
  done
  echo
  echo "> 每天 01:00（cron）自动构建两条线：**dev** = triton-ascend \`main-dev\` + AscendNPU-IR \`master\`；"
  echo "> **stable** = triton-ascend \`main\` + AscendNPU-IR \`stable\`。一个日期一条 release，两条线各一个 wheel；"
  echo "> wheel 是**二合一包**（包内已捆绑 \`bishengir-compile/opt\` + \`hivmc\` + 9 个模板库 \`.bc\`）。"
  echo "> 下载见下方 **Assets**。"
} > "$HEAD"

# ---------- 每个变体一节（用标记包裹，便于增量合并）----------
for i in "${ORDER[@]}"; do
  D=${DIRS[$i]}; INFO=$D/BUILD_INFO.txt; W=${WHLS[$i]}; V=${VARS[$i]}
  TA_SHA=$(sed -n 's/^triton-ascend: branch=.* commit=\([0-9a-f]*\).*/\1/p' "$INFO" | head -1)
  NP_SHA=$(sed -n 's/^AscendNPU-IR:  branch=.* commit=\([0-9a-f]*\).*/\1/p' "$INFO" | head -1)
  TA_BR=$(sed -n 's/^triton-ascend: branch=\([^ ]*\).*/\1/p' "$INFO" | head -1)
  NP_BR=$(sed -n 's/^AscendNPU-IR:  branch=\([^ ]*\).*/\1/p' "$INFO" | head -1)
  STUBBED=$(get '空 TU 顶替的模板源文件'); [ "$STUBBED" = "无" ] && STUBBED=""
  MISSING_BC=$(get '模板库缺失');          [ "$MISSING_BC" = "无" ] && MISSING_BC=""
  CANN=$(get cann)
  CONTAINER=$(get 容器 | sed 's/  *log=.*//')
  BC_CNT=$(get 模板库条目)
  NPUIR_OK=1
  case "$(get 'AscendNPU-IR')" in *build_ok=0*) NPUIR_OK=0 ;; esac

  {
    echo "## $V — triton-ascend \`$TA_BR\` + AscendNPU-IR \`$NP_BR\`"
    echo
    echo "**构建时间**：$(get date) ｜ **产物**：\`$(basename "$W")\`（${SIZES[$i]}，md5 \`${MD5S[$i]}\`）"
    [ "$NPUIR_OK" = 0 ] && echo "⚠️ **本次 NPUIR 构建失败**（build_ok=0）→ 该 wheel 内**不含** bishengir 工具链，仅供排查。"
    [ -n "$CANN" ] && echo "**bisheng 编译器（模板库用）**：\`$CANN\`"
    [ -n "$CONTAINER" ] && echo "**构建容器**：$CONTAINER"
    echo
    echo "### 组件 commit"
    echo
    echo "| 组件 | 分支 | commit | commit message |"
    echo "|---|---|---|---|"
    echo "| triton-ascend | $TA_BR | \`$TA_SHA\` | $(subject_of triton-ascend | sed 's/|/\\|/g') |"
    echo "| AscendNPU-IR | $NP_BR | \`$NP_SHA\` | $(subject_of AscendNPU-IR | sed 's/|/\\|/g') |"
    echo
    echo "子模块指针："
    echo
    echo '```'
    sed -n '/^--- triton-ascend submodules ---/,/^--- bishengir 版本 ---/p' "$INFO" | grep -vE '^---|^$'
    echo '```'
    echo
    echo "### 包内捆绑的 AscendNPU-IR 工具链（二合一）"
    echo
    echo "wheel 内 \`triton/backends/ascend/bishengir/\`：$(get 'wheel 内 bishengir 条目')"
    echo
    echo '```'
    echo "bin/{bishengir-compile, bishengir-opt, hivmc, hivmc-a5}"
    echo "lib/{host.bc, meta_op.{aic,aiv,mix}.{c220,c310}.bc}   # ${BC_CNT:-共 9 个}"
    echo '```'
    echo
    echo "版本：$(sed -n '/^--- bishengir 版本 ---/,/^--- 产物 md5 ---/p' "$INFO" | sed -n '2p')"
    echo
    echo "### 安装"
    echo
    echo '```bash'
    echo "pip install --no-deps --force-reinstall \\"
    echo "  https://github.com/$REPO/releases/download/$TAG/$(basename "$W")"
    echo '```'
    echo
    echo "外部依赖自行确保：CANN toolkit、torch-npu（当前配套 2.7.1.post8）。"
    if [ -n "$STUBBED" ] || [ -n "$MISSING_BC" ]; then
      echo
      echo "### 已知问题（本次构建）"
      echo
      if [ -n "$STUBBED" ]; then
        echo "NPUIR 设备调试模板（\`lib/{Debug,RegBase/Debug,RegBase/Debug/SIMT}/Debug.cpp\`）需要的宏 \`CCE_PRINT_CC\`"
        echo "在 ${CANN:-所用 CANN} 的 ccec 里不存在 → 编译失败；本次对这 3 个源文件做了**空 TU 顶替**，"
        echo "以便 \`meta_op.*.bc\` 能正常链接（设备调试打印相关符号为空，其余模板库完整）："
        echo
        echo '```'
        printf '%s\n' "$STUBBED" | tr ' ' '\n' | grep -v '^$'
        echo '```'
      fi
      [ -n "$MISSING_BC" ] && echo "模板库缺失：$MISSING_BC"
    fi
  } > "$TMP/section-$V.md"
done

# ---------- 创建或更新 release（说明按变体分节合并）----------
SECS=(); for i in "${ORDER[@]}"; do SECS+=("$TMP/section-${VARS[$i]}.md"); done
RELEASE_ID=$(python3 - "$REPO" "$TAG" "$DATE_DISPLAY" "$HEAD" "$TOKEN" "$SORT_DATE" "${SECS[@]}" <<'PY'
import json, os, re, sys, urllib.request, urllib.error

repo, tag, datestr, headfile, token, sortdate = sys.argv[1:7]
secfiles = sys.argv[7:]
hdr = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
       "Content-Type": "application/json", "User-Agent": "ws_daily-publish"}
MARK = re.compile(r"<!-- variant:([^ ]+) -->\n(.*?)\n<!-- /variant:\1 -->", re.S)


def call(url, payload=None, method="GET"):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=hdr, method=method)
    return json.load(urllib.request.urlopen(req))


def merge_body(old, head, sections):
    """按变体分节合并：本次给的分节替换旧的，旧里其它分节原样保留。返回 (body, 变体顺序)。"""
    kept = {m.group(1): m.group(2) for m in MARK.finditer(old or "")}
    kept.update(sections)
    order = [v for v in ("dev", "stable") if v in kept] + sorted(v for v in kept if v not in ("dev", "stable"))
    out = [head.rstrip(), ""]
    for v in order:
        out += [f"<!-- variant:{v} -->", kept[v].rstrip(), f"<!-- /variant:{v} -->", ""]
    return "\n".join(out).rstrip() + "\n", order


def title_of(order):
    return f"[每日] {datestr} · " + " + ".join(order)


def sort_commit():
    """造一个与默认分支 HEAD 同 tree 的合成 commit，committer date = 排序键日期。
    仓库内容零变化、不进分支历史（只被本次 release 的 tag 引用）。
    任何失败都返回 None —— 排序只是显示顺序，绝不能让发布本身失败。"""
    if not sortdate:
        return None
    try:
        head = call(f"https://api.github.com/repos/{repo}/commits?per_page=1")[0]
        ident = {"name": "ws_daily", "email": "ws_daily@users.noreply.github.com", "date": sortdate}
        c = call(f"https://api.github.com/repos/{repo}/git/commits",
                 {"message": f"release {tag}（排序键 commit，非代码改动）",
                  "tree": head["commit"]["tree"]["sha"], "parents": [head["sha"]],
                  "author": ident, "committer": ident}, "POST")
        print(f"publish: 排序键 commit {c['sha'][:10]} committer_date={sortdate}", file=sys.stderr)
        return c["sha"]
    except Exception as e:      # noqa: BLE001 —— 排序键失败不影响发布
        print(f"publish: ⚠️ 排序键 commit 创建失败（不影响发布）: {e}", file=sys.stderr)
        return None


head = open(headfile, encoding="utf-8").read()
sections = {}
for f in secfiles:
    v = os.path.basename(f)[len("section-"):-len(".md")]
    sections[v] = open(f, encoding="utf-8").read()

try:
    body, order = merge_body("", head, sections)
    payload = {"tag_name": tag, "name": title_of(order), "body": body,
               "draft": False, "prerelease": False}
    target = sort_commit()
    if target:
        payload["target_commitish"] = target    # tag 指向该 commit → created_at = sortdate
    r = call(f"https://api.github.com/repos/{repo}/releases", payload, "POST")
    print(r["id"]); print(f"publish: release 已创建 {r['html_url']}", file=sys.stderr)
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")
    if e.code == 422:  # 已存在 → 合并说明（保留未涉及变体的分节）
        cur = call(f"https://api.github.com/repos/{repo}/releases/tags/{tag}")
        body, order = merge_body(cur.get("body") or "", head, sections)
        r = call(f"https://api.github.com/repos/{repo}/releases/{cur['id']}",
                 {"name": title_of(order), "body": body}, "PATCH")
        print(r["id"]); print(f"publish: release 已存在 → 已合并更新说明（含 {', '.join(order)}）{r['html_url']}", file=sys.stderr)
    else:
        print(f"publish: 创建 release 失败 HTTP {e.code}: {detail[:300]}", file=sys.stderr)
        sys.exit(1)
PY
) || { echo "publish: 创建/更新 release 失败"; exit 1; }
[ -n "$RELEASE_ID" ] || { echo "publish: 没拿到 release id"; exit 1; }

# ---------- 上传 asset（逐个 wheel，已存在则跳过）----------
ASSET_KEYS_OF() { printf '%s\n%s\n' "$1" "$(printf '%s' "$1" | tr '+' '.')" | sort -u; }
list_assets() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
                  "$API/repos/$REPO/releases/$RELEASE_ID/assets"; }
asset_id_of() { python3 -c "
import json, sys
keys = set(sys.argv[1:])
print(next((a['id'] for a in json.load(sys.stdin) if a['name'] in keys), ''))
" $*; }

UPLOADED=0
for i in "${ORDER[@]}"; do
  W=${WHLS[$i]}; ASSET_NAME=$(basename "$W")
  # GitHub 侧存的名字有两种可能：保留 '+'（上传时已 URL 编码）或被规范化成 '.'（历史/未编码），两种都比对
  KEYS=$(ASSET_KEYS_OF "$ASSET_NAME")
  EXIST=$(list_assets | asset_id_of $KEYS 2>/dev/null)
  if [ -n "$EXIST" ]; then
    echo "publish: [${VARS[$i]}] asset 已存在（id=$EXIST），跳过上传"
    continue
  fi
  echo "publish: [${VARS[$i]}] 上传 $ASSET_NAME ..."
  # name 必须 URL 编码：否则 + 会被当成空格，GitHub 会把 asset 名规范化成 . 导致下载链接 404
  ASSET_Q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$ASSET_NAME")
  if curl -sS --fail-with-body -X POST \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
      --data-binary "@$W" -o /tmp/wsdl_asset.json \
      "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ASSET_Q"; then
    python3 -c "import json;d=json.load(open('/tmp/wsdl_asset.json'));print('publish: ✅ 上传完成', d.get('browser_download_url',''))"
    UPLOADED=$((UPLOADED+1))
  elif [ -n "$(list_assets | asset_id_of $KEYS 2>/dev/null)" ]; then
    echo "publish: asset 已存在（并发上传或命名规范化），视为成功"
  else
    echo "publish: ❌ 上传失败"; sed -n '1,3p' /tmp/wsdl_asset.json 2>/dev/null; exit 1
  fi
done
echo "publish: done（asset 上传 $UPLOADED 个 / 共 ${#ORDER[@]} 个变体）"
