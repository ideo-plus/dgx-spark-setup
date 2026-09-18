#!/bin/bash
# 2 台の DGX Spark で vLLM を tensor parallel 2 で動かす (1 台に 1 ノードずつ起動する)。
#  - 使い方: ./vllm-cluster-node.sh <rank> <model> [vllm serve に渡す追加オプション...]
#    rank 0 = spark-153d (API を受ける側)、rank 1 = spark-5083 (headless)。両方で実行する
#    例: ./vllm-cluster-node.sh 0 Qwen/Qwen3-0.6B   (spark-153d)
#        ./vllm-cluster-node.sh 1 Qwen/Qwen3-0.6B   (spark-5083)
#  - イメージに Ray が無いので、vLLM 組み込みの複数ノード (--nnodes / --node-rank) を使う
#  - ノード間通信は QSFP 直結リンク上の RoCE (setup-qsfp-link.sh で振ったアドレス)
#  - モデルは両機の ~/.local/share/huggingface に置いておく (オフラインで読む)
#  - 追加オプションのうちエンジン設定 (--max-model-len など) は両機でそろえて引数で渡す。
#    API サーバー専用のもの (ツール呼び出し・reasoning パーサなど) は headless の rank 1 が
#    unrecognized arguments で落ちるので、API_ARGS に入れる (rank 0 にだけ渡る)
#    例: API_ARGS="--enable-auto-tool-choice --tool-call-parser hermes --reasoning-parser qwen3"
#  - 環境変数: IMAGE, GPU_UTIL (既定 0.2), PORT (既定 8000), API_ARGS, NCCL_DEBUG
#  - 止めるとき: docker rm -f vllm-node (両機)
set -eu

RANK=${1:?usage: $0 <rank 0|1> <model> [vllm args...]}
MODEL=${2:?usage: $0 <rank 0|1> <model> [vllm args...]}
shift 2
case "$RANK" in 0|1) ;; *) echo "rank は 0 か 1" >&2; exit 1;; esac

IMAGE=${IMAGE:-nvcr.io/nvidia/vllm:26.08-py3}
GPU_UTIL=${GPU_UTIL:-0.2}
PORT=${PORT:-8000}
IFACE=enp1s0f0np0
HCA=rocep1s0f0
MASTER=192.168.100.10
MY_IP=192.168.100.$((10 + RANK))

# GPU が死んでいると (Xid 119 など) コンテナは起動するがワーカーが
# "No CUDA GPUs are available" で落ちるだけなので、先に確かめる
python3 -c 'import ctypes,sys; sys.exit(ctypes.CDLL("libcuda.so.1").cuInit(0))' || {
  echo "cuInit 失敗: GPU が使えない。journalctl -k | grep Xid を確認 (多くは再起動で戻る)" >&2
  exit 1
}

EXTRA=()
if [ "$RANK" -eq 0 ]; then
  read -r -a EXTRA <<< "${API_ARGS:-}"
else
  EXTRA=(--headless)
fi

docker rm -f vllm-node >/dev/null 2>&1 || true
docker run -d --name vllm-node --network host --gpus all --ipc=host \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  --device /dev/infiniband --cap-add IPC_LOCK \
  -v "$HOME/.local/share/huggingface:/root/.cache/huggingface" \
  -e HF_HUB_OFFLINE=1 \
  -e VLLM_HOST_IP="$MY_IP" \
  -e NCCL_SOCKET_IFNAME=$IFACE -e GLOO_SOCKET_IFNAME=$IFACE \
  -e NCCL_IB_HCA=$HCA ${NCCL_DEBUG:+-e NCCL_DEBUG=$NCCL_DEBUG} \
  "$IMAGE" \
  vllm serve "$MODEL" --host 0.0.0.0 --port "$PORT" \
    --tensor-parallel-size 2 --nnodes 2 --node-rank "$RANK" \
    --master-addr $MASTER --master-port 29501 \
    --gpu-memory-utilization "$GPU_UTIL" "${EXTRA[@]}" "$@"
echo "起動した (rank $RANK)。ログ: docker logs -f vllm-node"
