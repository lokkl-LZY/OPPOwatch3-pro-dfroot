**English** | [简体中文](README.zh-CN.md)

# OWW211 Temporary Root — Permissive + uid0

> **Temporary root for the OPPO Watch 3 Pro (OWW211 / Snapdragon W5 "monaco" / A.142 / Linux 5.4.134-00522).**
> Success criteria: `getenforce` returns `Permissive`, and `/data/local/tmp/.dfr/ready` reports `uid=0`.
> **A reboot wipes it** (all changes live in the page cache and kernel memory, nothing is written to disk);
> simply re-run the script to gain root again.

---

## ⚠️ Compatibility (must match, otherwise do not run)

| Item | Value |
|---|---|
| Device | OPPO Watch 3 Pro `OWW211` |
| Firmware | `OWW211_11_A.142` (`ro.build.display.id`) |
| Kernel | `5.4.134-perf-00522-gb29f81177a79`, ARMv7 |
| Security patch | `2021-09-05` |

All offsets in the payloads (liblog hook point, dead zone, KO offsets) were measured on **A.142 / 00522**.
Do not use on other firmware (the script refuses unless `FORCE=1`).
For **your own device** or an explicitly authorized test environment only.

---

## One-click usage (beginner)

1. Install adb (Platform Tools), Python, and Git for Windows.
2. Connect the watch over USB, unlock it, and tap "Allow USB debugging".
3. **Double-click `一键root.cmd`** (`一键root.bat` only forwards to it) and follow the on-screen prompts.

The script does the rest: find the device → establish the uid0 channel (DirtyFrag chain, with automatic
reboot-and-retry) → start a local root shell (`/data/local/tmp/rootshell` + `adb forward`) → verify →
**drop you straight into a root shell**.

> The root shell is `uid=0` with `CapEff=0x3fffffffff`, reachable via `adb forward tcp:5556 tcp:5555` —
> **no cable replug, no adbd restart needed**. Manual access: `python tools/rootshell_client.py 5556`.

On success you will see:

```
==============================================
 ✅ 完成！adb shell 现在是 root
==============================================
   uid=0(root) gid=0(root) ...
   CapEff: 0000003fffffffff
```

> Why one manual step is still required: adbd decides at startup whether to drop privileges; init refuses
> any software `stop/start adbd` (the property check ignores Permissive), and killing adbd does not restart
> it. The only reliable trigger: on the watch, Settings → System → Developer options → toggle
> "USB debugging" off, wait 2 seconds, toggle it back on. The patch is lost on reboot — just double-click
> the script again.

---

## Command-line usage

Prerequisite: `adb` available, USB debugging enabled and authorized.

```bash
SERIAL=<your-serial> ./run.sh        # or ./run.sh -s <serial> (optional when only one device is connected)
```

The script will: verify firmware → install the bundled DF app (if missing) → push image/blocks/r.sh →
write the payload into the `liblog` page cache in two stages → trigger vold/init/wifi HAL → verify and
print uid0 evidence.

Then run arbitrary root commands through the channel:

```bash
./cmd.sh 'id; ls /data; ls /data/data | head'
./cmd.sh 'cat /data/system/packages.xml | head -5'
```

Restore: just reboot (`adb reboot`). Nothing persists.

---

## How it works (4-step chain)

1. **DirtyFrag (CVE-2026-43284) page-cache write**: the bundled DF app uses `IpSecManager` + ESP over
   loopback to decrypt in place, writing arbitrary content into the page cache of a **read-only system
   file** (here `liblog.so`).
2. **Funnel hook**: the entry of `__android_log_write_log_message` is patched to a trampoline; whenever
   any process logs, our 438-byte payload runs. The payload dispatches by caller:
   - process `vold` → opens `/data/media/0/m.img` + `/dev/block/loop0` and issues `LOOP_SET_FD`;
   - process `init` / `installd` (uid0) → `mount(ext4,ro)` at `/vendor/lib/mediacas`, then
     `clone+execve("/system/bin/sh","/data/local/tmp/r.sh")` — the **uid0 channel**;
   - log tag `WifiHAL` → `openat("/vendor/lib/mediacas/k")` + `finit_module()`.
3. **Home-made vendor_file carrier**: `assets/m.img` is a 16MB ext4 image containing `/k` (our kernel
   module); both the root directory and the file carry the inline xattr
   `security.selinux=u:object_r:vendor_file:s0`. After mounting, `k` is a genuine `vendor_file`, so
   `finit_module` from `hal_wifi` is permitted by SELinux.
4. **Kernel module**: `dfk.ko` (hand-built, no external symbols) does exactly one thing — writes 0 to
   `selinux_state.enforcing` (`0xc1d5a720 + 1`) ⇒ global **Permissive**. `initialized` is left untouched,
   so the subsystem stays functional.

Why not simply `echo 0 > /sys/fs/selinux/enforce`: the kernel's `sel_write_enforce()` also checks
`security:setenforce`, and **no domain** in this policy is granted that permission (only neverallow).
Hence it must be done from kernel context.

---

## File layout

```
一键root.cmd           Beginner entry (recommended): double-click → root_oneclick.sh (auto-retry)
一键root.bat           Forwards to 一键root.cmd
root_oneclick.sh        Orchestrator: channel retry → root shell → adb forward → verify → interactive
run.sh                  Core: verify / install / write blocks / trigger / verify
cmd.sh                  Run commands through the uid0 channel
adbroot.sh              Make adb shell root directly (patch adbd privilege-drop stubs + bind mount)
assets/
  m.img                 16MB ext4 carrier (contains /k, vendor_file label)
  dfk.ko                Kernel module (__versions + .plt/.init.plt complete)
  dfroot.apk            DirtyFrag app (signed)
  r.sh                  uid0 channel script (polls .dfr/cmd)
  blocks/               16B payload write blocks (h3 first, h1 last; p* = payload body, s* = stubs)
tools/
  rootshell.exe         root shell server (ARM, pushed to the device by the one-click script)
  rootshell_client.py   root shell client (`python tools/rootshell_client.py 5556`)
  check_rootshell.py    root shell readiness probe (used internally)
  propset.exe           property setter helper (used by adbroot.sh)
  adbd_root             adbd with privilege-drop stubs patched (used by adbroot.sh / run.sh)
```

## Troubleshooting

- **`device not found` / device disappears**: check both `adb devices` and `fastboot devices`.
  If in fastboot: read-only `fastboot getvar product/serialno/unlocked`, recover with **`fastboot reboot`**;
  do not flash or erase anything.
- **Script reports "not achieved"**: usually a missed page-cache window. Once uptime is stable, **just
  re-run** it; if it still fails, check the `dfselperm` kernel error printed by the script
  (PLT / symbol version / vermagic).
- **Black screen / abnormal behavior after running**: `adb reboot` fully restores (nothing persisted).
- **Do not** run with `FORCE=1` on other firmware: mismatched offsets can panic the kernel.

## Known limitations

- Temporary: a reboot — or even page reclamation — requires a re-run.
- Depends on this firmware's `liblog.so` (the blocks were measured against that file); re-measure
  offsets after a system OTA.
- `r.sh` runs in the `u:r:toolbox:s0` context (the post-exec domain); `uid=0` + Permissive ⇒ effectively
  unrestricted.

## Disclaimer

This project is for authorized testing and security research on **devices you own**. Do not use it on
devices you do not control.
