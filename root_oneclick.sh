#!/usr/bin/env bash
# =============================================================================
# root_oneclick.sh —— OWW211 一键 root
#
# 自动化到"只剩一个人工动作"：
#   1. 找设备（adb / fastboot 都查）
#   2. 确保 uid0 通道（必要时跑 run.sh，起不来自动重启重试）
#   3. ro.debuggable=1
#   4. adbd 打补丁 + bind mount
#   5. 启动 TCP root shell（这一步就已经是 uid0，不需要任何人工）
#   6. 【需你操作一次】在手表上关/开「USB 调试」→ 脚本自动等待并验证 adb shell 变 root
#   7. 汇总
#
# 为什么第 6 步必须人工：
#   adbd 是 init 的常驻服务，只在启动时决定要不要降权；init 拒绝任何软件方式的
#   stop/start（属性检查，审计里 permissive=0），直接 kill 会让 USB gadget 失联。
#   ★ 拔插 USB 无效；唯一可靠的触发是让框架下发 sys.usb.config 变化，
#     也就是在设置里把「USB 调试」关掉再打开。
# =============================================================================
set -uo pipefail
DIR_RAW="$(cd "$(dirname "$0")" && pwd)"
if command -v cygpath >/dev/null 2>&1; then DIR="$(cygpath -m "$DIR_RAW")"; else DIR="$DIR_RAW"; fi
cd "$DIR_RAW" || exit 1
ADB="${ADB:-adb}"
export MSYS2_ARG_CONV_EXCL="*"

say(){ printf '%s\n' "$*"; }
step(){ printf '\n[%s] %s\n' "$1" "$2"; }
ok(){   printf '   ✅ %s\n' "$*"; }
warn(){ printf '   ⚠️  %s\n' "$*"; }
die(){  printf '\n❌ %s\n\n' "$*"; exit 1; }

say "=============================================="
say "   OPPO Watch 3 Pro (OWW211) 一键 root"
say "=============================================="

# ---------- 1. 找设备 ----------
step "1/7" "找设备"
command -v "$ADB" >/dev/null 2>&1 || die "找不到 adb。请安装 Android Platform Tools 并加入 PATH（或设 ADB=C:\\path\\to\\adb.exe）"
SERIAL="${SERIAL:-}"
for i in $(seq 1 15); do
  if [ -z "$SERIAL" ]; then
    mapfile -t DEVS < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
    [ "${#DEVS[@]}" -ge 1 ] && { SERIAL="${DEVS[0]}"; break; }
  else
    "$ADB" -s "$SERIAL" get-state 2>/dev/null | grep -q device && break
  fi
  FB=$(timeout 5 fastboot devices 2>/dev/null | awk '{print $1}' | head -1 || true)
  [ -n "$FB" ] && die "设备在 fastboot 模式（$FB）。请长按手表电源键约 10 秒重启到系统，再运行本脚本。"
  sleep 2
done
[ -n "${SERIAL:-}" ] || die "找不到设备。请检查：USB 线、手表已解锁、屏幕上点过「允许 USB 调试」。"
ok "设备: $SERIAL"
sh_(){ timeout 60 "$ADB" -s "$SERIAL" shell "$@" 2>&1 | tr -d '\r'; }

# 已 root 直接结束
if [ "$(sh_ 'id -u')" = "0" ]; then
  ok "adb shell 已经是 root"
  sh_ 'id; grep -E "^Cap(Eff|Bnd)" /proc/self/status' | sed 's/^/   /'
  say ""; say "=============================================="
  say " ✅ 完成（本来就是 root）"
  say "=============================================="
  exit 0
fi

# ---------- 2. 确保 uid0 通道 ----------
ch_alive(){
  local r
  r=$(SERIAL="$SERIAL" TIMEOUT=8 bash "$DIR_RAW/cmd.sh" 'id -u' 2>/dev/null | tr -d '\r' | grep -x '0' | head -1)
  [ "${r:-}" = "0" ]
}
wait_boot(){
  local i
  for i in $(seq 1 40); do
    sleep 3
    [ "$(sh_ 'cut -d" " -f1 /proc/uptime' 2>/dev/null | cut -d. -f1)" -ge 45 ] 2>/dev/null && return 0
  done
  return 1
}

step "2/7" "建立 uid0 通道"
for attempt in 1 2 3 4 5; do
  if ch_alive; then ok "通道已在运行"; break; fi
  # 已加载载荷但通道没建（上一轮 clone 失败）→ run.sh 会因保险拒绝，直接重启更快
  ENF_NOW=$(sh_ 'getenforce')
  MOD_NOW=$(sh_ 'cat /proc/modules 2>/dev/null | grep -c dfselperm')
  if [ "$ENF_NOW" = "Permissive" ] && [ "${MOD_NOW:-0}" -ge 1 ]; then
    warn "载荷已在但通道未建立（clone 失败）→ 直接重启重试"
    "$ADB" -s "$SERIAL" reboot >/dev/null 2>&1
    sleep 20
    wait_boot || true
    sleep 5
    continue
  fi
  say "   第 $attempt 轮：执行 run.sh（约 1~2 分钟）…"
  SERIAL="$SERIAL" bash "$DIR_RAW/run.sh" 2>&1 | sed 's/^/   /' | tail -12
  if ch_alive; then ok "通道已建立"; break; fi
  if [ "$attempt" -lt 5 ]; then
    warn "本轮没拿到通道，自动重启后再试（页面窗口没赶上）"
    "$ADB" -s "$SERIAL" reboot >/dev/null 2>&1
    sleep 20
    wait_boot || true
    sleep 5
  else
    die "5 轮都没拿到 uid0 通道。请长按电源键重启手表，然后再运行本脚本一次。"
  fi
