#!/bin/bash
# 2 台の DGX Spark で動かすモデルを切り替える (spark-153d で実行する)。
#  - 使い方: ./spark-model.sh <qwen|deepseek|stop|status|logs>
#    qwen      いま動いているものを止めて Qwen3.8-Flash-Next を起動する (モデル名 qwen3.8-flash-next)
#    deepseek  いま動いているものを止めて DeepSeek-V4.1-Flash を起動する (モデル名 DeepSeek-v4.1-Flash-EXL3)
#    stop      どれも止める
#    status    動いているコンテナと API の状態を表示する
#    logs      起動中または最後に起動したレシピの start.sh のログを追う (Ctrl-C で抜けてもサーバーは止まらない)
#  - Mac からは: ssh spark-153d dgx-spark-setup/spark-model.sh qwen
#  - 起動は切り離して行う (ssh が切れても続く)。準備完了まで Qwen は約 13 分、DeepSeek は約 6 分
#  - API はどれもポート 8000。各レシピの .env はこの 2 台に合わせて設定済み (NOTES.md 参照)
set -eu

QWEN_DIR=$HOME/Qwen3.8-Flash-Next-Dual-DGX-Sparks
DS_DIR=$HOME/DeepSeek-v4.1-Flash-EXL3-2x-DGX-Sparks
WORKER=192.168.100.11
LAST=$HOME/.cache/spark-model-last   # 最後に起動したレシピのディレクトリ

stop_all() {
    # 各レシピの stop.sh は自分のコンテナ (vllm-fn / dsv41-exl3-*) だけを止める
    (cd "$QWEN_DIR" && ./stop.sh) || true
    (cd "$DS_DIR" && ./stop.sh) || true
    # vllm-cluster-node.sh で起動したもの
    docker rm -f vllm-node >/dev/null 2>&1 || true
    ssh "$WORKER" docker rm -f vllm-node >/dev/null 2>&1 || true
}

launch() {   # <dir> <env...>
    local dir=$1; shift
    mkdir -p "$dir/logs"
    (cd "$dir" && env "$@" setsid -f ./start.sh > logs/start.out 2>&1 < /dev/null)
    mkdir -p "$(dirname "$LAST")"; echo "$dir" > "$LAST"
    echo "起動を開始した。ログ: $0 logs"
}

case "${1:-}" in
    qwen)
        stop_all
        launch "$QWEN_DIR"
        ;;
    deepseek)
        stop_all
        # 公開イメージのラベルがリポジトリのハッシュと合わないので、再ビルドを止める (NOTES.md 参照)
        launch "$DS_DIR" SKIP_BUILD=1 SKIP_PULL=1
        ;;
    stop)
        stop_all
        ;;
    status)
        echo "== head";   docker ps --format '  {{.Names}}\t{{.Status}}' | grep -E 'vllm|dsv41' || echo "  (なし)"
        echo "== worker"; ssh "$WORKER" "docker ps --format '  {{.Names}}\t{{.Status}}'" | grep -E 'vllm|dsv41' || echo "  (なし)"
        if curl -fsS -m 5 localhost:8000/v1/models >/dev/null 2>&1; then
            echo "== API: $(curl -s localhost:8000/v1/models | python3 -c 'import sys,json; print(", ".join(m["id"] for m in json.load(sys.stdin)["data"]))')"
        else
            echo "== API: 応答なし"
        fi
        ;;
    logs)
        [ -f "$LAST" ] || { echo "まだ何も起動していない" >&2; exit 1; }
        tail -n 50 -f "$(cat "$LAST")/logs/start.out"
        ;;
    *)
        sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
