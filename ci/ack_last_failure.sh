#!/bin/bash
# =============================================================================
# ack_last_failure.sh —— 确认已看到失败提示，消除登录时的醒目提示
#   把当前 ATTENTION 内容追加到 state/health.txt 作为历史记录，然后删掉 ATTENTION。
#   注意：只是"确认看过"，不改构建状态；下次再失败会重新置 ATTENTION。
# =============================================================================
set -u
W=${WS_DAILY_ROOT:-$HOME/ws_daily}
A=$W/state/ATTENTION              # 构建失败
AS=$W/state/ATTENTION.sync        # a5 同步异常
if [ ! -e "$A" ] && [ ! -e "$AS" ]; then
  echo "没有待确认的提示（$A、$AS 都不存在）"
  exit 0
fi
n=0
for f in "$A" "$AS"; do
  [ -e "$f" ] || continue
  {
    echo "acked: $(date '+%F %T') by $(id -un)@$(hostname) ($(basename "$f"))"
    sed 's/^/acked-content: /' "$f"
  } >> "$W/state/health.txt"
  rm -f "$f"
  n=$((n + 1))
done
echo "✅ 已消除登录提示（$n 类）；历史记录保留在 $W/state/health.txt"
