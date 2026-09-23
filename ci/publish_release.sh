#!/bin/bash
# =============================================================================
# publish_release.sh <outdir>
#   把 out/<日期>_ta<sha8>_npuir<sha8>/ 里的 wheel 发到 GitHub release
#   仓库：$GH_RELEASE_REPO（默认 jqran/triton-ascend-wheels）
#   release 说明由该目录的 BUILD_INFO.txt 生成：各组件 commit + commit message、
#   子模块指针、glibc/CANN 版本、wheel md5、已知问题
#
#   鉴权（按顺序）：$GH_TOKEN_FILE（默认 ~/.config/ws_daily/gh_token）> gh auth token
#   幂等：release 已存在 → 更新标题/说明；同名 asset 已存在 → 跳过上传
#   退出码：0 成功/已存在；1 用法或产物问题；2 未配置凭据（调用方按 best-effort 处理）
# =============================================================================
set -uo pipefail

OUTDIR=$(readlink -f "${1:?usage: publish_release.sh <outdir>}")   # 解析软链：out/latest -> out/<日期>_ta.._npuir..
REPO=${GH_RELEASE_REPO:-jqran/triton-ascend-wheels}
TOKEN_FILE=${GH_TOKEN_FILE:-$HOME/.config/ws_daily/gh_token}
API=https://api.github.com

WHL=$(ls -t "$OUTDIR"/*.whl 2>/dev/null | head -1)
[ -n "$WHL" ] || { echo "publish: $OUTDIR 下没有 wheel"; exit 1; }
INFO=$OUTDIR/BUILD_INFO.txt
[ -f "$INFO" ] || { echo "publish: 缺 $INFO"; exit 1; }

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

# ---------- 从 BUILD_INFO 抽字段 ----------
get() { sed -n "s/^$1: //p" "$INFO" | head -1; }
# commit message 的 subject：commit 段里第 4 行（1=marker, 2=sha, 3=date, 4=subject）
subject_of() { sed -n "/^--- $1 commit ---/,/^--- /p" "$INFO" | sed -n '4p'; }

BASE=$(basename "$OUTDIR")
TAG=$(printf '%s' "$BASE" | tr '_' '-')
TA_SHA=$(sed -n 's/^triton-ascend: branch=.* commit=\([0-9a-f]*\).*/\1/p' "$INFO" | head -1)
NP_SHA=$(sed -n 's/^AscendNPU-IR:  branch=.* commit=\([0-9a-f]*\).*/\1/p' "$INFO" | head -1)
TA_BR=$(sed -n 's/^triton-ascend: branch=\([^ ]*\).*/\1/p' "$INFO" | head -1)
NP_BR=$(sed -n 's/^AscendNPU-IR:  branch=\([^ ]*\).*/\1/p' "$INFO" | head -1)
DATE_FROM_DIR=$(printf '%s' "$BASE" | cut -c1-4)-$(printf '%s' "$BASE" | cut -c5-6)-$(printf '%s' "$BASE" | cut -c7-8)
VARIANT=$(get variant | awk '{print $1}')
TITLE="[${VARIANT:-?}] triton-ascend ${TA_SHA:0:8} + AscendNPU-IR ${NP_SHA:0:8} ($DATE_FROM_DIR)"
MD5=$(md5sum "$WHL" | cut -d' ' -f1)
SIZE=$(du -h "$WHL" | cut -f1)
STUBBED=$(get '空 TU 顶替的模板源文件'); [ "$STUBBED" = "无" ] && STUBBED=""
MISSING_BC=$(get '模板库缺失');        [ "$MISSING_BC" = "无" ] && MISSING_BC=""
CANN=$(get cann)
CONTAINER=$(get 容器 | sed 's/  *log=.*//')     # 去掉日志路径，只留容器与 glibc

# ---------- 生成 release 说明 ----------
BODY=$(mktemp)
{
  echo "**构建时间**：$(get date) ｜ **Python**：cp311 / linux_x86_64"
  echo "**构建线**：$(get variant)"
  echo "**构建容器**：$CONTAINER"
  [ -n "$CANN" ] && echo "**bisheng 编译器（模板库用）**：\`$CANN\`"
  echo "**产物**：\`$(basename "$WHL")\`（$SIZE，md5 \`$MD5\`）"
  echo
  echo "## 组件 commit"
  echo
  echo "| 组件 | 分支 | commit | commit message |"
  echo "|---|---|---|---|"
  echo "| triton-ascend | $TA_BR | \`$TA_SHA\` | $(subject_of triton-ascend | sed 's/|/\\|/g') |"
  echo "| AscendNPU-IR | $NP_BR | \`$NP_SHA\` | $(subject_of AscendNPU-IR | sed 's/|/\\|/g') |"
  echo
  echo "子模块指针："
  echo
  echo '```'
  sed -n '/^--- triton-ascend submodules ---/,/^--- bishengir 版本 ---/p' "$INFO" \
    | grep -vE '^---|^$'
  echo '```'
  echo
  echo "## 包内捆绑的 AscendNPU-IR 工具链（二合一）"
  echo
  echo "wheel 内 \`triton/backends/ascend/bishengir/\`：$(get 'wheel 内 bishengir 条目')"
  echo
  echo '```'
  echo "bin/{bishengir-compile, bishengir-opt, hivmc, hivmc-a5}"
  echo "lib/{host.bc, meta_op.{aic,aiv,mix}.{c220,c310}.bc}   # 共 9 个"
  echo '```'
  echo
  echo "版本：$(sed -n '/^--- bishengir 版本 ---/,/^--- 产物 md5 ---/p' "$INFO" | sed -n '2p')"
  echo
  echo "## 安装"
  echo
  echo '```bash'
  echo "pip install --no-deps --force-reinstall \\"
  echo "  https://github.com/$REPO/releases/download/$TAG/$(basename "$WHL")"
  echo '```'
  echo
  echo "外部依赖自行确保：CANN toolkit、torch-npu（当前配套 2.7.1.post8）。"
  if [ -n "$STUBBED" ]; then
    echo
    echo "## 已知问题（本次构建）"
    echo
    echo "NPUIR 设备调试模板（\`lib/{Debug,RegBase/Debug,RegBase/Debug/SIMT}/Debug.cpp\`）需要的宏 \`CCE_PRINT_CC\`"
    echo "在 ${CANN:-所用 CANN} 的 ccec 里不存在 → 编译失败；本次对这 3 个源文件做了**空 TU 顶替**，"
    echo "以便 \`meta_op.*.bc\` 能正常链接（设备调试打印相关符号为空，其余模板库完整）："
    echo
    echo '```'
    printf '%s\n' "$STUBBED" | tr ' ' '\n' | grep -v '^$'
    echo '```'
    echo
    echo "模板库缺失：${MISSING_BC:-无}"
  fi
} > "$BODY"

echo "publish: repo=$REPO tag=$TAG wheel=$(basename "$WHL") ($SIZE) 凭据=$TOKEN_SRC"

# ---------- 创建或更新 release ----------
RELEASE_ID=$(python3 - "$REPO" "$TAG" "$TITLE" "$BODY" "$TOKEN" <<'PY'
import json, sys, urllib.request, urllib.error
repo, tag, title, bodyfile, token = sys.argv[1:6]
body = open(bodyfile, encoding="utf-8").read()
hdr = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
       "Content-Type": "application/json", "User-Agent": "ws_daily-publish"}

def call(url, payload, method):
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=hdr, method=method)
    return json.load(urllib.request.urlopen(req))

