# DGX Spark セットアップメモ

ハマりどころと、その原因・対処の記録。手順そのものより「なぜそうしたか」を残す。

対象機は 2 台。ホスト名は DGX OS の初期値 (シリアル由来) のまま使っている。

| # | ホスト名 | LAN (`enP7s7`) | QSFP 直結 (`enp1s0f0np0` / `enP2p1s0f0np0`) | Tailscale |
|---|---|---|---|---|
| 1 | `spark-153d` | 10.0.1.60 | 192.168.100.10 / 192.168.101.10 | 100.109.104.27 |
| 2 | `spark-5083` | 10.0.1.61 | 192.168.100.11 / 192.168.101.11 | 100.95.207.79 |

共通: GB10 (Grace + Blackwell, aarch64) / Ubuntu 24.04 (DGX OS) /
カーネル `7.0.0-1019-nvidia` / CUDA 13.0 / compute capability **12.1 (sm_121)** /
ユニファイドメモリ 128GB。

物理モニタは接続していない (headless)。画面も起動しない (`multi-user.target`)。

---

## リモートデスクトップ (RDP)

> **2026-09-18 に両機とも RDP をやめ、画面なし (`multi-user.target`) にした。**
> spark-153d で RDP 用の Xorg が引き金になって GPU が `Xid 119 (GSP Timeout)` で止まり、
> 再起動まで CUDA が使えなくなったため (「GPU が死んでいても vLLM はコンテナ起動までは進む」参照)。
> 2 台構成の推論ではメモリも GPU も推論に回したい。以下は戻すときのための記録。
>
> ```bash
> # やめたときの手順
> sudo grdctl --system rdp disable
> sudo systemctl disable --now gnome-remote-desktop.service
> sudo systemctl set-default multi-user.target && sudo systemctl isolate multi-user.target
> # 戻す
> sudo systemctl set-default graphical.target && sudo grdctl --system rdp enable
> sudo systemctl enable --now gnome-remote-desktop.service
> ```

### 画面共有ではなくリモートログインを使う

GNOME の「画面共有 (Desktop Sharing)」は `screen-share-mode = mirror-primary`、
つまりプライマリ画面のミラーリングで動く。**headless だとミラー元が存在しない**ため、
認証は通るのに接続直後に切断される。ログにはこう出る。

```
Failed to record monitor: GDBus.Error:org.freedesktop.DBus.Error.Failed: Unknown monitor
→ ERRINFO_RPC_INITIATED_DISCONNECT
```

使えるのは「リモートログイン」のほう。システム daemon が仮想セッションを新規に作るので
物理モニタが要らない。設定は `grdctl --system`。

```bash
sudo mkdir -p /etc/gnome-remote-desktop
sudo openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=$(hostname)" \
  -out /etc/gnome-remote-desktop/rdp-tls.crt \
  -keyout /etc/gnome-remote-desktop/rdp-tls.key
sudo chown gnome-remote-desktop:gnome-remote-desktop /etc/gnome-remote-desktop/rdp-tls.*
sudo chmod 644 /etc/gnome-remote-desktop/rdp-tls.crt
sudo chmod 600 /etc/gnome-remote-desktop/rdp-tls.key

sudo grdctl --system rdp set-tls-cert /etc/gnome-remote-desktop/rdp-tls.crt
sudo grdctl --system rdp set-tls-key  /etc/gnome-remote-desktop/rdp-tls.key
sudo grdctl --system rdp set-credentials <user> <password>   # 実際のアカウント資格情報
sudo grdctl --system rdp enable

grdctl rdp disable          # ユーザー側の画面共有を止めて 3389 を解放する
sudo systemctl restart gnome-remote-desktop.service
```

`set-credentials` は必須。設定しないと `[RDP] Credentials are not set, denying client` で
拒否され、クライアントには `0x204` としか出ない。

GPU アクセス権も要る。`/dev/dri/card0` は `root:video`、`renderD128` は `root:render` の
0660 なので、daemon 用ユーザーを両グループに入れる。systemd はサービス起動時に補助グループを
解決し直すため、リブートは不要。

```bash
sudo usermod -aG video,render gnome-remote-desktop
sudo systemctl restart gnome-remote-desktop.service
```

### クライアント側: `.rdp` に `use redirection server name:i:1` が必須

リモートログインは 2 段構えで動く。

```
クライアント ──→ システム daemon (認証)
             ←── サーバーリダイレクト
             ──→ handover daemon (実セッション)
```

macOS の Windows App は **GUI 設定のみだとこのリダイレクトに追従しない**。
該当の設定項目が GUI に存在しないため、`.rdp` ファイル経由でしか渡せない。
これが無いと、認証は通るのにリダイレクト送出の直後に切れる。

```
full address:s:<host>:3389
username:s:<user>
use redirection server name:i:1
authentication level:i:2
```

保存済みの接続一覧からではなく、この `.rdp` ファイルから接続すること。

サーバー側ログで成功時にはこう出る。

```
[RDP] Sending server redirection
Started gnome-remote-desktop-handover.service
[RDP] Initialization of CUDA was successful      ← H.264 エンコードが GPU 支援
[RDP.RDPGFX] ... H264 (AVC444): true
```

### ログアウトすると待ち受けが復活しない

リモートセッションから**ログアウト**すると `RDP server stopped` となり、システム daemon は
プロセスとして生きたまま 3389 を手放す。この状態から

```bash
sudo systemctl restart gnome-remote-desktop.service   # これでは戻らない
```

では復旧しない (daemon は起動するが `RDP server started` が出ない)。待ち受けは GDM と
協調して張られるため、**GDM ごと立て直す**必要がある。

```bash
sudo systemctl restart gdm
```

運用上は、セッション終了時にログアウトせず**クライアント側で切断**するのが正解。

### 補足

- `Init TPM credentials failed ... using GKeyFile as fallback` は警告。TPM 非搭載のため
  鍵をファイル保存にフォールバックしているだけで、資格情報は再起動をまたいで保持される。
- `renderD128` の Vulkan エラー (`VK_ERROR_INCOMPATIBLE_DRIVER`) は Mesa の freedreno が
  NVIDIA デバイスを掴もうとして失敗しているもの。CUDA 初期化は成功しているので実害なし。

---

## vLLM

### upstream の安定版イメージは使えない

`vllm/vllm-openai:latest` は **GB10 (sm_121) 非対応**。使えるのは以下。

