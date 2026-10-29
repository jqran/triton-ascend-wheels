#!/bin/bash
# =============================================================================
# check_failure.sh —— 登录提示：ws_daily 最近一次构建有问题就打印醒目提示
#
# 设计：逻辑放脚本里，.bashrc 只留三行调用（便于测试与复用，比如手动跑或放 cron）。
#   · 只有 state/ATTENTION 存在才输出，否则**静默退出**（对登录零打扰、开销就是一次 test）
#   · 需要更详细的信息就 cat state/health.txt
#   · 消除提示：ack_last_failure.sh（或等 all 模式两条线都真跑成功）
# 环境变量：WS_DAILY_ROOT 可覆盖工作区（默认 ~/ws_daily）
# =============================================================================
set -u
W=${WS_DAILY_ROOT:-$HOME/ws_daily}
A=$W/state/ATTENTION              # 构建失败（daily_build.sh 写）
AS=$W/state/ATTENTION.sync        # a5 同步异常（a5_sync_service.py 写；独立文件，互不覆盖）
SH=$W/state/sync_health.txt
[ -e "$A" ] || [ -e "$AS" ] || exit 0          # 两类都没有 → 静默

H=$W/state/health.txt
if [ -t 1 ]; then R=$'\033[1;31m'; Y=$'\033[1;33m'; B=$'\033[1m'; N=$'\033[0m'; else R=; Y=; B=; N=; fi
# 优先指向"真正失败的那个变体"的日志 —— 否则一律取最新那份，可能指向成功的那条线（2026-10-22 踩到）
FAIL_LOGS=""
for f in "$W/state/last_run.txt" "$W/stable/state/last_run.txt"; do
  [ -f "$f" ] || continue
  line=$(tail -1 "$f")
  st=$(printf '%s' "$line" | sed -n 's/.* status=\([^ ]*\).*/\1/p')
  lg=$(printf '%s' "$line" | sed -n 's/.* log=\([^ ]*\).*/\1/p')
  case "$st" in OK|SKIPPED_UNCHANGED) ;; *) [ -n "$lg" ] && FAIL_LOGS="$FAIL_LOGS $lg" ;; esac
done
LOG_LAST=$(ls -t "$W"/logs/daily_*_*.log 2>/dev/null | head -1)
PUB_LAST=$(ls -t "$W"/logs/publish_*.log 2>/dev/null | head -1)

echo
echo "${R}${B}╔════════════════════════════════════════════════════════════════════════╗${N}"
echo "${R}${B}║   ⚠️   ws_daily：构建或 a5 同步有问题，请看一眼                       ║${N}"
echo "${R}${B}╚════════════════════════════════════════════════════════════════════════╝${N}"
if [ -e "$A" ]; then
  echo "  ${B}【构建】${N}"
  printf '  %s%s%s\n' "$Y" "$(cat "$A" 2>/dev/null)" "$N"
  if [ -f "$H" ]; then
    while IFS= read -r l; do printf '    %s\n' "$l"; done < "$H"
  fi
fi
if [ -e "$AS" ]; then
  echo "  ${B}【a5 同步】${N}"
  printf '  %s%s%s\n' "$Y" "$(cat "$AS" 2>/dev/null)" "$N"
  if [ -f "$SH" ]; then
    while IFS= read -r l; do printf '    %s\n' "$l"; done < "$SH"
  fi
fi
echo "  ${B}快速动作${N}"
if [ -n "$FAIL_LOGS" ]; then
  for lg in $FAIL_LOGS; do echo "    看日志     : tail -n 50 $lg"; done
else
  echo "    看日志     : tail -n 50 ${LOG_LAST:-$W/logs/daily_<variant>_<日期>.log}"
fi
if [ -n "${PUB_LAST:-}" ]; then
  echo "    发布日志   : tail -n 30 $PUB_LAST"
else
  echo "    发布日志   : （本轮没跑发布）"
fi
echo "    同步日志   : tail -n 30 $W/logs/a5_sync_cron.log"
echo "    产物索引   : cat $W/out/INDEX.md"
echo "    变体状态   : cat $W/{state,stable/state}/last_run.txt"
echo "    消除本提示 : $W/ack_last_failure.sh"
echo
exit 0
