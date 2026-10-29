[English](README.md) | **简体中文**

# OWW211 临时 root —— Permissive + uid0

> **OPPO Watch 3 Pro（OWW211 / Snapdragon W5 "monaco" / A.142 / Linux 5.4.134-00522）的临时 root。**
> 成功判据：`getenforce` = `Permissive`，且 `/data/local/tmp/.dfr/ready` 显示 `uid=0`。
> **重启即失效**（全部改动都在页缓存与内核内存里，不落盘）；重跑脚本即可再次获得。

---

## ⚠️ 适用范围（必须匹配，否则不要跑）

| 项 | 值 |
|---|---|
| 机型 | OPPO Watch 3 Pro `OWW211` |
| 固件 | `OWW211_11_A.142`（`ro.build.display.id`） |
| 内核 | `5.4.134-perf-00522-gb29f81177a79`，ARMv7 |
| 安全补丁 | `2021-09-05` |

载荷里的所有偏移（liblog 钩点、死区、KO 偏移）都是按 **A.142 / 00522** 实测量的；
其他固件请勿直接使用（脚本会拒绝，除非 `FORCE=1`）。
仅用于**你自己的设备**或明确授权的测试环境。

---

## 一键使用（小白版）

1. 装好 adb（Platform Tools）、Python 和 Git for Windows。
2. 手表用 USB 连电脑，解锁并在弹窗里点「允许 USB 调试」。
3. **双击 `一键root.cmd`**（`一键root.bat` 只是转发到它），按屏幕提示做即可。

脚本会自动完成：找设备 → 建立 uid0 通道（DirtyFrag 链，失败自动重启重试）→
启动本地 root shell（`/data/local/tmp/rootshell` + `adb forward`）→ 验证 → **直接在窗口里进入 root shell**。

> root shell 是 `uid=0` + `CapEff=0x3fffffffff`，通过 `adb forward tcp:5556 tcp:5555` 接入，
> **不需要拔插、不需要重启 adbd**。手动进入：`python tools/rootshell_client.py 5556`。

成功后会看到：

```
==============================================
 ✅ 完成！adb shell 现在是 root
==============================================
   uid=0(root) gid=0(root) ...
   CapEff: 0000003fffffffff
```

> 为什么还要手工操作一次：adbd 只在启动时决定要不要降权，而 init 拒绝任何软件方式的
> `stop/start adbd`（属性检查无视 Permissive），杀掉 adbd 又不会自动重启。
> 唯一可靠的触发是：手表上 设置 → 系统 → 开发者选项 → 把「USB 调试」关掉，等 2 秒再打开。
> 重启手表后补丁失效，重新双击脚本即可。

---

## 一键使用（命令行）

前置：`adb` 可用、手表开启 USB 调试并已授权。

```bash
SERIAL=<你的序列号> ./run.sh        # 或 ./run.sh -s <序列号>（只连一台时可省略）
```

脚本会：校验固件 → 安装内置 DF app（如缺）→ 推送镜像/块/r.sh → 分两段把载荷写进
`liblog` 页缓存 → 触发 vold/init/wifi HAL → 验证并打印 uid0 证据。

之后用通道执行任意 root 命令：

```bash
./cmd.sh 'id; ls /data; ls /data/data | head'
./cmd.sh 'cat /data/system/packages.xml | head -5'
```

恢复原状：直接重启（`adb reboot`）。没有任何持久化改动。

---

## 它是怎么工作的（4 步链）

1. **DirtyFrag（CVE-2026-43284）页缓存写**：内置的 DF app 通过 `IpSecManager` + ESP
   在回环上做原地解密，把任意内容写进**只读系统文件**的页缓存（本方案写 `liblog.so`）。
