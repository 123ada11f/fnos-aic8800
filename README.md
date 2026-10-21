# fnOS aic8800 — AIC8800 USB WiFi6 模块驱动包（LGX WIFI6 / 88M80）

让 **AIC8800D80** USB WiFi6 + 蓝牙模块在 **fnOS（Debian 12，内核 6.18.18.c1126-trim）** 上正常工作的完整方案。

本仓库包含内核模块、固件、以及最关键的**模式切换脚本**——因为这块模块在整机断电后会伪装成一个只读 U 盘，不切换就永远不会出现 `wlan` 接口。

---

## 1. 这块卡为什么特殊

绝大多数 USB WiFi 网卡插上就能用，这块不行。

| 阶段 | USB ID | 表现 |
|---|---|---|
| 出厂 / 整机断电后 | `1111:1111` | **伪装成 4MB 只读 FAT U 盘**，卷标 `WIFI6`，里面只有一个 `Wifi6_install.exe` |
| 发送切换命令后 | `a69c:8d80` | 固件下载态，等主机灌固件 |
| 固件加载完成 | `a69c:8d81` | 真正的 WiFi + 蓝牙，出现 `wlan0` / `hci0` |

所以问题从来不是「驱动没装」——而是**设备根本没进入 WiFi 模式**，此时任何驱动都匹配不上（`1111:1111` 不在任何 AIC 驱动的 ID 表里）。

### 怎么切换：0xFD 厂商 SCSI 命令

逆向官方 Windows 安装包里的 `Usb_Driver.dll`（`Set_CS1_0` / `GetHippo` 两个导出函数）得到：

```
CDB: 16 字节，byte0 = 0xFD，byte15 = 子命令，其余全 0
  子命令 0xF3  → 读设备信息，返回 "88M80\0DISK"
  子命令 0xF2  → 执行切换，需要额外 16 字节全零 data-out 载荷
```

发完 `0xF2`，设备立即断开、以 `a69c:8d80` 重新枚举，内核 `aic_load_fw` 自动灌固件，然后变成 `a69c:8d81`。

> **为什么是 byte15 而不是 byte11**：早期逆向把栈偏移算错了（`0x2b - 0x1c` 之差是 15）。按 byte11 发命令完全没反应，这是一个很容易踩的坑。

### 切换不持久

整机断电 / 重启后，设备**回到 `1111:1111` U 盘模式**。

- 仅拔插 USB 线或 USB 端口断电：不会复位，仍是 `a69c:8d81`
- 整机重启 / 完全断电：复位回 `1111:1111`

所以必须开机自动重发切换命令 —— 这就是 `aic8800-switch.service` 存在的唯一理由。

---

## 2. 目录结构

| 路径 | 内容 | 安装到 |
|---|---|---|
| `modules/` | 5 个预编译内核模块（vermagic `6.18.18.c1126-trim`） | `/lib/modules/<内核>/updates/trim/aic8800/` |
| `firmware/usb/` | USB 版固件 84 个（WiFi 必需） | `/lib/firmware/aic8800/usb/` |
| `firmware/sdio/` | SDIO 版固件 73 个（本模块用不到，备用） | `/lib/firmware/aic8800/sdio/` |
| `tools/aic8800-switch` | 模式切换脚本（**核心**） | `/usr/local/sbin/aic8800-switch` |
| `config/aic8800-switch.service` | 开机 oneshot 服务 | `/etc/systemd/system/` |
| `config/99-aic8800-replug.rules` | 热插拔触发 udev 规则 | `/lib/udev/rules.d/` |
| `config/aic8800.conf` | `blacklist aic_btusb`（蓝牙改用内核 btusb） | `/etc/modprobe.d/` |
| `install.sh` / `uninstall.sh` | 一键安装 / 卸载 | — |

内核模块清单：

| 模块 | version | 作用 |
|---|---|---|
| `aic_load_fw.ko` | 1.0 | 下载固件到芯片（ROM 下载态 → 运行态） |
| `aic8800DC_fdrv.ko` | 6.4.3.0 | WiFi 主驱动（cfg80211），**本机实际使用的是这个** |
| `aic8800_fdrv.ko` | 6.4.3.0 | WiFi 主驱动（SDIO/其他变体） |
| `aic8800_bsp.ko` | 1.0 | 板级支持（本机未加载） |
| `aic_btusb.ko` | 2.1.0 | 厂商蓝牙驱动（**本机不可用，需 blacklist**，见下） |

---

## 3. 安装

```bash
git clone <本仓库地址>
cd fnos-aic8800
sudo bash install.sh
sudo reboot
```

重启后验证：

```bash
lsusb | grep a69c          # 期望: a69c:8d81 AICSemi AIC 8800D80
nmcli device               # 期望: wlx<MAC>  wifi  connected
hciconfig                  # 期望: hci0  UP RUNNING
```

不重启、立即切换：

```bash
sudo systemctl start aic8800-switch.service
```

---

## 4. 蓝牙：为什么要 blacklist 厂商驱动

这是本仓库第二个反直觉的地方。

`aic_btusb.ko`（厂商蓝牙驱动）会 probe 并占住 `1-4:1.0` / `1-4:1.1` 两个 HCI 接口，
但**从不注册 `hci` 设备**。dmesg 里表现为两行紧挨着、中间什么都没有：

