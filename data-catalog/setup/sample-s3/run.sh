#!/usr/bin/env bash
# インジェスト対象のサンプル S3（MinIO + メダリオン構成の parquet）を起動・停止する
# 使い方: ./run.sh {start|load|stop|status|logs|purge|config [--show-secrets]}
#   設定は同じディレクトリの .env で与える（cp .env.example .env して編集する．無ければ既定値）．
#   別ファイルは ENV_FILE=.env.bench ./run.sh start のように指定する．
#   優先順位: シェルの環境変数 > .env > 既定値（config で実際の値と出所を確認できる）
#   OpenMetadata / DataHub のどちらのスタックとも別 compose プロジェクトのため，起動順序の依存はない
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/env.sh"
# preflight.sh は common.sh も読み込む
. "$SCRIPT_DIR/../lib/preflight.sh"
env_load "$SCRIPT_DIR"

# 既定値は .env.example と compose.yaml に揃える
# object-storage/setup/minio の Dockerfile でビルドする公式ソースのタグ（イメージタグにも使う）
env_var SAMPLE_S3_MINIO_VERSION RELEASE.2025-10-15T17-29-55Z
env_var SAMPLE_S3_START_TIMEOUT 60
export SAMPLE_S3_MINIO_VERSION

# 接続情報は検証用の固定値で秘密ではない（compose.yaml と各ツールのインジェスト定義に同じ値を書いている）
CONTAINER_NAME="sample_minio"
ACCESS_KEY="sample_s3_user"
SECRET_KEY="sample_s3_password"
BUCKET="sample-lake"
S3_PORT=9100
CONSOLE_PORT=9101
MINIO_IMAGE="localhost/handbook-minio:${SAMPLE_S3_MINIO_VERSION}"
MINIO_BUILD_DIR="$(cd "$SCRIPT_DIR/../../../object-storage/setup/minio" && pwd)"
GENERATOR_IMAGE="sample-s3-generator:local"

compose() {
    local env_args=()
    [ -n "$ENV_FILE_LOADED" ] && env_args=(--env-file "$ENV_FILE_LOADED")
    (cd "$SCRIPT_DIR" && "${COMPOSE_CMD[@]}" ${env_args[@]+"${env_args[@]}"} -f compose.yaml "$@")
}

compose_prepare() {
    require_podman
    compose_cmd
}

# MinIO のイメージが無ければ object-storage/setup/minio の Dockerfile でビルドする
# （初回は Go のビルドで数分かかる．object-storage 側でビルド済みならそれを使う）
ensure_minio_image() {
    if podman image exists "$MINIO_IMAGE"; then
        return 0
    fi
    log_info "$MINIO_IMAGE が無いのでビルドする（初回は数分かかる）．"
    podman build --build-arg "MINIO_VERSION=$SAMPLE_S3_MINIO_VERSION" -t "$MINIO_IMAGE" "$MINIO_BUILD_DIR"
}

# 生成スクリプトをコンテナで実行する．MinIO へは各ツールのインジェストと同じく
# host.containers.internal 経由でホストの公開ポートに接続する．
# （MinIO とネットワーク名前空間を共有する方式は，podman-compose が作る pod が
#  名前空間を共有しない設定のため使えなかった）
run_generator() {
    podman container exists "$CONTAINER_NAME" || die "${CONTAINER_NAME} が無い．先に $0 start を実行すること．"
    # host.containers.internal が未定義な環境（Linux ネイティブ等）では --add-host で補う
    container_host_args
    podman build -q -t "$GENERATOR_IMAGE" "$SCRIPT_DIR/generator" >/dev/null
    podman run --rm \
        ${CONTAINER_HOST_ARGS[@]+"${CONTAINER_HOST_ARGS[@]}"} \
        -e S3_ENDPOINT="http://host.containers.internal:${S3_PORT}" \
        -e S3_ACCESS_KEY="$ACCESS_KEY" \
        -e S3_SECRET_KEY="$SECRET_KEY" \
        -e S3_BUCKET="$BUCKET" \
        -e MANIFEST_PATH=/manifest/openmetadata.json \
        -v "$SCRIPT_DIR/openmetadata.json:/manifest/openmetadata.json:ro$(selinux_mount_suffix)" \
        "$GENERATOR_IMAGE" "$@"
}

print_info() {
    echo "  S3 API:   http://localhost:${S3_PORT}（コンテナからは http://host.containers.internal:${S3_PORT}）"
    echo "  Console:  http://localhost:${CONSOLE_PORT}"
    echo "  認証情報: ${ACCESS_KEY} / ${SECRET_KEY}（検証用の固定値）"
    echo "  バケット: s3://${BUCKET}（bronze/orders，silver/orders，gold/daily_sales．dt=2026-11-01〜15）"
}

cmd_load() {
    log_info "parquet を生成して s3://${BUCKET} にアップロードする（既存のオブジェクトは削除して作り直す）．"
    run_generator load
}

cmd_start() {
    env_print_source
    # 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）
    preflight 1024 3
    ensure_minio_image

    log_info "サンプル S3 (MinIO) を起動する．"
    compose up -d || die "compose up に失敗した．"
    wait_http "http://localhost:${S3_PORT}/minio/health/live" "$SAMPLE_S3_START_TIMEOUT" 2 \
        || die "MinIO がタイムアウトまでに応答しなかった．ログを確認すること: $0 logs"

    cmd_load
    log_info "サンプル S3 が起動し，データを投入した．"
    print_info
}

cmd_stop() {
    compose_prepare
    compose down
    log_info "サンプル S3 を停止した（データボリュームは保持）．"
}

cmd_purge() {
    if [ "${FORCE:-0}" != "1" ]; then
        read -r -p "サンプル S3 と sample-s3-data ボリュームを削除する．よろしいか [y/N]: " ans
        [ "$ans" = "y" ] || { echo "中止した"; return 1; }
    fi
    compose_prepare
    compose down -v
    log_info "サンプル S3 とデータボリュームを削除した．"
}

cmd_status() {
    compose_prepare
    echo "=== compose ps ==="
    compose ps
    echo
    if ! curl -fsS -o /dev/null "http://localhost:${S3_PORT}/minio/health/live" 2>/dev/null; then
        echo "${CONTAINER_NAME}: 停止中（ヘルスチェックに応答しない）"
        exit 1
    fi
    echo "${CONTAINER_NAME}: 起動中"
    print_info
    echo
    echo "=== s3://${BUCKET} のオブジェクト ==="
    run_generator list
}

cmd_logs() {
    compose_prepare
    compose logs -f
}

case "${1:-}" in
    start) cmd_start ;;
    load) require_podman; cmd_load ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    purge) cmd_purge ;;
    config) shift; env_print_config "$@" ;;
    *) echo "使い方: $0 {start|load|stop|status|logs|purge|config [--show-secrets]}" >&2; exit 1 ;;
esac