2. **漏斗钩子**：把 `__android_log_write_log_message` 入口改成跳板，任意进程打日志时
   执行我们的 438B 载荷。载荷按调用者分流：
   - 进程名 `vold` → 打开 `/data/media/0/m.img` + `/dev/block/loop0` 并 `LOOP_SET_FD`；
   - 进程名 `init` / `installd`（uid0）→ `mount(ext4,ro)` 到 `/vendor/lib/mediacas`，
     然后 `clone+execve("/system/bin/sh","/data/local/tmp/r.sh")` —— **uid0 通道**；
   - 日志 tag `WifiHAL` → `openat("/vendor/lib/mediacas/k")` + `finit_module()`。
3. **自制 vendor_file 载体**：`assets/m.img` 是一个 16MB ext4，里面 `/k` 是我们的内核模块，
   **根目录和文件都带 `security.selinux=u:object_r:vendor_file:s0`** 内联 xattr。
   挂载后 `k` 天生是 `vendor_file`，`hal_wifi` 对它 `finit_module` 会被 SELinux 放行。
4. **内核模块**：`dfk.ko`（手搓，无外部符号）只做一件事——把 `selinux_state.enforcing`
   （`0xc1d5a720 + 1`）写 0 ⇒ 全局 **Permissive**。`initialized` 不动，系统不会失能。

为什么不能直接 `echo 0 > /sys/fs/selinux/enforce`：内核在 `sel_write_enforce()` 里
还会查 `security:setenforce`，而本策略**没有任何域**被授予该权限（只有 neverallow）。
所以必须内核态落地。

---

## 文件结构

```
一键root.cmd           小白入口（推荐）：双击 → root_oneclick.sh（带自动重试）
一键root.bat           转发到 一键root.cmd
root_oneclick.sh        一键编排：通道重试→启动 root shell→adb forward→验证→进入交互
run.sh                  一键执行（校验/安装/写块/触发/验证）
cmd.sh                  通过 uid0 通道执行命令
adbroot.sh              让 adb shell 直接是 root（改 adbd 降权桩 + bind mount）
assets/
  m.img                 16MB ext4 载体（含 /k，vendor_file 标签）
  dfk.ko                内核模块（__versions + .plt/.init.plt 齐备）
  dfroot.apk            DirtyFrag app（已签名）
  r.sh                  uid0 通道脚本（轮询 .dfr/cmd）
  blocks/               载荷的 16B 写入块（h3 最先写、h1 最后写；p* 为载荷体、s* 为桩）
tools/
  rootshell.exe         root shell 服务端（ARM，一键脚本推送到设备）
  rootshell_client.py   root shell 客户端（`python tools/rootshell_client.py 5556`）
  check_rootshell.py    root shell 就绪探测（一键脚本内部使用）
  propset.exe           属性设置小工具（adbroot.sh 使用）
  adbd_root             降权桩已补的 adbd（adbroot.sh / run.sh 使用）
```

## 故障排查

- **`device not found` / 设备消失**：先同时查 `adb devices` 与 `fastboot devices`。
  若在 fastboot：只读 `fastboot getvar product/serialno/unlocked`，用 **`fastboot reboot`**
  拉回；不要刷写/擦除。
- **脚本报"未达成"**：多为页缓存窗口错过。确认 uptime 稳定后**直接重跑**一次；
  仍失败看脚本打印的 `dfselperm` 内核错误（PLT / symbol version / vermagic）。
- **执行后黑屏/异常**：`adb reboot` 即可完全恢复（无落盘改动）。
- **Do not** 在别的固件上 `FORCE=1` 跑：偏移不匹配可能导致内核 panic。

## 已知边界

- 临时性：重启、甚至页面被内核回收后都需要重跑。
- 依赖本固件的 `liblog.so`（内置块按该文件量取）；系统 OTA 后需重新量偏移。
- `r.sh` 以 `u:r:toolbox:s0` 上下文运行（exec 后的域），`uid=0` + Permissive ⇒ 实际全权。

## 免责声明

本项目只用于**自有设备**的授权测试与安全研究。请勿用于你无权控制的设备。
