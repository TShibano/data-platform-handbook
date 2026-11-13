#!/usr/bin/env bash
# RustFS を単一ノードで起動・停止する
# 使い方: ./run.sh {start|stop|status|logs|purge|config}
#   設定は同じディレクトリの .env で与える（cp .env.example .env して編集する．無ければ既定値）．
#   別ファイルは ENV_FILE=.env.bench ./run.sh start のように指定する．
#   優先順位: シェルの環境変数 > .env > 既定値（config で実際の値と出所を確認できる）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/env.sh"
env_load "$SCRIPT_DIR"

# 既定値は .env.example と compose.yaml に揃える
env_var CONTAINER_RUNTIME podman
env_var RUSTFS_IMAGE docker.io/rustfs/rustfs:1.0.5
env_var RUSTFS_S3_PORT 9020
env_var RUSTFS_CONSOLE_PORT 9021
# rustfsadmin は既知の値．localhost 以外へ公開する場合は必ず上書きする
env_var RUSTFS_ACCESS_KEY rustfsadmin
env_var RUSTFS_SECRET_KEY rustfsadmin secret

RUNTIME="$CONTAINER_RUNTIME"
NAME="handbook-rustfs"
VOLUME="${NAME}-data"
IMAGE="$RUSTFS_IMAGE"
S3_PORT="$RUSTFS_S3_PORT"
CONSOLE_PORT="$RUSTFS_CONSOLE_PORT"
ACCESS_KEY="$RUSTFS_ACCESS_KEY"
SECRET_KEY="$RUSTFS_SECRET_KEY"

container_exists() { "$RUNTIME" container inspect "$NAME" >/dev/null 2>&1; }
container_running() {
    [ "$("$RUNTIME" container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]
}

# 指定コマンドが成功するまで最大60秒待つ
wait_until() {
    local desc="$1"; shift
    for _ in $(seq 1 60); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "タイムアウト: $desc（$RUNTIME logs $NAME で確認する）" >&2
    return 1
}

print_info() {
    echo "  S3 API:  http://localhost:$S3_PORT"
    echo "  Console: http://localhost:$CONSOLE_PORT"
    echo "  認証情報: $ACCESS_KEY / $SECRET_KEY"
}

cmd_start() {
    env_print_source
    if container_running; then
        echo "$NAME は起動済み"
        print_info
        return 0
    fi
    if container_exists; then
        "$RUNTIME" start "$NAME" >/dev/null
    else
        "$RUNTIME" run -d \
            --name "$NAME" \
            -p "$S3_PORT:9000" \
            -p "$CONSOLE_PORT:9001" \
            -e RUSTFS_ACCESS_KEY="$ACCESS_KEY" \
            -e RUSTFS_SECRET_KEY="$SECRET_KEY" \
            -e RUSTFS_VOLUMES=/data \
            -e RUSTFS_ADDRESS=":9000" \
            -e RUSTFS_CONSOLE_ADDRESS=":9001" \
            -e RUSTFS_CONSOLE_ENABLE=true \
            -v "$VOLUME:/data" \
            "$IMAGE" >/dev/null
    fi
    echo "RustFS 起動待機中..."
    wait_until "RustFS の起動" curl -sf "http://localhost:$S3_PORT/health"
    echo "RustFS 準備完了"
    print_info
}

cmd_stop() {
    if container_exists; then
        # データはボリュームに残す
        "$RUNTIME" rm -f "$NAME" >/dev/null
        echo "$NAME を停止・削除した（ボリューム $VOLUME は保持）"
    else
        echo "$NAME は存在しない"
    fi
}

cmd_status() {
    if container_running; then
        echo "$NAME: 起動中"
        print_info
    elif container_exists; then
        echo "$NAME: 停止中"
    else
        echo "$NAME: 未作成"
    fi
}

cmd_logs() { "$RUNTIME" logs -f "$NAME"; }

cmd_purge() {
    if [ "${FORCE:-0}" != "1" ]; then
        read -r -p "$NAME とボリューム $VOLUME を削除する．よろしいか [y/N]: " ans
        [ "$ans" = "y" ] || { echo "中止した"; return 1; }
    fi
    cmd_stop
    "$RUNTIME" volume rm "$VOLUME" >/dev/null 2>&1 && echo "ボリューム $VOLUME を削除した" || true
}

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    purge) cmd_purge ;;
    config) env_print_config ;;
    *) echo "使い方: $0 {start|stop|status|logs|purge|config}" >&2; exit 1 ;;
esac
