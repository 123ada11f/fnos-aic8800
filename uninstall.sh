#!/bin/bash
# 卸载 AIC8800 驱动（不删除本目录备份）
# 用法: sudo bash uninstall.sh
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "请用 sudo / root 运行"; exit 1; }
KVER="${KVER:-$(uname -r)}"
KDIR="/lib/modules/$KVER/updates/trim/aic8800"

echo "==> 1/4 停止并禁用开机切换服务"
systemctl disable --now aic8800-switch.service 2>/dev/null || true
rm -f /etc/systemd/system/aic8800-switch.service

echo "==> 2/4 移除 udev 规则 / modprobe 配置 / 切换脚本"
rm -f /lib/udev/rules.d/99-aic8800-replug.rules
rm -f /lib/udev/rules.d/99-aic8800-switch.rules
rm -f /etc/modprobe.d/aic8800.conf
rm -f /usr/local/sbin/aic8800-switch
rm -f /lib/firmware/aic8800D80

echo "==> 3/4 卸载内核模块（按依赖顺序）"
# aic8800DC_fdrv 依赖 aic_load_fw，必须先卸 fdrv
for m in aic8800DC_fdrv aic8800_fdrv aic_load_fw aic8800_bsp aic_btusb; do
  if lsmod | grep -q "^${m}\b"; then
    rmmod "$m" 2>/dev/null || echo "  (跳过 $m，仍在使用中)"
  fi
done
rm -rf "$KDIR"

echo "==> 4/4 更新依赖并重载"
depmod -a "$KVER" 2>/dev/null || true
systemctl daemon-reload
udevadm control --reload 2>/dev/null || true

echo
echo "已卸载。固件目录 /lib/firmware/aic8800 已保留（系统自带，勿删）。"
echo "重启后 USB 设备会回到 1111:1111 U盘模式。"