```
aic_btusb: btusb_probe: download begining...
aic_btusb: btusb_probe: download ending...
```

原因：该模块只为 **8800d80n**（D80N 变体）和 **8800dc** 准备了蓝牙固件名，
没有非 N 的 8800d80。而 `/lib/firmware/aic8800/usb/` 里也确实没有
`fmacfw_btusb_8800d80_u02.bin`。结果固件下载被静默跳过，`hci0` 注册失败，
`/sys/class/bluetooth/` 变空。

**解法**：把这两个接口交给内核通用 `btusb` 驱动。

```bash
# /etc/modprobe.d/aic8800.conf
blacklist aic_btusb
```

之后 `hci0` 正常出现，BD 地址 = WiFi MAC + 1（本机 `<MAC>` → `<MAC+1>`），
BLE 扫描、配对均正常。

---

## 5. 常见问题

**`lsusb` 还是 `1111:1111`？**
```bash
sudo systemctl start aic8800-switch.service
```
若脚本报找不到 sg 节点，把 USB 拔插一次再试；若报
`switch command sent, but the dongle did not re-enumerate`，整机断电重启（不是拔线）。

**WiFi 接口名**
`wlx<MAC>`（`wlx` + MAC）。NetworkManager 正常管理，与其他 WiFi 网卡无差别。

**蓝牙没有 `hci0`**
确认 `aic_btusb` 已被 blacklist：
```bash
grep blacklist /etc/modprobe.d/aic8800.conf   # 应有 blacklist aic_btusb
lsmod | grep aic_btusb                        # 应无输出
```

**换内核后驱动失效**
`modules/` 里的 `.ko` 与内核版本绑定（`vermagic: 6.18.18.c1126-trim`）。
换内核后需要用新内核头文件重新编译：官方源码在
[AIC-AMD/aic8800](https://github.com/AIC-AMD/aic8800)
（`aic8800_linux_drvier` 分支，`CONFIG_AIC_LOADFW_SUPPORT=m CONFIG_AIC8800_WLAN_SUPPORT=m`）。
`install.sh` 会检测 vermagic 不一致并警告。

**fnOS 升级覆盖了 `/lib/modules` 或 `/lib/firmware`**
重跑 `sudo bash install.sh` 即可。

**固件盘（4MB U 盘）挂载着**
切换成功后设备重枚举，原来的 `/dev/sdb` 会消失，`/vol00/WIFI6` 自动卸载，属正常现象。

---

## 6. 排查时试过但**无效**的方法（省得你重复劳动）

以下全部实测无效，切换只能靠 `0xFD/0xF2`：

- `usb_modeswitch -K` / `-M`（configPack 里没有 `1111:*` 条目）
- SCSI `START STOP UNIT`（`eject`, LoEj=1）—— 只让容量变 0，不改 ID
- SCSI `ALLOW MEDIUM REMOVAL`、`TEST UNIT READY`、`MODE SENSE`
- SCSI `BUS DEVICE RESET`、USB `USBDEVFS_RESET`(0x5514)
- xHCI 端口断电重枚举（`usb1-port4/disable` 1→0）
- `echo 0/1 > .../authorized` 重授权
- 解绑 `usb-storage` 后重新枚举
- EP0 厂商请求：`0x40/0xA0`、`0x40/0xFD`、`0xC0/0xFD` 全 STALL
- EP0 全量扫描 2048 种组合（4 种 bmRequestType × 256 bRequest）—— **全部 EPROTO**
- bulk 端点裸发 `0xFD` 包 —— 直接把端点打死（EPIPE / timeout）
- 给 `aic_load_fw.ko` 打二进制补丁改 ID 表 + 接口 class 校验
  —— probe 能过了，但固件上传 `bin upload fail: err:-32`，因为存储固件不跑 AIC 下载协议
- `new_id` / 手工 `bind` —— ID 表没有 `1111:1111`，必然失败

**核心教训**：设备在存储态对 EP0 任何厂商请求一律 STALL，唯一入口就是那条
SCSI `0xFD` 命令。别在 USB 层找。

---

## 7. 兼容性

- 实测环境：fnOS（Debian 12 bookworm），内核 `6.18.18.c1126-trim`，x86_64
- 设备：`LGX WIFI6` / `88M80`，芯片 AIC8800D80
- 其他 fnOS 内核版本需自行重新编译模块（见上）
- 其他 AIC8800 变体（8800d80n / 8800dc / 8800d80x2）的 ID 表不同，
  本仓库切到 `a69c:8d81` 的路径只对 D80 验证过

## 8. 授权

- `modules/` 下的内核模块均为 **GPL**（`modinfo` license 字段确认），
  由 AIC 官方源码编译，遵循 GPL-2.0。
- `firmware/` 下为 AIC 官方固件二进制，版权归 AICSemi 所有，
  此处仅为便于在自己设备上恢复而留存。如需商用请向 AICSemi 取得授权。
- 本仓库的脚本与文档（`install.sh`、`uninstall.sh`、`tools/`、`config/`、本 README）
  以 MIT 授权。