done

# ---------- 3. ro.debuggable ----------
step "3/7" "设置 ro.debuggable=1（决定 adbd 是否保留全能力）"
SERIAL="$SERIAL" TIMEOUT=25 bash "$DIR_RAW/cmd.sh" \
  '/data/local/tmp/propset /dev/__properties__ ro.debuggable 1 0 >/dev/null 2>&1; getprop ro.debuggable' \
  | grep -E '^[01]$' | sed 's/^/   值: /'

# ---------- 4. adbd 补丁 + 挂载 ----------
step "4/7" "给 adbd 打补丁并挂载"
SERIAL="$SERIAL" bash "$DIR_RAW/adbroot.sh" 2>&1 | sed -n '1,8p' | sed 's/^/   /'
ok "adbd 补丁已就位（等 adbd 重启后生效）"

# ---------- 5. 起 TCP root shell（现在就可用，不需要人工）----------
step "5/7" "启动 root shell（经 adb forward，立即可用）"
if [ -z "$(sh_ 'test -f /data/local/tmp/rootshell && echo 1')" ]; then
  "$ADB" -s "$SERIAL" push "$DIR/tools/rootshell.exe" /data/local/tmp/rootshell >/dev/null 2>&1
  sh_ 'chmod 755 /data/local/tmp/rootshell' >/dev/null
fi
SERIAL="$SERIAL" TIMEOUT=15 bash "$DIR_RAW/cmd.sh"   'setsid /data/local/tmp/rootshell 5555 >/dev/null 2>&1 </dev/null & echo started' >/dev/null 2>&1
"$ADB" -s "$SERIAL" forward tcp:5556 tcp:5555 >/dev/null 2>&1
VER=$("${PYTHON:-python}" "$DIR/tools/check_rootshell.py" 5556 2>/dev/null)
if printf '%s' "$VER" | grep -q '^0$'; then
  ok "root shell 可用（python tools/rootshell_client.py 5556）"
else
  warn "root shell 未起来（$VER），但 DF 通道仍可用：bash cmd.sh 'id -u'"
fi

# ---------- 6. 唯一的人工步骤：让 adbd 重启 ----------
step "6/7" "让 adb shell 也变成 root —— 请在手表上做一次"
say ""
say "   手表上依次点："
say "     设置 → 系统 → 开发者选项 → 「USB 调试」→ 关闭"
say "     等 2 秒 → 再打开 → 弹窗勾选「始终允许」→ 确定"
say ""
say "   ★ 拔插 USB 无效（adbd 是常驻服务）；重启会丢补丁。"
say ""
say "   正在等待 adb 回来…（最多 240 秒，可随时按 Ctrl+C 放弃）"
say ""

adb_uid(){
  local u
  u=$("$ADB" -s "$SERIAL" shell 'id -u' 2>/dev/null | tr -d '\r')
  printf '%s' "$u"
}

GOT0=0
for i in $(seq 1 80); do
  sleep 3
  st=$("$ADB" -s "$SERIAL" get-state 2>/dev/null)
  if [ "$st" != "device" ]; then
    printf '.'
    # 每 12 秒踢一次 adb server，帮助重新枚举
    if [ $((i % 4)) -eq 0 ]; then
      "$ADB" kill-server >/dev/null 2>&1; sleep 1; "$ADB" start-server >/dev/null 2>&1
    fi
    continue
  fi
  u=$(adb_uid)
  if [ "$u" = "0" ]; then GOT0=1; break; fi
  printf '.'
done
say ""

if [ "$GOT0" = "1" ]; then
  ok "adb shell 已是 uid 0"
  "$ADB" -s "$SERIAL" forward tcp:5556 tcp:5555 >/dev/null 2>&1
  sh_ 'id; getenforce; grep -E "^Cap(Eff|Bnd)" /proc/self/status' | sed 's/^/   /'
else
  warn "还没等到 uid0。可能原因："
  say "     - 还没做那一步开关（做完脚本会自动识别，也可以重跑本脚本）"
  say "     - adb 处于 MTP/关闭状态：重启手表后重跑本脚本"
  say ""
  say "   注意：即使这一步没成功，你现在仍然有 root —— 用"
  say "     python tools\\rootshell_client.py 5556"
  say "   或"
  say "     bash cmd.sh 'id -u'"
fi

# ---------- 7. 汇总 ----------
step "7/7" "结果"
if [ "$GOT0" = "1" ]; then
  say "   adb shell      : uid=0(root) + 全能力 + $(sh_ 'getenforce')"
else
  say "   adb shell      : 仍是 $(sh_ 'id -u')（等第 6 步的开关）"
fi
say "   TCP root shell : python tools\\rootshell_client.py 5556"
say "   单条命令       : bash cmd.sh 'id -u'"
say ""
say "   重启后全部失效，重跑本脚本即可。"
say ""
