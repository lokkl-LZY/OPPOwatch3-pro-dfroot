#!/usr/bin/env bash
# =============================================================================
# adbroot.sh —— 让 adb shell 直接以 uid0 + 全 capability 运行
#
# 原理: user build 的 adbd 在启动时把自己降到 shell（ro.debuggable 无效、
#       ALLOW_ADBD_ROOT 未编入）。把它内部 minijail 的 5 个降权 PLT 桩改成
#       "返回 0"，再用 bind mount 覆盖 APEX 里的原文件；init 重新拉起 adbd 时
#       它就不会降权，adb shell 即为 root。
#
# 前置: 设备已经是 root（先跑 ./run.sh 拿 DF 通道，或 adb shell 已经是 root）
# 用法:
#   SERIAL=<sn> ./adbroot.sh            # 打补丁 + 挂载, 然后按提示拔插 USB
#   SERIAL=<sn> ./adbroot.sh --restore  # 撤掉挂载, 恢复原版 adbd（+ 拔插 USB）
# 注意: 没有任何软件办法重启 adbd —— init 的属性检查会拒绝 ctl.stop/start，
#       强行 kill 会让 USB gadget 失联。唯一可靠的触发是"拔插 USB 线"或重启。
# =============================================================================
set -uo pipefail
DIR_RAW="$(cd "$(dirname "$0")" && pwd)"
if command -v cygpath >/dev/null 2>&1; then DIR="$(cygpath -m "$DIR_RAW")"; else DIR="$DIR_RAW"; fi
ADB="${ADB:-adb}"; SERIAL="${SERIAL:-}"
export MSYS2_ARG_CONV_EXCL="*"
ORIG_MD5="e132182d5f3d4c2b05c569b1c30c35ae"   # OWW211 A.142 / com.android.adbd APEX 原版
TGT=/apex/com.android.adbd/bin/adbd
say(){ printf '%s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

[ -n "$SERIAL" ] || { mapfile -t D < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}'); [ "${#D[@]}" -eq 1 ] || die "请用 SERIAL=<序列号>"; SERIAL="${D[0]}"; }
sh_(){ timeout 60 "$ADB" -s "$SERIAL" shell "$@" 2>&1 | tr -d '\r'; }
# 挂载需要 uid0: adb shell 已是 root 就直接用, 否则走 DF 通道(cmd.sh)
if [ "$(sh_ 'id -u')" = "0" ]; then
  dev(){ sh_ "$@"; }
else
  PR=$(SERIAL="$SERIAL" TIMEOUT=8 bash "$DIR_RAW/cmd.sh" 'id -u' 2>/dev/null | tr -d '\r' | grep -x '0' | head -1)
  [ "${PR:-}" = "0" ] || \
die "当前 adb shell 不是 root 且 DF 通道未运行。先跑 ./run.sh 拿到 uid0 再执行本脚本"
  dev(){ SERIAL="$SERIAL" bash "$DIR_RAW/cmd.sh" "$*" 2>&1 | sed '/^--- rc=/d'; }
fi

if [ "${1:-}" = "--restore" ]; then
  # 运行中的 adbd 正映射着 bind 文件, 普通 umount 会 EBUSY ⇒ 用 lazy umount
  dev "umount -l $TGT 2>/dev/null; echo restored; md5sum $TGT" | sed 's/^/    /'
  say ""
  say "下一步: 拔插 USB 线（或重启），adbd 会以原版身份重新启动。"
  say "       （lazy umount 只是摘掉视图，补丁版 adbd 进程会一直跑到下次重启/拔插）"
  exit 0
fi

TMP="$DIR/.adbd.orig"
say "[1/4] 拉取原版 adbd"
TT="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/adbd.orig.$$"
"$ADB" -s "$SERIAL" pull "$TGT" "$TT" >/dev/null 2>&1 && mv -f "$TT" "$TMP" || die "拉取失败（若为中文路径问题，可用 ASCII 目录）"
GOT=$(md5sum "$TMP" | awk '{print $1}')
say "      md5=$GOT"
ALREADY=0
if [ "$GOT" = "59a45c4c617c11d9cb879a81a7be53be" ]; then
  ALREADY=1
  say "      当前已是补丁版（挂载生效中），跳过打补丁"
elif [ "$GOT" != "$ORIG_MD5" ] && [ "${FORCE:-0}" != "1" ]; then
  die "adbd 指纹不匹配（偏移按 A.142 量取）。确认风险后可 FORCE=1 重试"
fi

if [ "$ALREADY" = "0" ]; then
say "[2/4] 打 5 个降权桩补丁"
"${PYTHON:-python}" - "$TMP" <<'PY' || die "补丁失败"
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
sites = {0xf6c90: 'capset', 0xf6d90: 'setgroups', 0xf6da0: 'initgroups',
         0xf6db0: 'setresgid', 0xf6dc0: 'setresuid'}
for off, name in sites.items():
    if bytes(d[off:off+4]) != bytes.fromhex('00c68fe2'):
        sys.exit('offset mismatch at %s (0x%x)' % (name, off))
    d[off:off+4] = bytes.fromhex('0000a0e3')   # mov r0,#0
    d[off+4:off+8] = bytes.fromhex('1eff2fe1') # bx lr
open(p, 'wb').write(d)
print('      patched: ' + ' '.join(sites.values()))
PY
fi

say "[3/4] 推送并挂载"
MOUNTED=$(sh_ "mount | grep -c ' on $TGT '")
if [ "$ALREADY" = "1" ] && [ "${MOUNTED:-0}" -ge 1 ]; then
  say "      已经是补丁版且挂载生效，跳过（adbd 正映射该文件，umount 会 EBUSY）"
else
  "$ADB" -s "$SERIAL" push "$TMP" /data/local/tmp/adbd_root >/dev/null 2>&1 || die "推送失败"
  sh_ 'chmod 755 /data/local/tmp/adbd_root' >/dev/null
  dev "umount -l $TGT 2>/dev/null; mount --bind /data/local/tmp/adbd_root $TGT && echo BIND-OK; md5sum $TGT" | sed 's/^/      /'
fi
rm -f "$TMP"

say "[3.5/4] 打开 ro.debuggable（让 adbd 跳过降权, 含 capability 边界集）"
if [ -z "$(sh_ 'test -f /data/local/tmp/propset && echo 1')" ]; then
  "$ADB" -s "$SERIAL" push "$DIR/tools/propset.exe" /data/local/tmp/propset >/dev/null 2>&1
  sh_ 'chmod 755 /data/local/tmp/propset' >/dev/null
fi
dev '/data/local/tmp/propset /dev/__properties__ ro.debuggable 1 0' | sed 's/^/      /'

say "[4/4] 等待 adbd 重启"
say ""
say "  现在做一步手工操作（在手表屏幕上，一次即可）:"
say "    设置 -> 系统 -> 开发者选项 -> 「USB 调试」关掉，等 2 秒，再打开"
say "    弹窗「允许 USB 调试」勾选始终允许"
say ""
say "  为什么必须这样做: adbd 是 init 的常驻服务，【拔插 USB 不会重启它】；"
say "  只有 sys.usb.config 变化（由框架在 USB 调试开关时下发）才会 stop/start adbd，"
say "  而 init 拒绝我们直接 ctl.stop/start，直接 kill 会让 USB gadget 失联。"
say ""
say "  若 adb 显示 not found: 电脑上执行 adb kill-server && adb start-server"
say ""
say "  插回后验证:  adb shell id    → 期望 uid=0(root)，CapEff=0000003fffffffff"
say "  还原:        SERIAL=$SERIAL ./adbroot.sh --restore   然后拔插 USB"