| イメージ | 備考 |
|---|---|
| `nvcr.io/nvidia/vllm:26.08-py3` | NGC 公式。arm64 マニフェストあり。**匿名 pull 可** (NGC ログイン不要)。25.5GB |
| `vllm/vllm-openai:cu130-nightly` | upstream の CUDA 13 ナイトリー |
| `ghcr.io/timothystewart6/vllm-gb10` | コミュニティ製、sm_121a 向けビルド |

NGC の利用可能タグは匿名トークンで列挙できる。

```bash
TOKEN=$(curl -s "https://nvcr.io/proxy_auth?scope=repository:nvidia/vllm:pull" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOKEN" https://nvcr.io/v2/nvidia/vllm/tags/list
```

### 起動

```bash
docker run --rm --gpus all --ipc=host -p 8000:8000 \
  -v "$HOME/.local/share/huggingface:/root/.cache/huggingface" \
  nvcr.io/nvidia/vllm:26.08-py3 \
  vllm serve <model> --host 0.0.0.0 --gpu-memory-utilization 0.2
```

`--ipc=host` は必須。vLLM はワーカー間で共有メモリを使うため、Docker 既定の 64MB では落ちる。

### `--gpu-memory-utilization` はユニファイドメモリ全体に対する比率

ここが DGX Spark 固有の罠。ディスクリート GPU なら「VRAM をどれだけ使うか」だが、
GB10 は CPU と GPU が 128GB を共有しているので、**確保分がそのままシステム RAM を食う**。

Qwen3-0.6B に `0.6` を指定した実測値:

```
Free memory on device (114.54/121.69 GiB) on startup.
Desired GPU memory utilization is (0.6, 73.01 GiB).
Actual usage is 3.35 GiB for consumed memory (weights + non-torch)
Current kv cache memory in use is 69.4 GiB      ← 0.6B のモデルに 69GB
GPU KV cache size: 649,728 tokens
```

モデル本体は 3.35GB しか使っていないのに KV キャッシュが 69GB。小さいモデルでは `0.1`〜`0.2`
に下げるか、`--kv-cache-memory` でバイト数を直接指定する。ディスクリート GPU の感覚で `0.9`
にしないこと。

### 動作実績 (2026-09-18, Qwen/Qwen3-0.6B)

vLLM 0.27.1 / FLASH_ATTN (FlashAttention 2) / FlashInfer サンプリング /
torch.compile 14 秒 / CUDA グラフ捕捉成功 (PIECEWISE 51 + FULL 35) / エンジン初期化 92 秒。

sm_121a が認識されていることは FlashInfer のキャッシュパスで確認できる。

```
.../flashinfer_autotune_cache/0.6.17/121a/...
                                     ^^^^
```

### 2 台構成 (tensor parallel 2)

`vllm-cluster-node.sh` を両機で実行する (rank 0 = spark-153d、rank 1 = spark-5083)。

```bash
./vllm-cluster-node.sh 0 <model>   # spark-153d。API は :8000
./vllm-cluster-node.sh 1 <model>   # spark-5083。--headless で API は立てない
```

- **Ray は使わない。** NGC の `vllm:26.08-py3` には Ray が入っていない。代わりに vLLM 組み込みの
  複数ノード (`--nnodes 2 --node-rank N --master-addr 192.168.100.10`、既定の mp バックエンド) を使う。
- **通信を直結リンクに固定する。** 以下を外すと LAN (10.0.1.x) 側に流れる。
  `VLLM_HOST_IP=192.168.100.1x` / `NCCL_SOCKET_IFNAME` と `GLOO_SOCKET_IFNAME` = `enp1s0f0np0` /
  `NCCL_IB_HCA=rocep1s0f0`。コンテナには `--network host --device /dev/infiniband --cap-add IPC_LOCK
  --ulimit memlock=-1` を付ける。
- RoCE で通っているかは `NCCL_DEBUG=INFO` のログで見る。`NET/IB : No device found.` が 1 行出るが、
  その後に次が出ていれば OK。`NET/Socket` になっていたら TCP に落ちている。

  ```
  NCCL INFO NET/IB : Using [0]rocep1s0f0:1/RoCE [RO]; OOB enp1s0f0np0:192.168.100.10<0>
  NCCL INFO Channel 00/0 : 0[0] -> 1[0] [send] via NET/IB/0
  ```

- 直結リンクの RDMA 帯域は `ib_write_bw` で 1 本あたり約 112 Gb/s (2026-09-18 実測)。
  今は 1 本 (`rocep1s0f0`) しか使っていない。
- イメージとモデルは直結リンク経由で 2 台目に送ると速い (25.5GB のイメージで約 4 分)。

  ```bash
  docker save nvcr.io/nvidia/vllm:26.08-py3 | ssh 192.168.100.11 docker load
  rsync -a ~/.local/share/huggingface/hub 192.168.100.11:.local/share/huggingface/
  ```

動作実績 (2026-09-18): Qwen/Qwen3-0.6B を TP=2 で起動し、spark-153d:8000 で応答を確認。

### Codex CLI から使う

今のモデルは `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` (31GB、1 ノード 14.8GiB、KV 55 万トークン)。
0.6B ではツールを選べず実用にならなかった。

```bash
M=Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8
GPU_UTIL=0.4 API_ARGS="--enable-auto-tool-choice --tool-call-parser qwen3_coder" \
  ./vllm-cluster-node.sh 0 $M   # spark-153d
GPU_UTIL=0.4 ./vllm-cluster-node.sh 1 $M     # spark-5083
```

API サーバー専用のオプションを headless の rank 1 に渡すと `unrecognized arguments` で落ち、
rank 0 は待ち続ける。だから `API_ARGS` に分けている。

Codex 0.155 の `-p <name>` は `~/.codex/<name>.config.toml` を基本設定に重ねる方式。

```toml
# ~/.codex/spark.config.toml   → codex -p spark
model_provider = "spark"
model = "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8"
model_context_window = 262144   # 無いと "Model metadata ... not found" の警告

[model_providers.spark]
name = "DGX Spark vLLM"
base_url = "http://spark-153d:8000/v1"
wire_api = "responses"

[mcp_servers.searxng]
command = "npx"
args = ["-y", "mcp-searxng@2.3.0"]
startup_timeout_sec = 60
env = { SEARXNG_URL = "http://spark-153d:8080", SEARXNG_LITE_TOOLS = "true", SEARXNG_MAX_RESULTS = "5" }

[mcp_servers.searxng.tools.searxng_web_search]
approval_mode = "approve"
[mcp_servers.searxng.tools.web_url_read]
approval_mode = "approve"
```

