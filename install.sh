#!/bin/bash
# AIC8800 USB WiFi6 模块 (LGX WIFI6 / 88M80) — 一键安装脚本
# 适用: fnOS (Debian 12) / 内核 6.18.18.c1126-trim
# 用法: sudo bash install.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
KVER="${KVER:-$(uname -r)}"
KDIR="/lib/modules/$KVER/updates/trim/aic8800"
FWDIR="/lib/firmware/aic8800"

[ "$(id -u)" = 0 ] || { echo "请用 sudo / root 运行"; exit 1; }

# ---- 0. 前置检查 ----------------------------------------------------------
if [ ! -d "/lib/modules/$KVER" ]; then
  echo "错误: 找不到 /lib/modules/$KVER" >&2
  exit 1
fi

MOD_VERMAGIC="$(modinfo -F vermagic "$SRC/modules/aic_load_fw.ko" 2>/dev/null | awk '{print $1}')"
if [ "$MOD_VERMAGIC" != "$KVER" ]; then
  echo "警告: 模块 vermagic ($MOD_VERMAGIC) 与当前内核 ($KVER) 不一致。" >&2
  echo "      这些 .ko 是预编译的，只能在 $MOD_VERMAGIC 上加载。" >&2
  echo "      其他内核请用官方源码重新编译 (见 README「换内核」)。" >&2
  read -r -p "仍然继续? [y/N] " ans
  [ "${ans,,}" = "y" ] || exit 1
fi

echo "==> 1/5 安装内核模块 -> $KDIR"
mkdir -p "$KDIR"
install -m 644 "$SRC/modules/"*.ko "$KDIR/"
depmod -a "$KVER"

echo "==> 2/5 安装固件 -> $FWDIR/{usb,sdio}"
mkdir -p "$FWDIR/usb" "$FWDIR/sdio"
# 注意用 "dir/." 形式，保证目标目录已存在时是合并而不是嵌套成 usb/usb
cp -a "$SRC/firmware/usb/."  "$FWDIR/usb/"
cp -a "$SRC/firmware/sdio/." "$FWDIR/sdio/"
# 部分固件路径会走不带子目录的 /lib/firmware/aic8800D80，建个兼容软链
ln -sfn "$FWDIR/usb" /lib/firmware/aic8800D80 2>/dev/null || true

echo "==> 3/5 安装模式切换脚本 -> /usr/local/sbin/aic8800-switch"
install -m 755 "$SRC/tools/aic8800-switch" /usr/local/sbin/aic8800-switch

echo "==> 4/5 安装配置文件"
install -m 644 "$SRC/config/aic8800.conf"            /etc/modprobe.d/aic8800.conf
install -m 644 "$SRC/config/99-aic8800-replug.rules" /lib/udev/rules.d/99-aic8800-replug.rules
install -m 644 "$SRC/config/aic8800-switch.service"  /etc/systemd/system/aic8800-switch.service
# 清掉可能存在的旧版规则文件（早期版本用 RUN+= 直接跑，会失败）
rm -f /lib/udev/rules.d/99-aic8800-switch.rules

echo "==> 5/5 启用服务"
systemctl daemon-reload
udevadm control --reload
systemctl enable aic8800-switch.service

cat <<'EOF'

安装完成。

首次使用请重启:  sudo reboot

重启后 aic8800-switch.service 会自动完成整条链路:
  1111:1111 (U盘模式) --0xFD/0xF2--> a69c:8d80 (固件下载态) --aic_load_fw--> a69c:8d81 (WiFi+蓝牙)

不重启、立即切换:  sudo systemctl start aic8800-switch.service
验证:              lsusb | grep a69c   /   nmcli device   /   hciconfig
EOF
