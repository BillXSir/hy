# 蓝牙"僵尸 hci0"

蓝牙适配器在系统里**存在但完全不可用**：`hciconfig` 能看到 `hci0`，`bluetoothctl` 却扫不到任何设备，也连不上任何东西。

## 症状指纹

一行判真伪，记住它：

> `hciconfig` 里 `hci0` **存在**，但
> - `DOWN`
> - `BD Address: 00:00:00:00:00:00`
> - `Features: 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00`
>
> ⇒ **控制器从未初始化成功**，绝大多数是**固件没加载**。

```
hci0:	Type: Primary  Bus: USB
	BD Address: 00:00:00:00:00:00  ACL MTU: 0:0  SCO MTU: 0:0
	DOWN
	Features: 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00
```

**对照**：如果 `BD Address` 有值、只是状态 `DOWN`，那是"没上电"，不是这个问题 —— 用 `hciconfig hci0 up` 或重启 `bluetooth.service` 即可，别往下走。

## 一键操作（安全模式）

```bash
sudo ./bt-dead-hci0.sh
```

一条命令做完：采集 → 判定 → 必要时修复 → 验证 → 给下一步建议。

**安全边界**（这是"可以放心无脑跑"的前提）：

| 允许 | 禁止 |
|---|---|
| 读 sysfs / dmesg / hciconfig | 写、改、删任何**固件**文件 |
| USB 层 `unbind`/`bind` 重新枚举设备 | 重启系统 |
| 卸载**当前正绑在故障设备上**的外部模块（可逆） | 卸载内核内建驱动 |
| 重启 `bluetooth.service` | 改内核 cmdline、动 bootloader |
| 固件缺失时**只报告、不下载** | 猜一个固件塞进去 |

持久化改动必须显式 `--install`，且自动备份到 `/var/backups/bt-dead-hci0/<时间戳>/`。

### 全部模式

```bash
sudo ./bt-dead-hci0.sh --diagnose    # 纯只读
sudo ./bt-dead-hci0.sh --fix         # 只修这一次，不持久化
sudo ./bt-dead-hci0.sh --install     # 装开机自愈
sudo ./bt-dead-hci0.sh --install --blacklist rtl_btusb   # 顺带屏蔽冲突的外部模块
sudo ./bt-dead-hci0.sh --uninstall   # 回滚持久化改动
# 通用: --quiet(精简输出, 给 systemd 日志用)  --no-color
```

## 判定表

脚本给出四种 verdict：

| verdict | 含义 | 下一步 |
|---|---|---|
| `OK` | 控制器都已初始化 | 问题不在底层，转查配对 / 权限 / 应用层；若**重启后复现**则装 `--install` |
| `ZOMBIE` | 有控制器但没初始化 | 看 `fw=` 细分（下表） |
| `NO_ADAPTER` | 一个 hci 都没有 | 硬件 / 驱动未加载，本脚本不适用；查 `lsusb`、`dmesg \| grep -iE 'btusb\|btrtl'` |
| 提示「非 USB 控制器」 | 平台 / UART 蓝牙 | USB 重新枚举法无效，走芯片厂商的 UART 初始化流程 |

`ZOMBIE` 的 `fw=` 细分是分析核心：

| fw 值 | 判据 | 结论 |
|---|---|---|
| `RACE` | dmesg 里「BT 请求固件」的时刻 **早于** `VFS: Mounted root` | **开机竞速**：驱动在根文件系统挂载前就要固件。见 `case-yarbo-firmware-race.md` |
| `MISSING` | `/lib/firmware/<名字>` 真的不存在 | 固件缺失，先解决固件来源，**别怀疑硬件** |
| `MIXED` | 多控制器、部分固件缺 | 逐个确认 |
| `UNKNOWN` | 固件在位但起不来 | 固件 / 芯片不匹配、config 文件错、射频供电 |

## 修复阶梯

脚本自动按序执行，失败即停，绝不升级为破坏性操作：

1. **L1**：USB 层 `unbind` → `bind` 该设备，迫使驱动重新 probe
2. **L2**：L1 失败且设备被某个**外部模块**（非 `btusb`）占用时，卸载它再重试
3. **L3**：仍失败 → 报告并停止

修复后自动收尾：检查是否停在 `DOWN` → 需要时重启 `bluetoothd` → 仍 `DOWN` 则 `hciconfig hci0 up` → 实扫 12 秒验证射频链路。

## 持久化

`--install` 落地：

```
/usr/local/sbin/bt-dead-hci0.sh                脚本本体
/etc/systemd/system/bt-dead-hci0-fix.service   After=bluetooth.service, ExecStartPre=sleep 5
/etc/modprobe.d/blacklist-bt-conflict.conf     仅当 --blacklist 指定时生成
/var/log/bt-dead-hci0.log                      每次开机一行 verdict，排查先看它
```