### Claude Code から使う

vLLM 0.27 は Anthropic 互換の `/v1/messages` を持つ (`vllm/entrypoints/anthropic`)。ストリーミングと
`tool_use`、`count_tokens` も通る (2026-09-18、Qwen3-Coder-30B で確認)。環境変数で接続先を差し替える。

`bin/claude-spark` (シェルスクリプト) を使う。Mac で `PATH` に通す (例: `ln -s ~/dgx-spark-setup/bin/claude-spark ~/bin/`)。

```bash
claude-spark                                  # spark-153d の 8000 → 8001 の順に試し、応答した方につなぐ
claude-spark -c                               # claude の引数はそのまま渡る
SPARK_URL=http://spark-153d:8001 claude-spark # 接続先を固定する
SPARK_MODEL=glm-5.3-flash claude-spark        # モデル名を固定する (未指定なら /v1/models の最初の id)
```

- `/v1/models` の応答は 1 行の JSON で、後ろに permission の `"id"` (`modelperm-…`) も並ぶ。
  最後の `"id"` を拾うと、このモデルではない ID になる。最初の `"id"` がモデル名。

- haiku 相当の補助的な呼び出し (タイトル生成、WebFetch の要約) も同じモデルに向ける。そうしないと、存在しないモデル名で 404 になる。
- `WebSearch` はサーバー側で実行されるツールなので、vLLM では動かない (下記)。無効化し、代わりに SearXNG の MCP を使う。

```json
// ~/.claude/spark-mcp.json
{"mcpServers":{"searxng":{"command":"npx","args":["-y","mcp-searxng@2.3.0"],
  "env":{"SEARXNG_URL":"http://spark-153d:8080","SEARXNG_LITE_TOOLS":"true","SEARXNG_MAX_RESULTS":"5"}}}}
```

### Web 検索は MCP + SearXNG で行う

Codex の `--search` (Claude Code の WebSearch も同じ) は **API サーバー側で実行されるツール**。
vLLM はこれを実行せず、しかもエラーにもせず黙って無視する。モデルは検索したふりをして答えを作る。
なので検索はハーネス側で動く MCP サーバーに任せる。

```
Codex ──MCP──→ mcp-searxng ──HTTP──→ SearXNG (spark-153d:8080) ──→ Google / Bing など
```

- SearXNG は spark-153d の `~/searxng` (compose、`restart: always`)。API キー不要。
  MCP から JSON で叩くので `settings.yml` の `search.formats` に `json` を足す。`limiter: false`。
  ポート 8080 は LAN / tailnet 向け。ルーターで外に開けないこと。
- `mcp-searxng` は検索 (`searxng_web_search`) とページ読み取り (`web_url_read`) の両方を持つ。
  `SEARXNG_LITE_TOOLS=true` で検索の引数がクエリだけになり、小さいモデルでも扱いやすい。
- **MCP ツールは呼ぶたびに承認が要る。** `codex exec` (承認ポリシー never) では
  `MCP tool call requires approval, but approval policy is never` で失敗し、モデルは
  「検索できない」と答えるだけになる。読み取り専用の 2 つは `approval_mode = "approve"` にした。
- 動作実績 (2026-09-18): 「DGX Spark のメモリ容量」を検索し、出典 4 件付きで 128GB と回答。

### GPU が死んでいても vLLM はコンテナ起動までは進む

spark-153d で、ワーカーが `RuntimeError: No CUDA GPUs are available` で落ち続けた。原因は
vLLM ではなく GPU 自体で、起動前から `Xid 119 (GSP Timeout)` で止まっていた (引き金は RDP の Xorg)。
以後カーネルログに `gpuHandleSanityCheckRegReadError ... 0xbadf5600` が大量に出て、`cuInit` が
100 を返す。再起動で戻った。

紛らわしい点が 2 つある。

- `torch.cuda.device_count()` は NVML 経由なので GPU が死んでいても `1` を返す。
  判定は `cuInit` で行う (`vllm-cluster-node.sh` は起動前にこれを確かめる)。
- NGC イメージの起動バナーに `CUDA failed to initialize ... (error 100)` と出る。正常な機では
  代わりに `CUDA Forward Compatibility mode ENABLED` と出る。`--entrypoint` を差し替えて
  試すとこのバナーを見逃す。

### ollama との併用

ollama とはメモリを取り合うので同時に動かさない。vLLM を使う間は ollama を止める。

---

## モデルの切り替え (`spark-model.sh`)

各レシピの起動コマンドは長いので、`spark-model.sh` にまとめた。いま動いているもの (DeepSeek、Qwen3.8、
`vllm-cluster-node.sh` の `vllm-node`) を止めてから起動する。API はどれもポート 8000。

```bash
ssh spark-153d dgx-spark-setup/spark-model.sh qwen       # Qwen3.8-Flash-Next (qwen3.8-flash-next)
ssh spark-153d dgx-spark-setup/spark-model.sh deepseek   # DeepSeek-V4.1-Flash (DeepSeek-v4.1-Flash-EXL3)
ssh spark-153d dgx-spark-setup/spark-model.sh status
ssh spark-153d -t dgx-spark-setup/spark-model.sh logs
ssh spark-153d dgx-spark-setup/spark-model.sh stop
```

---

## DeepSeek-V4.1-Flash (EXL3 2.9bpw, TP=2)

レシピは <https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-EXL3-2x-DGX-Sparks> (`~/DeepSeek-v4.1-Flash-EXL3-2x-DGX-Sparks`、
spark-153d)。重みは 1 ノードあたり約 99.5GiB で、起動には `MemAvailable` が重み + 12GiB 必要 (`check_memory_headroom`)。

### 重みのダウンロード

- `download.sh` は `model/` が無いと何も出さずに終わる。`set -o pipefail` の下で `find` が失敗するため。
  先に `mkdir -p model engram-src` しておく。
- spark-153d には `hf` コマンドが無いので、`.hfshim/hf` (uvx 経由のラッパー) を `PATH` の先頭に置いて実行する。
- xet は受信したチャンクをまとめて書き出す。`du` を数十秒おきに測っても速度はわからない。
  完了したファイル数 (`ls model/*.safetensors | wc -l`、39 で完了) で見る。
