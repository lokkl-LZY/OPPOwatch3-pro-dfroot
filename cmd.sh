#!/usr/bin/env bash
# cmd.sh —— 通过 uid0 通道执行任意命令
#   用法: ./cmd.sh 'id; ls /data/data | head'
#         SERIAL=<sn> TIMEOUT=300 ./cmd.sh 'dd if=/dev/block/by-name/boot of=/data/local/tmp/boot.img'
set -uo pipefail
DIR_RAW="$(cd "$(dirname "$0")" && pwd)"
if command -v cygpath >/dev/null 2>&1; then DIR="$(cygpath -m "$DIR_RAW")"; else DIR="$DIR_RAW"; fi
ADB="${ADB:-adb}"; SERIAL="${SERIAL:-}"; TIMEOUT="${TIMEOUT:-120}"
export MSYS2_ARG_CONV_EXCL="*"
[ $# -ge 1 ] || { echo "用法: $0 '<命令>'"; exit 2; }
CMD="$*"

if [ -z "$SERIAL" ]; then
  mapfile -t DEVS < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
  [ "${#DEVS[@]}" -eq 1 ] || { echo "请用 SERIAL=<序列号> 指定设备"; exit 2; }
  SERIAL="${DEVS[0]}"
fi
sh_(){ timeout 40 "$ADB" -s "$SERIAL" shell "$@" 2>&1 | tr -d '\r'; }

[ -n "$(sh_ 'cat /data/local/tmp/.dfr/ready 2>/dev/null')" ] || {
  echo "[x] uid0 通道未运行，先执行 ./run.sh"; exit 1; }

printf '%s' "$CMD" > "$DIR/.cmd.txt"
# 先清掉上一轮输出, 否则会把旧结果当成这次的
sh_ 'rm -f /data/local/tmp/.dfr/out' >/dev/null
# 推到临时名再 mv: 避免通道读到半截命令
"$ADB" -s "$SERIAL" push "$DIR/.cmd.txt" /data/local/tmp/.dfr/cmd.tmp >/dev/null 2>&1 || {
  echo "[x] 推送命令失败"; exit 1; }
sh_ 'mv /data/local/tmp/.dfr/cmd.tmp /data/local/tmp/.dfr/cmd' >/dev/null
rm -f "$DIR/.cmd.txt"

OUT=""
for i in $(seq 1 "$TIMEOUT"); do
  OUT=$(sh_ 'cat /data/local/tmp/.dfr/out 2>/dev/null')
  printf '%s' "$OUT" | grep -q -- '--- rc=' && break
  sleep 1
done
printf '%s\n' "$OUT"
