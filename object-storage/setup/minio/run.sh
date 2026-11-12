#!/usr/bin/env bash
# MinIO（コミュニティ版）を単一ノードで起動・停止する
# 使い方: ./run.sh {start|stop|status|logs|purge}
#   CONTAINER_RUNTIME=docker ./run.sh start のようにランタイムを切り替えられる（既定は podman）
set -euo pipefail

RUNTIME="${CONTAINER_RUNTIME:-podman}"
NAME="handbook-minio"
VOLUME="${NAME}-data"
# 公式イメージは匿名取得できないため，コミュニティフォークの最終 MinIO 名義リリースを既定にする
IMAGE="${MINIO_IMAGE:-docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z}"
S3_PORT="${MINIO_S3_PORT:-9000}"
CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"

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

cmd_start() {
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
    *) echo "使い方: $0 {start|stop|status|logs|purge}" >&2; exit 1 ;;
esac