- 実績 (2026-09-18): HF_TOKEN なしで平均約 37MiB/s。EXL3 197GiB が 17:21〜18:50、Engram 190GiB
  (シャード 47/48 が各 約 95GiB) が 18:50〜20:18。途中で `Connection reset` が出るが、xet が再試行するので止まらない。
- 落ちたときや止まったときのために `watch-download.sh` (見張り、未コミットのローカルファイル) を `setsid` で動かした。
  `download-watch.log` に状態を書く。`DONE` で終了。
- **Engram に `config.json` が要るのに、`download.sh` はこれを取らない** (取るのはシャード 47/48 と index だけ)。
  起動すると、重みの読み込みで `FileNotFoundError: '/engram-src/config.json'` になる。元のリポジトリから取って、
  `engram-src/`、head の `~/.cache/vllm-dsv41-flash-exl3/engram-src/`、worker の engram-src の 3 か所に置く。

  ```bash
  hf download deepseek-ai/DeepSeek-V4.1-Flash config.json --local-dir engram-src
  ```
- 重みの予算は `scripts/weight_budget.py --model model --tp 2` で 1 ランクあたり 99.48GiB (routed experts が 91.29GiB)。

### `.env` で直すところ

作者の環境 (`10.0.0.x`、`enp1s0f1np1`) の値になっているので、この 2 台に合わせる。

| 変数 | 値 |
|---|---|
| `HEAD_IP` / `WORKER_IP` | `192.168.100.10` / `192.168.100.11` |
| `HEAD_CX7_IF` / `WORKER_CX7_IF` | どちらも `enp1s0f0np0` |
| `HEAD_CX7_IB` / `WORKER_CX7_IB` | どちらも `rocep1s0f0` |
| `NCCL_IB_GID_INDEX` | `5` (2 台とも)。既定の `3` は `fe80::` のリンクローカル |
| `WORKER_USER` | `j5ik2o` |
| `PORT` | `8000` (既定は 8888)。sparkDash と Claude Code の接続先をそのまま使える |
| `NFS_CLIENTS` | `192.168.100.11` (既定は `/24` 全体) |

GID は `/sys/class/infiniband/rocep1s0f0/ports/1/gids/N` と `gid_attrs/types/N` で見る。
`::ffff:192.168.100.1x` かつ `RoCE v2` の行を選ぶ (2 台とも index 5)。

### 起動の実績 (2026-09-18)

```bash
SKIP_BUILD=1 SKIP_PULL=1 setsid -f ./start.sh > logs/start.out 2>&1 < /dev/null   # WEIGHT_SYNC=rsync
```

- コンテナの起動から「is UP」まで約 6 分。重みの読み込みに約 5 分、エンジンの初期化 (KV 確保、ウォームアップ) に 75 秒。
- 起動後の空きメモリ (`MemAvailable`) は head 4GiB、worker 6GiB。この状態で Claude Code を Spark 上で動かすのは避ける。
- 生成速度: 1 リクエスト、思考なしで 600 トークンを 16.9 秒 (約 35 tok/s、DSpark k=3)。
  サンプル数は 1 (日本語で LRU キャッシュの実装と解説を頼んだもの、`max_tokens` 600)。
  別に、Claude Code で使っていた 15 分間のサーバーログ (10 秒ごとの集計、1 本だけ処理していた 21 区間) では、
  中央値 32 tok/s、最大 47 tok/s。
- `/v1/messages` で `thinking` と `tool_use` のブロックが返る。Claude Code から使える。
- 起動後のウォームアップで `sampler-cache postcondition UNMET` という警告が出る。止まる問題ではない (nonfatal)。
  まだコンパイルされていない top-k/top-p の組み合わせが来たとき、その場で JIT コンパイルするので、初回だけ遅くなる。

### 思考 (thinking) をサーバー側でオフにする

DeepSeek のチャットテンプレートは、既定で思考がオンになっている。Claude Code は 1 つの作業で何往復もやり取りし、
そのたびに数百トークンの思考を出すので、とても遅い (約 30 tok/s)。vLLM の `/v1/messages` は、リクエストの
`thinking` の指定を無視する。そのため、クライアント側では止められない。サーバーの既定値で止める。

```bash
# .env
EXTRA_ARGS='--default-chat-template-kwargs {"enable_thinking":false}'   # JSON にスペースを入れない (空白で分割される)
```

`EXTRA_ARGS` は headless の worker にも渡るが、このオプションは受け付けられて起動する。
ツール呼び出し 1 往復が約 1.7 秒になった。ただし、再起動後の最初の 1 回は 22 秒かかった
(サンプラーのカーネルを、その場で JIT コンパイルするため)。

### イメージは head で取得し、直結リンクで worker に送る

2 台で同時に `docker pull` すると、同じインターネット回線を取り合うだけになる。head で取得してから送る。

```bash
docker pull $IMG && docker save $IMG | ssh 192.168.100.11 docker load   # 22.5GB
```

`start.sh` は、イメージのレイヤー (`RootFS.Layers`) が 2 台で一致すれば送り直さない。

**`SKIP_BUILD=1 SKIP_PULL=1 ./start.sh` で起動する。** 公開イメージ (2026-09-12 ビルド) のラベル
`dsv41.recipe.stamp` が、リポジトリ (09-13、09-16 のコミット) から計算したハッシュと一致しない。
このままだと `start.sh` が「レシピが変わった」とみなし、exllamav3 をローカルでビルドし直す。
ただし、`Dockerfile` が `COPY` する 44 ファイルは、イメージの中身とすべて同一だった (2026-09-18 に `cmp` で確認)。
ハッシュの差は、イメージに入らないファイルから来ている。

### NFS は使えない。`WEIGHT_SYNC=rsync` にする

既定の `WEIGHT_SYNC=nfs` は、この 2 台では失敗する。

```
exportfs: /export does not support NFS export
[dsv41-exl3] ERROR: NFS server did not become ready.
```

NFS コンテナが公開しようとする `/export` は、コンテナの rootfs (docker の overlay2) の上にある。
カーネルの nfsd は overlayfs を公開できない。作者の環境 (ZFS の上の docker) では通るのだと思われる。
コンテナは `--restart unless-stopped` なので、失敗したまま再起動を繰り返す。`docker rm -f dsv41-exl3-nfs` で消す。