try:
    r = call(f"https://api.github.com/repos/{repo}/releases",
             {"tag_name": tag, "name": title, "body": body, "draft": False, "prerelease": False}, "POST")
    print(r["id"]); print(f"publish: release 已创建 {r['html_url']}", file=sys.stderr)
except urllib.error.HTTPError as e:
    detail = e.read().decode(errors="replace")
    if e.code == 422:  # 已存在 → 取 id 并更新标题/说明
        req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/tags/{tag}", headers=hdr)
        cur = json.load(urllib.request.urlopen(req))
        r = call(f"https://api.github.com/repos/{repo}/releases/{cur['id']}",
                 {"name": title, "body": body}, "PATCH")
        print(r["id"]); print(f"publish: release 已存在 → 已更新标题/说明 {r['html_url']}", file=sys.stderr)
    else:
        print(f"publish: 创建 release 失败 HTTP {e.code}: {detail[:300]}", file=sys.stderr)
        sys.exit(1)
PY
) || { echo "publish: 创建/更新 release 失败"; rm -f "$BODY"; exit 1; }
rm -f "$BODY"
[ -n "$RELEASE_ID" ] || { echo "publish: 没拿到 release id"; exit 1; }

# ---------- 上传 asset（已存在则跳过）----------
ASSET_NAME=$(basename "$WHL")
# GitHub 侧存的名字有两种可能：保留 '+'（上传时已 URL 编码）或被规范化成 '.'（历史/未编码），两种都比对
ASSET_KEYS=$(printf '%s\n%s\n' "$ASSET_NAME" "$(printf '%s' "$ASSET_NAME" | tr '+' '.')" | sort -u)
list_assets() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
                  "$API/repos/$REPO/releases/$RELEASE_ID/assets"; }
asset_id_of() { python3 -c "
import json, sys
keys = set(sys.argv[1:])
print(next((a['id'] for a in json.load(sys.stdin) if a['name'] in keys), ''))
" $ASSET_KEYS; }
EXIST=$(list_assets | asset_id_of 2>/dev/null)
if [ -n "$EXIST" ]; then
  echo "publish: asset 已存在（id=$EXIST），跳过上传"
else
  echo "publish: 上传 $ASSET_NAME ..."
  # name 必须 URL 编码：否则 + 会被当成空格，GitHub 会把 asset 名规范化成 . 导致下载链接 404
  ASSET_Q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$ASSET_NAME")
  if curl -sS --fail-with-body -X POST \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
      --data-binary "@$WHL" -o /tmp/wsdl_asset.json \
      "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$ASSET_Q"; then
    python3 -c "import json;d=json.load(open('/tmp/wsdl_asset.json'));print('publish: ✅ 上传完成', d.get('browser_download_url',''))"
  elif [ -n "$(list_assets | asset_id_of 2>/dev/null)" ]; then
    echo "publish: asset 已存在（并发上传或命名规范化），视为成功"
  else
    echo "publish: ❌ 上传失败"; sed -n '1,3p' /tmp/wsdl_asset.json 2>/dev/null; exit 1
  fi
fi
echo "publish: done"
