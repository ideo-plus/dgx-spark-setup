#!/bin/bash
set -euo pipefail

cat > /usr/local/sbin/snap-store-cjk-font.sh <<'EOF'
#!/bin/bash
# App Center (snap-store) は Flutter 製で、同梱の libflutter_linux_gtk.so が
# fontconfig にリンクされていないため、言語別のフォントフォールバックが効かない。
# 同梱のラテン専用 Ubuntu フォント(Flutter アセット)に Noto Sans CJK JP を
# bind mount して、日本語が豆腐(□)になるのを回避する。
set -u
REG=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
BOLD=/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc
DIR=/snap/snap-store/current/bin/data/flutter_assets/packages/yaru/assets/fonts

# snapd が squashfs を mount し終えるまで待つ
for _ in $(seq 30); do [ -d "$DIR" ] && break; sleep 1; done
[ -d "$DIR" ] || { echo "not found: $DIR" >&2; exit 0; }

case "${1:-mount}" in
  mount)
    for f in Ubuntu-R.ttf Ubuntu-M.ttf Ubuntu-L.ttf; do
      mountpoint -q "$DIR/$f" || mount --bind "$REG" "$DIR/$f"
    done
    mountpoint -q "$DIR/Ubuntu-B.ttf" || mount --bind "$BOLD" "$DIR/Ubuntu-B.ttf"
    ;;
  unmount)
    for f in Ubuntu-R.ttf Ubuntu-M.ttf Ubuntu-L.ttf Ubuntu-B.ttf; do
      mountpoint -q "$DIR/$f" && umount "$DIR/$f"
    done
    ;;
esac
exit 0
EOF
chmod 755 /usr/local/sbin/snap-store-cjk-font.sh

cat > /etc/systemd/system/snap-store-cjk-font.service <<'EOF'
[Unit]
Description=Bind-mount Noto Sans CJK JP over snap-store bundled Ubuntu fonts
After=snapd.service snapd.mounts.target
Wants=snapd.mounts.target
ConditionPathExists=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/snap-store-cjk-font.sh mount
ExecStop=/usr/local/sbin/snap-store-cjk-font.sh unmount

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable snap-store-cjk-font.service
# 既に手動 mount 済みでも冪等
systemctl start snap-store-cjk-font.service
systemctl --no-pager status snap-store-cjk-font.service | head -12
echo '--- mounted sizes ---'
ls -lL /snap/snap-store/current/bin/data/flutter_assets/packages/yaru/assets/fonts
