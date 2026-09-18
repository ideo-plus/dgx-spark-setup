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

物理モニタは接続していない (headless)。この前提が RDP の構成を決めている。

---

## リモートデスクトップ (RDP)

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
