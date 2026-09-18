#!/bin/bash
# 2 台の DGX Spark を QSFP (ConnectX-7) で直結したリンクに固定 IP を振る。
#  - 使い方: sudo ./setup-qsfp-link.sh <ホスト番号>   (1 台目: 10, 2 台目: 11)
#  - 1 本のケーブルで 2 つのインターフェースが上がる (PCIe が 2 分割されているため)。
#    同一サブネットにすると経路が曖昧になるので、別サブネットに分ける
#  - ゲートウェイは振らない (LAN 側の既定経路を奪わない)。冪等
set -eu

HOST=${1:?usage: $0 <host-number e.g. 10|11>}
[ "$(id -u)" -eq 0 ] || { echo "root で実行すること (sudo)" >&2; exit 1; }

MTU=9000
# インターフェース:サブネット (接続名は qsfp-<インターフェース>)
LINKS="enp1s0f0np0:192.168.100 enP2p1s0f0np0:192.168.101"

for l in $LINKS; do
  dev=${l%%:*}; net=${l##*:}; con="qsfp-$dev"
  [ -e "/sys/class/net/$dev" ] || { echo "無い: $dev (スキップ)" >&2; continue; }

  # このデバイスを掴んでいる他の接続 (DHCP の自動接続など) を自動接続させない
  while IFS=: read -r name d; do
    [ "$d" = "$dev" ] && [ "$name" != "$con" ] || continue
    nmcli con mod "$name" connection.autoconnect no
    nmcli con down "$name" >/dev/null 2>&1 || true
    echo "無効化: $name ($dev)"
  done < <(nmcli -t -f NAME,DEVICE con show --active)

  nmcli con delete "$con" >/dev/null 2>&1 || true
  nmcli con add type ethernet ifname "$dev" con-name "$con" \
    ipv4.method manual ipv4.addresses "$net.$HOST/24" ipv4.never-default yes \
    ipv6.method link-local \
    802-3-ethernet.mtu "$MTU" \
    connection.autoconnect yes connection.autoconnect-priority 100 >/dev/null
  nmcli con up "$con" >/dev/null
  echo "設定: $dev -> $net.$HOST/24 mtu $MTU"
done

echo '--- 状態 ---'
for l in $LINKS; do
  dev=${l%%:*}
  [ -e "/sys/class/net/$dev" ] && ip -br -4 addr show dev "$dev" && echo "  mtu $(cat /sys/class/net/$dev/mtu)"
done
