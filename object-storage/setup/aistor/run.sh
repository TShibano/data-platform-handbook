#!/usr/bin/env bash
# MinIO AIStor（商用版）を単一ノードで起動・停止する
# 使い方: ./run.sh {start|stop|status|logs|purge|config}
#   設定は同じディレクトリの .env で与える（cp .env.example .env して編集する．無ければ既定値）．
#   別ファイルは ENV_FILE=.env.bench ./run.sh start のように指定する．
#   優先順位: シェルの環境変数 > .env > 既定値（config で実際の値と出所を確認できる）
#   ライセンスファイルは既定で このディレクトリの minio.license を読む（AISTOR_LICENSE_FILE で変更可）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/env.sh"
env_load "$SCRIPT_DIR"

# 既定値は .env.example と compose.yaml に揃える
env_var CONTAINER_RUNTIME podman
env_var AISTOR_IMAGE quay.io/minio/aistor/minio:RELEASE.2026-09-19T17-05-25Z
# 相対パスは compose と同じくこのディレクトリ基準で解決する
env_var AISTOR_LICENSE_FILE ./minio.license
env_var AISTOR_S3_PORT 9010
env_var AISTOR_CONSOLE_PORT 9011
env_var AISTOR_ROOT_USER minioadmin
env_var AISTOR_ROOT_PASSWORD minioadmin secret

RUNTIME="$CONTAINER_RUNTIME"
NAME="handbook-aistor"
VOLUME="${NAME}-data"
IMAGE="$AISTOR_IMAGE"
LICENSE_FILE="$(env_abs_path "$AISTOR_LICENSE_FILE" "$SCRIPT_DIR")"
S3_PORT="$AISTOR_S3_PORT"
CONSOLE_PORT="$AISTOR_CONSOLE_PORT"
ROOT_USER="$AISTOR_ROOT_USER"
ROOT_PASSWORD="$AISTOR_ROOT_PASSWORD"

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
    env_print_source
    if container_running; then
        echo "$NAME は起動済み"
        print_info
        return 0
    fi
    if container_exists; then
        "$RUNTIME" start "$NAME" >/dev/null
    else
        local mount_args=() server_args=(minio server /mnt/data)
        if [ -f "$LICENSE_FILE" ]; then
            mount_args=(-v "$LICENSE_FILE:/minio.license:ro")
            server_args+=(--license /minio.license)
        else
            # RELEASE.2025-12-20T04-58-37Z 以降はライセンス無しでも起動するが，S3 操作はすべて拒否される
            echo "警告: ライセンスファイル $LICENSE_FILE が無い．オフラインモードで起動する（S3 操作は不可，コンソールからライセンス登録のみ可能）" >&2
        fi
        "$RUNTIME" run -d \
            --name "$NAME" \
            -p "$S3_PORT:9000" \
            -p "$CONSOLE_PORT:9001" \
            -e MINIO_ROOT_USER="$ROOT_USER" \
            -e MINIO_ROOT_PASSWORD="$ROOT_PASSWORD" \
            -v "$VOLUME:/mnt/data" \
            ${mount_args[@]+"${mount_args[@]}"} \
            "$IMAGE" "${server_args[@]}" >/dev/null
    fi
    echo "AIStor 起動待機中..."
    wait_until "AIStor の起動" curl -sf "http://localhost:$S3_PORT/minio/health/live"
    echo "AIStor 準備完了"
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