代わりに `WEIGHT_SYNC=rsync` にして、worker にローカルコピーを置く (EXL3 と slim Engram で 387GiB)。
送り先は worker の `~/.cache/dsv41-flash-exl3/{model,engram-src}`。直結リンク越しの rsync を 2 本並列にして、
約 590MiB/s 出た。

以下は nfs 方式の仕組みの記録。

### NFS に sudo は要らない

`WEIGHT_SYNC=nfs` はホストの nfs-server を使わない。head で `--privileged --network host` の
alpine コンテナ (`dsv41-exl3-nfs`) を立て、その中でカーネル nfsd を動かす。worker 側は
docker の `local` ドライバで NFS ボリュームを作ってマウントするので、こちらも sudo は要らない。

- エクスポートは `ro,no_root_squash,insecure`。ACL は既定で `192.168.100.0/24` と `WORKER_IP`。
- このコンテナは `--restart unless-stopped`。**`stop.sh` では止まらず、再起動後も立ち上がる。**
  不要になったら `docker rm -f dsv41-exl3-nfs`。

---

## Qwen3.8-Flash-Next (NVFP4, TP=2)

レシピは <https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks> (`~/Qwen3.8-Flash-Next-Dual-DGX-Sparks`)。
重みは `nvidia/Qwen3.8-Flash-Next-NVFP4` (123.6GiB、HF_TOKEN なしで約 38MiB/s、約 56 分)。
イメージは vLLM 公式の `vllm/vllm-openai:qwen38-flash-next`。重みの配り方は rsync が既定で、sudo も特権コンテナも使わない。

### `.env` で直すところ

`HEAD_IP` / `WORKER_IP` (192.168.100.10 / .11)、`WORKER_USER=j5ik2o`、`IB_GID_INDEX=5`、`PORT=8000` に加えて、次の 2 つ。

- `HF_HOME="/home/j5ik2o/.local/share/huggingface"`。この 2 台は HF のキャッシュを標準とは違う場所に置いている。
  未設定だと `~/.cache/huggingface` を探し、重みがないと判断してダウンロードからやり直す。
- `EXTRA_VLLM_ARGS="--default-chat-template-kwargs '{\"enable_thinking\":false}'"`。思考をオフにする (DeepSeek と同じ理由)。

### huggingface_hub 1.32 は blobs を HF キャッシュ全体で共有する

`hub/models--org--name/blobs/*` は、`hub/blobs/xx/<sha256>` へのシンボリックリンクになっている。
モデルのディレクトリの `du` は 9.9M しか出ない。`du -shL snapshots/*/` なら 124G。
**モデルのディレクトリだけを rsync すると、worker にはリンク切れのリンクしか届かない** (`start.sh` の rsync も同じ)。
`hub/blobs/` も一緒に送る。

```bash
H=$HF_HOME/hub
rsync -a --partial $H/blobs/ 192.168.100.11:$H/blobs/
rsync -a --partial $H/models--nvidia--Qwen3.8-Flash-Next-NVFP4/ 192.168.100.11:$H/models--nvidia--Qwen3.8-Flash-Next-NVFP4/
```

---

## GLM-5.3-Flash (EXL3 4.05bpw, TP=2)

レシピは <https://github.com/NNNtrance/GLM-5.3-Flash-EXL3-DGX-Spark> (`~/GLM-5.3-Flash-EXL3-DGX-Spark`、
Apache-2.0) の **TP=2 track の candidate D** (`tracks/tp2/`、`docs/15`)。vLLM に cuda-exl3 と DFlash2 の移植を載せ、
NCCL の mesh プラグインで **2 本の QSFP ケーブルを両方**使う。API はポート **8001**、モデル名 `glm-5.3-flash`。

| 部品 | 入手先 | 置き場所 (2 台とも同じパス) |
|---|---|---|
| 本体 | `turboderp/GLM-5.3-Flash-exl3` rev `2a30229e` (branch 4.05bpw、165GB、MIT) | `~/models/glm-5.3-flash-exl3-4.05bpw` |
| ドラフター | `incoai/GLM-5.3-Flash-DFlash2` rev `dc77ff1c` (2.3GB) | `~/models/dflash2-draft-tp2` |
| チャットテンプレート | `zai-org/GLM-5.3-Flash` rev `690b7052` (sha256 `0c4099f3…`) | `~/exl3-zeus/chat_template.jinja` |
| イメージ | 手元でビルド (下記) | `exl3-zeus:754421f` |
| mesh プラグイン | `autoscriptlabs/nccl-mesh-plugin` `19924dcc` + `patches/kernel/0004〜0006` | `~/nccl-mesh/libnccl-net-mesh.so` |
| パッチの木 | `tracks/tp2/patches/` + tp3 からの 4 ファイル | `~/exl3-zeus/tp2d/` |
| env ファイル | `tracks/tp2/env.tp2-full.example` を sed | `~/exl3-zeus/.env.tp2-full` |

- **ドラフターのライセンスは CC BY-NC-ND 4.0 (非商用、改変不可)**。個人での検証には使えるが、業務では使えない。
- 本体は `--local-dir` で置く。起動スクリプトはディレクトリを 1 つだけマウントし、HF はオフラインで動く。
  HF キャッシュの `snapshots/` はリンクなので、コンテナの中ではリンク切れになる。

### イメージ: `Dockerfile.gb10v8` は公開されていないので作り直す

手順 (`docs/02`) は cuda-exl3 の `docker/Dockerfile.gb10v8` を使うが、上流にも、このリポジトリにも無い
(作者も `docs/02` §10 で「未公開」と書いている)。上流にある `docker/Dockerfile.sparse-mla` を元に作り直した。

```dockerfile
ARG BASE
FROM ${BASE}
ARG ARCH=12.1
ENV TORCH_CUDA_ARCH_LIST=${ARCH}
COPY . /opt/cuda-exl3
RUN cd /opt/cuda-exl3 && rm -rf build *.egg-info && \
    MAX_JOBS=1 pip install . --no-build-isolation --no-deps && \
    python3 -c "import cuda_exl3; print('cuda-exl3', cuda_exl3.__version__)"
```

```bash
# ベース: vllm/vllm-openai@sha256:905c0293… を pull して glm53-flash-arm64-cu130 とタグを付ける (31GB)
DOCKER_BUILDKIT=0 docker build --memory=4g --memory-swap=4g -f docker/Dockerfile.gb10v8 \
  --build-arg BASE=vllm/vllm-openai:glm53-flash-arm64-cu130 --build-arg ARCH=12.1 -t exl3-zeus:serve-754421f .
DOCKER_BUILDKIT=0 docker build --memory=4g --memory-swap=4g --build-arg BASE=exl3-zeus:serve-754421f \
  -t exl3-zeus:754421f ~/exl3-zeus/dflash2-port      # リポジトリの patches/dflash2-port のコピー
```

