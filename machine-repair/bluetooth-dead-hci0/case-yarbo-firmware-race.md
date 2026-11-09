# 案例：YARBO / Rockchip 上内核驱动与根文件系统抢时序，导致蓝牙固件 ENOENT

真实案例记录。设备信息已脱敏（MAC 后三段、适配器名、IP 均为占位符）。

- **平台**：YARBO 机器人，Rockchip aarch64，内核 `6.1.75`，Systemd，BlueZ `5.64`
- **硬件**：Realtek `0bda:b85b`（RTL8852BU 系列，WiFi6 + BT5.3 二合一模块的蓝牙侧）
- **症状**：`hciconfig` 有 `hci0`，但 `DOWN` + `BD Address: 00:00:00:00:00:00` + `Features` 全零；`bluetoothctl` 扫不到任何设备
- **结论**：**不是硬件问题**。内建驱动在根文件系统挂载前请求固件，必然 `-ENOENT`，且失败后不重试

---

## 1. 固件是齐全的，先排除最容易被冤枉的对象

```
/lib/firmware/rtl_bt/rtl8852bu_fw.bin        64412 bytes
/lib/firmware/rtl_bt/rtl8852bu_config.bin       14 bytes
/lib -> usr/lib                              （软链正常）
```

文件在、路径对、权限对、可读。**所以"缺固件"这个方向一开始是错的**，真正要问的是"为什么读不到"。

## 2. 决定性证据：两个时间戳

失败那次的 dmesg：

```
[ 9.209218] usbcore: registered new interface driver btusb           ← 内建驱动 initcall
[ 9.961524] Bluetooth: hci0: RTL: loading rtl_bt/rtl8852bu_fw.bin
[ 9.961574] bluetooth hci0: Direct firmware load for rtl_bt/rtl8852bu_fw.bin failed with error -2
[ 9.961588] Bluetooth: hci0: RTL: firmware file rtl_bt/rtl8852bu_fw.bin not found
[11.368332] VFS: Mounted root (ext4 filesystem) on device 179:7.        ← 根文件系统才挂载
[11.385659] Run /sbin/init as init process
[12.332089] rtk_btusb: Realtek Bluetooth USB driver ver 3.1.xxxx
[12.519394] rtl8852be 0004:41:00.0: enabling device (0000 -> 0003)
```

**蓝牙在 9.96s 要固件，根文件系统 11.37s 才挂载 —— 早读了 1.4 秒。**

同一台设备多次开机的对比：

| 开机 | `VFS: Mounted root` | 蓝牙请求固件 | 结果 |
|---|---|---|---|
| #1 | 11.37s | 9.96s | ❌ `-ENOENT`，僵尸 `hci0` |
| #2 | 9.20s | 9.65s | ✅ `fw version 0xdac834ce` |
| #3 | 9.16s | 9.65s | ✅ `fw version 0xdac834ce` |
| #4（修复后） | 9.17s | 9.64s | ✅ 原生成功，自愈服务 no-op |

⇒ 这是**真实的竞速**，不是偶发故障。输一次就坏到下次重启。

## 3. 机制：为什么是"结构性必然"

```
kernel_init_freeable()
  ├─ do_basic_setup() → do_initcalls()     ← 内建 btusb 注册、USB 设备可能此刻枚举
  │                                          此时内核没有任何文件系统
  └─ return
kernel_init()
  ├─ prepare_namespace() → mount_root()    ← VFS: Mounted root，固件才可读
  └─ init_post() → Run /sbin/init
```

本机 cmdline 含 `skip_initramfs`，`/boot` 为空目录 —— **根本没有 initramfs**。于是：

- 内建驱动第一次 probe 拿不到固件是结构性的，只是"什么时候 probe"取决于 USB 枚举速度
- `btrtl` 的 `request_firmware_direct` 返回 `-ENOENT` 后，`btusb_probe` 失败退出，**没有任何重试机制**
- 等根文件系统就绪、文件本该可读了，驱动早就放弃了这个设备

## 4. 干扰项：厂商 out-of-tree 驱动

