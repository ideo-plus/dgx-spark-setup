#!/bin/bash
# Tailscale を公式 apt リポジトリから入れて tailscaled を有効化する。
#  - 使い方: sudo ./install-tailscale.sh [tailscale up に渡す追加オプション...]
#    例: sudo ./install-tailscale.sh --ssh
#  - ログインは表示される URL をブラウザで開いて行う。ログイン済みなら up はスキップ
#  - 冪等 (再実行するとリポジトリ定義を上書きして apt で最新化する)
set -eu

[ "$(id -u)" -eq 0 ] || { echo "root で実行すること (sudo)" >&2; exit 1; }

. /etc/os-release   # ID=ubuntu, VERSION_CODENAME=noble
BASE="https://pkgs.tailscale.com/stable/$ID"
KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg

curl -fsSL "$BASE/$VERSION_CODENAME.noarmor.gpg" -o "$KEYRING"
curl -fsSL "$BASE/$VERSION_CODENAME.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list
apt-get update -qq
apt-get install -y tailscale

systemctl enable --now tailscaled

if tailscale status >/dev/null 2>&1; then
  echo "ログイン済み (up はスキップ)"
else
  tailscale up "$@"
fi

echo '--- 状態 ---'
tailscale version | head -1
tailscale ip -4 || true