- `--memory` を効かせるため、旧来のビルダー (`DOCKER_BUILDKIT=0`) を使う。BuildKit ではこの上限が効かない。
  上限が効かないと、コンパイルが別のサーバーのメモリまで食い、OOM でそちらを落としかねない。
- ほかのサーバーが動いていて空きメモリが 8GiB しかなかったので、`MAX_JOBS` は 1 にした。それでも 1 層目は約 1.5 分で済んだ。
- 検査: ビルド中に `DFLASH2 PORT BUILD GATE: OK` と出る。cuda-exl3 のテスト (`pytest tests/`) は **44 passed / 41 skipped** で、作者と同じ。
  ほかのサーバーが動いている間は、`test_exl3_moe_glu.py` の 8 件が `CUDA error: out of memory` で落ちる。
- イメージは head でビルドし、`docker save | ssh 192.168.100.11 docker load` で worker に送った。
  ID が 2 台で一致すること (高速起動のキャッシュの識別子にイメージのタグが入る)。

### mesh プラグイン

```bash
git clone https://github.com/autoscriptlabs/nccl-mesh-plugin && cd nccl-mesh-plugin && git checkout 19924dcc
git apply ~/GLM-5.3-Flash-EXL3-DGX-Spark/patches/kernel/000{4,5,6}*.patch && make
mkdir -p ~/nccl-mesh && cp -a libnccl-net.so libnccl-net-mesh.so ~/nccl-mesh/   # 2 台とも
```

- root は要らない (`verbs.h` は 2 台とも入っていた)。コンテナに読み取り専用でマウントされるだけ。
- `make test-unit` は `test_error_paths` がリンクエラーでビルドできない (作者も既知の不具合としている)。
  `tests/test_routing` を単独で実行し、13/13 で合格すればよい。
- 2 本のケーブルが同じ 2 台の間をつなぐので、`NCCL_MESH_LINKS_PER_PEER=0` (自動) のまま。
  生成 8 回の間に、`rocep1s0f0` と `roceP2p1s0f0` がそれぞれ約 12.6GB を送った。

### パッチの木と overlay

```bash
R=~/GLM-5.3-Flash-EXL3-DGX-Spark; T=~/exl3-zeus/tp2d
cp $R/tracks/tp2/patches/*.py $T/
install -m 0755 $R/tracks/tp2/patches/tp2full-prelude.sh $T/tp2-prelude.sh && ln -f $T/tp2-prelude.sh $T/tp3-prelude.sh
cp $R/tracks/tp3/patches/vision/{patch-vision-tp3,check-vision-mapping,check-vision-names,check-video-geometry}.py $T/
cp $R/tracks/tp3/patches/patch-vllm-tp3.py $R/tracks/tp3/patches/prefix-hit-and-kpool-tail/patch-{prefixhit,kpooltail}-tp3.py $T/
```

- **高速起動のキャッシュは、この木の `patch-*.py` と prelude の中身から識別子を作る。** 初回起動 (dump) の前に完成させ、
  その後はファイルを 1 つも足さない。足すと次の起動が拒否される。
- prelude は 2 つの名前で**ハードリンク**にする (`tp3-prelude.sh` の名前でハッシュされるため)。
- overlay (`$T/overlay/`) はイメージから取り出して作る。
  1. `sparse_attn_indexer.py` と `sparse_attn_indexer_kpool.py` を `docker cp` で取り出す
  2. `patches/indexer-overlay/0001`、`0002` を当てる
  3. kpool のほうは読み取り専用でマウントされるので、`patch-indexer-workspace-tp3.py` を先に当てておく。
     このスクリプトは `--root` の下の 2 ファイル (`v1/attention/backends/mla/indexer.py` と kpool) しか触らない。
     その 2 つだけを置いたダミーの root を作り、ホストで実行した
- 2 台の木が一致していることを md5 で確かめる (24 ファイル)。

### env ファイル

```bash
sed -e "s/@NODE_RANK@/0/" -e "s/@HOST_IP@/10.0.1.60/" -e 's/@HEAD_IP@/10.0.1.60/' -e 's/@IFACE@/enP7s7/' \
    -e 's|@HOME@|/home/j5ik2o|g' -e 's|@CKPT@|/home/j5ik2o/models/glm-5.3-flash-exl3-4.05bpw|' \
    -e 's|@DRAFT_TP2@|/home/j5ik2o/models/dflash2-draft-tp2|' tracks/tp2/env.tp2-full.example > ~/exl3-zeus/.env.tp2-full
# worker は NODE_RANK=1、HOST_IP=10.0.1.61
```

- **`MASTER_ADDR` と `HOST_IP` は LAN (10.0.1.x、`enP7s7`)。** 直結の 192.168.100.x にすると、何も出さずに止まる (作者の注意)。
  RDMA のデバイスは mesh プラグインが自分で見つけるので、`NCCL_IB_GID_INDEX` は設定しない。
- テンプレートは `FASTLOAD_MODE=load` になっている。**初回は `dump`** にしないと「キャッシュがない」で止まる。
- `DRY_RUN=1 FABRIC_PREFIX=192.168.10 bash scripts/start-tp2full.sh 0` で `docker run` の全体を確認できる。
- `tracks/tp2/patches/verify-cpu.sh` (GPU を使わない検査) は、自分のディレクトリをパッチの木とみなす。
  `DIR=` の行を `~/exl3-zeus/tp2d` に書き換えたコピーで実行する。最後の動画の検査は `fixtures/` が無いと落ちるが、
  本番の prelude はそのとき「SKIPPED」と出して先に進む。

### 起動

```bash
# worker が先、head があと。各レシピのサーバー (vllm-fn など) は止めておく
ssh spark-5083 'cd ~/GLM-5.3-Flash-EXL3-DGX-Spark && bash scripts/start-tp2full.sh 1'
ssh spark-153d 'cd ~/GLM-5.3-Flash-EXL3-DGX-Spark && bash scripts/start-tp2full.sh 0'
docker rm -f exl3-tp2   # 止めるとき (2 台とも)
```