```
/lib/modules/6.1.75/kernel/drivers/bluetooth/rtl_btusb.ko   ← 只有这个，没有 btusb.ko
lsmod: rtl_btusb  102400  0          （dmesg 里却打印 rtk_btusb:）
```

- `btusb` 是**内建**（`=y`）：`lsmod` 看不到、`modprobe -r` 报 not found、`blacklist` 完全无效
- 厂商模块在根挂载后由 **udev 按 modalias 拉起**，抢占已被放弃的设备，做了一次 firmware download，**却产不出可用 HCI**
- 于是现场呈现出三重假象：模块在、设备在、`hciconfig` 有个 `hci0` —— 三个"正常"叠出一个完全不工作的状态
- 它甚至不需要任何显式配置就会回来：`blacklist` 必须配 `install <mod> /bin/false` 才拦得住

## 5. 当时踩过的错误假设

| 曾以为 | 实际 |
|---|---|
| 固件是后来才装进去的（mtime 看着很新） | mtime 是 dpkg 保留的**打包时间**，和安装时刻无关 |
| 应该改 initramfs 把固件带上 | 本机无 initramfs（`skip_initramfs` + `/boot` 空），此路不通 |
| `blacklist btusb` 能消除竞争 | `btusb` 内建，blacklist 对内建驱动无效 |
| 模块名就是 dmesg 里打印的 `rtk_btusb` | `lsmod` 名是 `rtl_btusb`，dmesg 前缀是另一个名字，容易写错 |
| 手动 unbind/bind 修好就算解决 | 只解决当次；根因是开机时序，**每次开机都可能重演** |
| 扫描 0 个设备 = 射频坏了 | 另一次是扫描与 `bluetoothd` 重启相撞；`btmon` 抓包证明射频完全正常 |

## 6. 最终方案

开机后重新枚举该 USB 设备，让内建 `btusb` 再 probe 一次 —— 那时根文件系统早已就绪，固件必然读得到。

```
/usr/local/sbin/bt-dead-hci0.sh                通用脚本（按 sysfs 反查路径，不硬编码）
/etc/systemd/system/bt-dead-hci0-fix.service   After=bluetooth.service, ExecStartPre=sleep 5
/etc/modprobe.d/blacklist-bt-conflict.conf     blacklist rtl_btusb + install rtl_btusb /bin/false
/var/log/bt-dead-hci0.log                      每次开机一行 verdict
```

两条路径都实测通过：

**输了竞速时**（就地手工验证）

```
usb device: 5-1.3
hci0 BD=00:00:00:00:00:00
re-probe attempt 1: 5-1.3
SUCCESS: hci0 BD=94:BA:06:FA:XX:XX
```

**赢了竞速时**（服务自动 no-op，不干扰正常路径）

```
[OK] 所有控制器均已正常初始化，无需修复
summary verdict=OK fw=none adapters=hci0  bd=94:BA:06:FA:XX:XX
```

修复后的开机日志：

```
[ 9.172031] VFS: Mounted root
[10.037964] Bluetooth: hci0: RTL: fw version 0xdac834ce
07:00:38   [OK] 所有控制器均已正常初始化，无需修复
```

## 7. 顺带记住的环境事实

- **USB 设备路径每次开机都变**：`5-1.3` / `7-1.3` / `6-1.3`（多控制器枚举顺序不固定）。硬编码路径的脚本换口就失效。
- **`bluetoothctl devices` 单开会话可能为空**：BlueZ 5.64 下未配对设备在扫描结束后会被清理，必须用
  `{ echo 'scan on'; sleep 10; echo devices; echo quit; } | bluetoothctl` 在同一会话里查。
- **开机约 34s 时 `bluetoothd` 会被设备厂商自己的初始化流程显式重启一次**（`NRestarts=0`，干净的 stop/start），属正常；`AutoEnable=true` 会自动把适配器拉起来。
- 该机型把蓝牙配成**音频角色**（`Class 0x6c0000`，适配器名 `Yarbo Music XXXXXXX`），由厂商应用写入，与本次故障无关。
