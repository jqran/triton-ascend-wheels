#!/bin/bash
# =============================================================================
# ack_last_failure.sh —— 确认已看到失败提示，消除登录时的醒目提示
#   把当前 ATTENTION 内容追加到 state/health.txt 作为历史记录，然后删掉 ATTENTION。
#   注意：只是"确认看过"，不改构建状态；下次再失败会重新置 ATTENTION。
# =============================================================================
set -u
W=${WS_DAILY_ROOT:-$HOME/ws_daily}
A=$W/state/ATTENTION
if [ ! -e "$A" ]; then
  echo "没有待确认的构建失败提示（$A 不存在）"
  exit 0
fi
{
  echo "acked: $(date '+%F %T') by $(id -un)@$(hostname)"
  sed 's/^/acked-content: /' "$A"
} >> "$W/state/health.txt"
rm -f "$A"
echo "✅ 已消除登录提示；历史记录保留在 $W/state/health.txt"