- 初回 (dump) は、コンテナの起動から準備完了まで約 17.5 分。重みの読み込みが 162 秒で、高速起動のキャッシュ
  (`/var/tmp/glm53-exl3-tp2d-r{0,1}`、1 台 79GB) を書き出す。2 回目からは env を `load` にすると約 4.7 分 (作者の値)。
- KV は 16.63GiB、2,203,571 トークン (作者の値は 20.15GiB、259 万)。

### 実績 (2026-09-19)

`/v1/messages` + ツール呼び出し ✓ (作者は試していない)、画像 ✓ (左右 2 色の 64×32 画像で色を答えさせた、1 回)。

**生成速度の測り方** (GLM と Qwen で同じ)

- サンプル数: 4 種類のプロンプト × **各 2 回** (GLM は 2026-09-19 14:3x JST、Qwen は同日 05:2x JST)。
  標本が少ないので、傾向を見る程度にとどめる。ばらつきの幅や信頼区間は出していない。
- プロンプト (1 種類につき固定の 1 文):
  - コード・英語 `Implement a simple LRU cache in Python and explain it.`
  - 散文・英語 `Write a detailed prose essay about the four seasons in Japan.`
  - コード・日本語 `Pythonで簡単なLRUキャッシュを実装して、解説して`
  - 散文・日本語 `日本の四季について、それぞれの特徴を散文で詳しく書いて`
- `/v1/chat/completions`、`max_tokens` 600 (8 回とも 600 トークンまで出た)、同時 1 本、ストリーミングなし。
  温度などのサンプリングは指定せず、サーバーの既定値。
- 値は `completion_tokens ÷ リクエスト全体の時間`。最初のトークンまでの時間 (入力の処理) も含む。入力が短いので影響は小さい。
- 思考: GLM は `reasoning_effort: low` と `clear_thinking` (レシピの既定)、Qwen は `enable_thinking: false`。条件はそろっていない。
- サーバーの設定: GLM は candidate D (DFlash2 で 7 トークン)、Qwen は MiaAI-Lab の Dual の既定 (MTP で 3 トークン、ドラフターは英語とコード向けの 4.7 万語)。

表の値は 1 回目 / 2 回目 (tok/s)。

| 内容 | GLM-5.3-Flash | Qwen3.8-Flash-Next |
|---|---|---|
| コード・英語 | 63.1 / 66.4 | 56.5 / 57.4 |
| 散文・英語 | 30.7 / 29.5 | 35.8 / 37.4 |
| コード・日本語の説明つき | 43.7 / 50.4 | 38.0 / 35.5 |
| 散文・日本語 | 23.1 / 24.6 | 23.1 / 23.0 |

- コードとツール呼び出しは GLM が速い (DFlash2 が 7 トークン先まで下書きし、コードではよく当たる)。英語の散文は Qwen が速い。
- 入力の処理は、作者の値で GLM 1,413 tok/s、Qwen 2,960 tok/s。キャッシュが効かない往復は GLM のほうが遅い。
- **エージェント用途の既知の限界**: 会話が約 3.6 万トークンを超えると壊れたツール呼び出しが出始め、約 7 万でループする
  (`tracks/tp2/README.md`)。3 台構成で直した `index_topk` 8192 は、2 台では試されていない。

### zsh の `$VAR:e` に注意

`rsync ... $W:exl3-zeus/` のように書くと、zsh は `:e` を「拡張子を取り出す」修飾子として解釈する。
`W=192.168.100.11` なら `11xl3-zeus/` という**ローカルの**パスになり、worker には何も届かない (rsync は成功扱い)。
`"$W":exl3-zeus/`、`${W}:…`、または絶対パスで書く。

---

## sparkDash (監視ダッシュボード)

<https://github.com/MiaAI-Lab/sparkDash>

### nginx を前段に置く 2 段構成にした

```
ブラウザ ──→ nginx (0.0.0.0:5555, Basic 認証) ──→ sparkDash (127.0.0.1:5556)
```

素直に LAN へ公開できない事情がある。

sparkDash の `SPARKDASH_TOKEN` は **API クライアント用であってブラウザ用ではない**。
トークンを設定してリモートバインドすると、認証ミドルウェアが静的アセットを含む
**全 GET** にトークンを要求する。

```js
// server/auth.js
if (!mutating && remote && !configuredToken()) { ... }  // トークン有りなのでここを通らず
const result = authenticate(req);                        // → 全 GET が認証必須
```

ブラウザの `<script src="/assets/index.js">` は `Authorization` ヘッダを付けられないので、
アセットが 401 になり **SPA が永久に起動しない**。`?token=` で HTML を開いてもアセット取得で
失敗する。

かといってトークンを設定しないと、`SPARKDASH_ALLOW_OPEN_REMOTE` の既定が `1` のため
**LAN 上の誰でも無認証で全操作可能**になる (電源制御・認証情報変更を含む)。しかも
`authenticate()` はトークン未設定時に無条件で `ok` を返すため、操作系まで素通りする。

よって本体はループバックに置き、認証は nginx の Basic 認証で担保する。
これはリポジトリのドキュメント (`docs/REMOTE-ACCESS.md`) が推奨している方式でもある。

### 設定ファイル

本体の `docker-compose.yml` は編集しない (`git pull` できるようにするため)。

| ファイル | 内容 |
|---|---|
| `~/sparkDash/.env` | `PORT=5556` / `BIND_HOST=127.0.0.1` |
| `~/sparkDash/docker-compose.override.yml` | `PORT` を 5556 に上書き / worker 監視用の SSH 鍵をマウント |
| `~/sparkDash/config/sparks.json` | 監視対象とロール (UI か `/api/sparks` で編集する) |
| `~/sparkdash-proxy/` | `nginx.conf` / `.htpasswd` / `docker-compose.yml` |

`docker-compose.override.yml` が必要なのは、本体の compose が `PORT=5555` を
**リテラルで**指定しており `.env` の値が効かないため。

```yaml
services:
  sparkdash:
    environment:
      - PORT=5556
    volumes:
      - ${HOME}/.ssh/id_ed25519.tailnet:/root/.ssh/id_ed25519:ro
```

### 2 台構成 (Head / Worker)

sparkDash は spark-153d だけで動かし、spark-5083 は SSH で監視する。