服务是 `Type=oneshot`，开机跑一次就退出，日志长这样：

```
2026-11-10T07:00:38+08:00 [OK] 所有控制器均已正常初始化，无需修复
2026-11-10T07:00:38+08:00 summary verdict=OK fw=none adapters=hci0  bd=94:BA:06:FA:XX:XX
```

正常态的机器可以一直留着这个服务：它检测到健康就立刻退出，零副作用。

> `blacklist` 必须**同时**写 `install <mod> /bin/false`。只写 `blacklist` 拦不住显式 `modprobe <mod>`，也拦不住某些 udev 路径。

## 验证成功的标志

```bash
lsusb -t | grep Wireless
#   |__ Port 3: Dev 3, If 0, Class=Wireless, Driver=btusb   ← 必须是 btusb
hciconfig hci0 | head -4
#   BD Address: 94:BA:06:FA:XX:XX  ...  UP RUNNING PSCAN ISCAN INQUIRY
lsmod | grep rtl_btusb        # 应为空（厂商驱动不应存在）

# 实扫（注意：必须同一会话，BlueZ 5.6x 下未配对设备在扫描结束后会被清理）
{ echo 'scan on'; sleep 10; echo devices; echo quit; } | bluetoothctl
```

## 回滚

```bash
sudo ./bt-dead-hci0.sh --uninstall
# 或手工:
sudo systemctl disable --now bt-dead-hci0-fix.service
sudo rm -f /etc/systemd/system/bt-dead-hci0-fix.service \
           /usr/local/sbin/bt-dead-hci0.sh \
           /etc/modprobe.d/blacklist-bt-conflict.conf
sudo systemctl daemon-reload
```

被屏蔽的模块需手动 `modprobe` 恢复。

## 平台注意事项

这几条是在 Rockchip + 内核 6.1 的设备上踩出来的，其它平台先核对再用：

### 1. 驱动是内建还是模块，决定完全不同的对策

`lsmod` 里看不到 `btusb`、`/lib/modules/$(uname -r)/kernel/drivers/bluetooth/` 下也没有 `btusb.ko`
⇒ `CONFIG_BT_HCIBTUSB=y`，**内建**。此时：

- `modprobe -r btusb` → `Module btusb not found`
- `blacklist btusb` → **完全无效**，blacklist 只对可加载模块起作用
- 只能靠 USB 层重新枚举让它重新 probe

### 2. 有 initramfs 才能"治根"

```bash
grep -o 'skip_initramfs' /proc/cmdline; ls -A /boot
```

出现 `skip_initramfs` 或 `/boot` 为空 ⇒ **没有 initramfs** ⇒ 内建驱动在 `do_initcalls()` 阶段就要固件，而那时内核根本没有任何文件系统 ⇒ `-ENOENT` 结构性必然。

这种情况下"把固件塞进 initramfs"这条路不存在，只能靠开机后重新枚举。**不要在无 initramfs 的板子上折腾 initramfs hook。**

### 3. USB 设备路径每次开机都会变

`5-1.3` → `7-1.3` → `6-1.3` 是常态（多控制器枚举顺序不固定）。所以脚本一律通过
`/sys/class/bluetooth/hciN/device` 反查真实路径，**不硬编码 `X-Y.Z`**。

### 4. 厂商 out-of-tree 驱动是常见干扰源

厂商模块常由 **udev 按 modalias 自动拉起**（`alias: usb:v*p*d*dc*dsc*dp*icE0isc01ip01in*`），
抢占已被内建驱动放弃的设备，做了一次 firmware download，**却产不出可用 HCI**。

于是现象变成：`lsmod` 有模块、`hciconfig` 有设备、三个"正常"的表象叠出一个完全不工作的状态。

模块名可能与文件名不一致（例：文件 `rtl_btusb.ko`，dmesg 打印 `rtk_btusb:`）——**以 `lsmod` 第一列为准**。

## 误判清单

| 现象 | 不要下的结论 |
|---|---|
| `hciconfig` 有 `hci0` | 不代表可用 —— 看 `BD Address` 和 `Features` |
| `lsmod` 有蓝牙模块 | 不代表模块绑上了设备 —— 用 `lsusb -t` 看 `Driver=` |
| `rfkill list` 报 command not found | 不是"没被 block"，是**系统没装 rfkill** |
| `bluetoothctl devices` 为空 | 不代表扫描失败；要在**同一会话**里 `scan on` 之后立刻 `devices` |
| `scan` 扫到 0 个设备 | 先确认 `Powered: yes` 和 `UP RUNNING PSCAN ISCAN INQUIRY`，再怀疑射频 |
| 固件文件的 mtime 比开机时间新 | 不能说明是安装时间；包的 mtime 是**打包时间**，dpkg 会原样保留 |
| 厂商驱动版本号很新 | 版本新不代表能用；见过更新的构件反而专抢设备 |
