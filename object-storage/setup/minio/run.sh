#!/usr/bin/env bash
# MinIO（コミュニティ版）を単一ノードで起動・停止する
# 使い方: ./run.sh {start|stop|status|logs|purge|build|config}
#   設定は同じディレクトリの .env で与える（cp .env.example .env して編集する．無ければ既定値）．
#   別ファイルは ENV_FILE=.env.bench ./run.sh start のように指定する．
#   優先順位: シェルの環境変数 > .env > 既定値（config で実際の値と出所を確認できる）
#   公式ソースを同じディレクトリの Dockerfile でビルドしたイメージを使う．
#   start はイメージが無ければビルドしてから起動し，build は常に再ビルドする．
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/env.sh"
env_load "$SCRIPT_DIR"

# 既定値は .env.example と compose.yaml に揃える
env_var CONTAINER_RUNTIME podman
# 公式リポジトリ github.com/minio/minio の最終リリースタグ
env_var MINIO_VERSION RELEASE.2025-10-15T17-29-55Z
# 既存のイメージ（キャッシュ済みの公式イメージ等）を使う場合は MINIO_IMAGE で上書きする
env_var MINIO_IMAGE "localhost/handbook-minio:$MINIO_VERSION"
env_var MINIO_S3_PORT 9000
env_var MINIO_CONSOLE_PORT 9001
env_var MINIO_ROOT_USER minioadmin
env_var MINIO_ROOT_PASSWORD minioadmin secret

RUNTIME="$CONTAINER_RUNTIME"
NAME="handbook-minio"
VOLUME="${NAME}-data"
VERSION="$MINIO_VERSION"
IMAGE="$MINIO_IMAGE"
S3_PORT="$MINIO_S3_PORT"
CONSOLE_PORT="$MINIO_CONSOLE_PORT"
ROOT_USER="$MINIO_ROOT_USER"
ROOT_PASSWORD="$MINIO_ROOT_PASSWORD"

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
    echo "  認証情報: $ROOT_USER / $ROOT_PASSWORD"
}

image_exists() { "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; }

cmd_build() {
    echo "$IMAGE をビルドする（MINIO_VERSION=${VERSION}．初回は数分かかる）"
    "$RUNTIME" build \
        --build-arg MINIO_VERSION="$VERSION" \
        -t "$IMAGE" \
        -f "$SCRIPT_DIR/Dockerfile" \
        "$SCRIPT_DIR"
    if container_exists; then
        echo "既存のコンテナ $NAME は古いイメージのまま．反映するには ./run.sh stop && ./run.sh start を実行する"
    fi
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
        # `image_exists || cmd_build` だと cmd_build 内で set -e が効かないため if で書く
        if ! image_exists; then cmd_build; fi
        "$RUNTIME" run -d \
            --name "$NAME" \
            -p "$S3_PORT:9000" \
            -p "$CONSOLE_PORT:9001" \
            -e MINIO_ROOT_USER="$ROOT_USER" \
            -e MINIO_ROOT_PASSWORD="$ROOT_PASSWORD" \
            -v "$VOLUME:/data" \
            "$IMAGE" server /data --console-address ":9001" >/dev/null
    fi
    echo "MinIO 起動待機中..."
    wait_until "MinIO の起動" curl -sf "http://localhost:$S3_PORT/minio/health/live"
    echo "MinIO 準備完了"
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
    build) cmd_build ;;
    config) env_print_config ;;
    *) echo "使い方: $0 {start|stop|status|logs|purge|build|config}" >&2; exit 1 ;;
esac
