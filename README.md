# dgx-spark-setup

DGX Spark (GB10 / Ubuntu 24.04) のセットアップ用スクリプトとメモ。

## スクリプト

| ファイル | 内容 |
|---|---|
| `install-cjk-fix.sh` | App Center (snap-store) の日本語が豆腐になるのを回避する |
| `xdg-english-dirs.sh` | XDG のユーザーディレクトリ名を英語に固定する |
| `setup-qsfp-link.sh` | 2 台の DGX Spark を QSFP 直結したリンクに固定 IP を振る |
| `install-tailscale.sh` | Tailscale を公式 apt リポジトリから入れて tailscaled を有効化する |
| `vllm-cluster-node.sh` | 2 台で vLLM を tensor parallel 2 で動かす (両機で rank 0 / 1 を起動) |

## メモ

- [NOTES.md](NOTES.md) — RDP (headless)、vLLM (2 台構成を含む)、sparkDash、Tailscale のハマりどころと対処
