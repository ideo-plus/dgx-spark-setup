#!/bin/bash
# XDG ユーザーディレクトリ(ダウンロード等)を英語名に統一する。
#  - sudo 不要。冪等。新規マシン・使用中マシンのどちらでも実行可
#  - 新規マシンではログイン前に実行すると日本語名が作られない
set -u

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="$CONF_DIR/user-dirs.conf"
DIRS="$CONF_DIR/user-dirs.dirs"
mkdir -p "$CONF_DIR"

# 1) ログイン時の自動ローカライズ(xdg-user-dirs-update)を無効化
if [ -f "$CONF" ] && grep -q '^[[:space:]]*enabled=' "$CONF"; then
  sed -i 's/^[[:space:]]*enabled=.*/enabled=false/' "$CONF"
else
  printf 'enabled=false\n' >> "$CONF"
fi
echo "設定: $CONF -> $(grep '^enabled=' "$CONF")"

# 2) 既存の日本語ディレクトリを英語名へ移動(中身ごと)
move_dir() {
  local src="$HOME/$1" dst="$HOME/$2"
  [ -d "$src" ] || return 0
  [ "$src" = "$dst" ] && return 0
  if [ ! -e "$dst" ]; then
    mv -v -- "$src" "$dst"
    return 0
  fi
  # 移動先が既にある場合は中身だけ移す。
  # 同名が衝突したら上書きせず ".ja-dup" を付けて退避し、日本語名は残さない
  local e base target n
  shopt -s dotglob nullglob
  for e in "$src"/*; do
    base=$(basename -- "$e")
    target="$dst/$base"
    if [ -e "$target" ]; then
      target="$dst/$base.ja-dup"; n=1
      while [ -e "$target" ]; do target="$dst/$base.ja-dup.$n"; n=$((n+1)); done
      echo "名前が衝突: $base -> $(basename -- "$target") として退避(内容は未確認、後で要確認)"
    fi
    mv -v -- "$e" "$target"
  done
  shopt -u dotglob nullglob
  if rmdir -- "$src" 2>/dev/null; then :; else echo "空にできず残置: $src" >&2; fi
}

move_dir デスクトップ   Desktop
move_dir ダウンロード   Downloads
move_dir テンプレート   Templates
move_dir 公開           Public
move_dir ドキュメント   Documents
move_dir ミュージック   Music
move_dir ピクチャ       Pictures
move_dir ビデオ         Videos

# 3) 英語ディレクトリを用意
cd "$HOME" && mkdir -p Desktop Downloads Templates Public Documents Music Pictures Videos

# 4) user-dirs.dirs を英語パスに揃える(既存ファイルは該当行だけ書き換え、他の設定は温存)
write_dirs_file() {
  cat > "$DIRS" <<'DIRSEOF'
# This file is written by xdg-user-dirs-update
# Format is XDG_xxx_DIR="$HOME/yyy", where yyy is a shell-escaped
# homedir-relative path, or XDG_xxx_DIR="/yyy", where /yyy is an
# absolute path. No other format is supported.
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_TEMPLATES_DIR="$HOME/Templates"
XDG_PUBLICSHARE_DIR="$HOME/Public"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_MUSIC_DIR="$HOME/Music"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos"
DIRSEOF
}

if [ -f "$DIRS" ]; then
  sed -i \
    -e 's|^XDG_DESKTOP_DIR=.*|XDG_DESKTOP_DIR="$HOME/Desktop"|' \
    -e 's|^XDG_DOWNLOAD_DIR=.*|XDG_DOWNLOAD_DIR="$HOME/Downloads"|' \
    -e 's|^XDG_TEMPLATES_DIR=.*|XDG_TEMPLATES_DIR="$HOME/Templates"|' \
    -e 's|^XDG_PUBLICSHARE_DIR=.*|XDG_PUBLICSHARE_DIR="$HOME/Public"|' \
    -e 's|^XDG_DOCUMENTS_DIR=.*|XDG_DOCUMENTS_DIR="$HOME/Documents"|' \
    -e 's|^XDG_MUSIC_DIR=.*|XDG_MUSIC_DIR="$HOME/Music"|' \
    -e 's|^XDG_PICTURES_DIR=.*|XDG_PICTURES_DIR="$HOME/Pictures"|' \
    -e 's|^XDG_VIDEOS_DIR=.*|XDG_VIDEOS_DIR="$HOME/Videos"|' \
    "$DIRS"
  # キーが欠けていれば補う
  for kv in DESKTOP:Desktop DOWNLOAD:Downloads TEMPLATES:Templates \
            PUBLICSHARE:Public DOCUMENTS:Documents MUSIC:Music \
            PICTURES:Pictures VIDEOS:Videos; do
    k=${kv%%:*}; v=${kv##*:}
    grep -q "^XDG_${k}_DIR=" "$DIRS" || printf 'XDG_%s_DIR="$HOME/%s"\n' "$k" "$v" >> "$DIRS"
  done
else
  write_dirs_file
fi

# 5) Files (Nautilus) サイドバーのブックマークも英語パスへ(URL エンコード済みの旧パスを置換)
BM="$CONF_DIR/gtk-3.0/bookmarks"
if [ -f "$BM" ]; then
  for kv in デスクトップ:Desktop ダウンロード:Downloads テンプレート:Templates \
            公開:Public ドキュメント:Documents ミュージック:Music \
            ピクチャ:Pictures ビデオ:Videos; do
    ja=${kv%%:*}; en=${kv##*:}
    enc=$(printf '%s' "$ja" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%\U&/g')
    # 区切りに | を使うと \| (選択) が効かなくなるので # を使う
    sed -i -e "s#file://$HOME/$enc\\([[:space:]]\\|\$\\)#file://$HOME/$en\\1#" \
           -e "s#file://$HOME/$ja\\([[:space:]]\\|\$\\)#file://$HOME/$en\\1#" "$BM"
  done
  echo "ブックマーク更新: $BM"
fi

echo '--- user-dirs.dirs ---'
grep ^XDG "$DIRS"
echo '--- 反映確認 ---'
for k in DESKTOP DOWNLOAD DOCUMENTS; do printf '%-9s %s\n' "$k" "$(xdg-user-dir "$k")"; done