| id | ホスト | ロール | 監視方法 | LLM 監視 |
|---|---|---|---|---|
| `spark1` | spark-153d | head | ローカル (`isLocal`) | ポート 8000 (vLLM rank 0) |
| `spark2` | spark-5083 | worker (`workerHeadId: spark1`) | SSH `j5ik2o@10.0.1.61` | なし |

- SSH は**コンテナ内から**張られる。ホストの `~/.ssh` は見えないので、鍵を
  `/root/.ssh/id_ed25519` という既定名でマウントする。パスフレーズ付きの鍵は使えない (BatchMode)。
- LLM ポートの既定は 8888。vLLM は 8000 で立てているので head 側を 8000 に直す。
- worker の表示ラベルは head の LLM から検出したモデル名が自動で入る。
- 追加・変更は UI の代わりに API でもできる (ループバックなのでトークン不要)。

  ```bash
  curl -X POST  127.0.0.1:5556/api/sparks/test   -H 'Content-Type: application/json' -d @spark2.json
  curl -X POST  127.0.0.1:5556/api/sparks        -H 'Content-Type: application/json' -d @spark2.json
  curl -X PATCH 127.0.0.1:5556/api/sparks/spark1 -H 'Content-Type: application/json' -d '{"role":"head"}'
  curl -X PUT   127.0.0.1:5556/api/sparks/spark1/llm-ports -H 'Content-Type: application/json' -d '{"llmPorts":[8000]}'
  ```

### 落とし穴

- **`.htpasswd` は 644 にする。** コンテナ内の nginx は uid 101 で動くため、600 だと
  `open() "/etc/nginx/.htpasswd" failed (13: Permission denied)` で全リクエストが 500 になる。
  中身は APR1 ハッシュなので 644 で問題ない。
- **nginx は IPv4 / IPv6 の両方で待ち受ける。** `listen 5555;` だけだと IPv4 のみ。
  Tailscale は v6 アドレスも割り当てるので、モバイルから MagicDNS 名で繋ぐと届かないことがある。

  ```nginx
  listen 5555;
  listen [::]:5555;
  ```
- **WebSocket の中継設定が要る。** `/ws` が通らないとメトリクスがリアルタイム更新されない。

  ```nginx
  map $http_upgrade $connection_upgrade { default upgrade; '' close; }
  # location 内
  proxy_http_version 1.1;
  proxy_set_header Upgrade    $http_upgrade;
  proxy_set_header Connection $connection_upgrade;
  ```

### 資格情報

Basic 認証のユーザー名/パスワードは `~/sparkdash-proxy/.htpasswd` (ハッシュ) にある。
このリポジトリには置かない。変更はこれで行う。

```bash
cd ~/sparkdash-proxy
printf 'USER:%s\n' "$(openssl passwd -apr1 'NEW_PASSWORD')" > .htpasswd
chmod 644 .htpasswd && docker compose restart
```

### `LLM API: Fail` は異常ではない

sparkDash は既定で **8888** を見に行く。そこで LLM サーバーが動いていなければ Fail と出る。
vLLM を繋ぐなら `-p 8888:8000` にするか、ユニット設定側でポートを合わせる。
ComfyUI / Hermes / Tailnet の監視は既定オフ。

### ComfyUI について

sparkDash が ComfyUI を起動するわけではない。**既に動いている ComfyUI を覗きに行く**
オプトイン機能 (`comfyMonitoring`、既定オフ、既定ポート 8188)。ComfyUI 自体は
画像・動画生成のノードベース UI で、LLM とは用途が別。使っていないなら有効にする意味はない。

---

## Tailscale

### Tailscale SSH (`--ssh`) は有効にしない

`tailscale up --ssh` にすると、tailnet 経由で来た 22 番への接続を sshd ではなく
tailscaled が受ける。ACL の ssh ルールが `check` モードだと、公開鍵を持っていても
ブラウザでの追加認証を要求され、`BatchMode` の ssh は無言で止まる。

```
# Tailscale SSH requires an additional check.
# To authenticate, visit: https://login.tailscale.com/a/...
```

QSFP 直結 IP (`192.168.10x.x`) 宛ては tailnet を通らないので通る、という非対称な症状になる。
`spark-5083` で一度これを踏んだ。対処は `sudo tailscale set --ssh=false` で、
以後は普通の sshd + `~/.ssh/id_ed25519.tailnet` で認証する。

---

## macOS クライアント側の落とし穴

### Chrome だけ `ERR_ADDRESS_UNREACHABLE` になる

**サーバーを疑う前にここを見る。** 判別法は単純で、Mac のターミナルから curl を打つ。

```bash
curl -v http://<LAN-IP>:5555/
```

**curl は通るのに Chrome だけ落ちる**なら、原因は macOS の「ローカルネットワーク」
プライバシー権限。macOS 15 以降、アプリはローカルネットワーク上のアドレスへのアクセスに
OS の許可が必要で、権限が無いと Chrome が接続を試みる前に OS がパケットを遮断する。

ループバック (`127.0.0.1`) はこの対象外なので、SSH トンネル経由なら繋がる。
これが切り分けの決め手になる。

対処:

1. システム設定 → プライバシーとセキュリティ → ローカルネットワーク → 当該ブラウザをオン
2. ブラウザを ⌘Q で完全終了して起動し直す

権限が既にオンなのに繋がらない場合、表示と内部状態が食い違っている既知の不具合がある。
オフ→オンし直す、または Mac を再起動する。Chrome 側にも独立した Local Network Access の
制限があり (`chrome://flags/#local-network-access-check`)、バージョンによって挙動が変わる。
今回は Chrome 152 → 153 の更新で解消した。

### 切り分けの原則

サーバー自身から自分の IP 宛てに curl しても、通信はループバックを通るだけで
**外部からの到達性は証明できない**。別ネットワーク名前空間から測ること。

```bash
docker run --rm --network bridge nginx:alpine sh -c \
  'for p in 22 3389 5555; do nc -z -w3 <LAN-IP> $p && echo "$p OK" || echo "$p NG"; done'
```

なお alpine の busybox `sh` は `/dev/tcp` をサポートしない (bash 専用)。`nc` を使う。

---

## 未着手 / 保留

### デーモン化

vLLM の常駐化 (systemd か compose) はまだ。2 台構成の起動方法は `vllm-cluster-node.sh` で固まった。

### 2 本目の直結リンクを使う

`NCCL_IB_HCA` に `roceP2p1s0f0` (192.168.101.x) も足せば帯域を倍にできる見込み。未検証。
