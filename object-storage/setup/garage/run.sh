#!/usr/bin/env bash
# Garage を単一ノードで起動し，レイアウト設定・キー作成・バケット作成まで行う
# 使い方: ./run.sh {start|stop|status|logs|purge}
#   CONTAINER_RUNTIME=docker ./run.sh start のようにランタイムを切り替えられる（既定は podman）
#   start 完了後，このディレクトリの .garage_env に S3 認証情報を書き出す（source して使う）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${CONTAINER_RUNTIME:-podman}"
NAME="handbook-garage"
IMAGE="${GARAGE_IMAGE:-docker.io/dxflrs/garage:v2.5.0}"
S3_PORT="${GARAGE_S3_PORT:-3900}"
WEB_PORT="${GARAGE_WEB_PORT:-3902}"
ADMIN_PORT="${GARAGE_ADMIN_PORT:-3903}"
CAPACITY="${GARAGE_CAPACITY:-10G}"
KEY_NAME="${GARAGE_KEY_NAME:-handbook-key}"
BUCKET="${GARAGE_BUCKET:-handbook}"
ENV_FILE="$SCRIPT_DIR/.garage_env"

container_exists() { "$RUNTIME" container inspect "$NAME" >/dev/null 2>&1; }
container_running() {
    [ "$("$RUNTIME" container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]
}

# イメージにシェルが無いため，CLI は /garage を直接 exec する
garage() { "$RUNTIME" exec "$NAME" /garage "$@"; }

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
    echo "  S3 API:    http://localhost:$S3_PORT（リージョン: garage）"
    echo "  Admin API: http://localhost:$ADMIN_PORT（Web UI は同梱されない）"
    if [ -f "$ENV_FILE" ]; then
        echo "  認証情報:  source $ENV_FILE で AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY を設定する"
    fi
}

# レイアウト・キー・バケットを冪等に初期化する
init_cluster() {
    # 1. レイアウト: ロール未割り当てのときだけ割り当てて適用する（新規ボリュームならバージョン1）
    local status_output
    status_output="$(garage status 2>/dev/null)"
    if echo "$status_output" | grep -qE "NO ROLE ASSIGNED|pending\.\.\."; then
        if echo "$status_output" | grep -q "NO ROLE ASSIGNED"; then
            # node id は <hash>@<addr> 形式なので hash 部分のみ使う
            local node_id
            node_id="$(garage node id -q | awk -F@ '{print $1}')"
            echo "ノードID: $node_id"
            garage layout assign -z dc1 -c "$CAPACITY" "$node_id"
        fi
        # 割り当て済みで未適用（pending...）の場合も適用する
        garage layout apply --version 1
        echo "クラスタレイアウトを適用した"
    else
        echo "レイアウトは設定済み（スキップ）"
    fi

    # 2. キー: 既存ならシークレットを再表示し，無ければ作成する
    local key_output
    if garage key info "$KEY_NAME" >/dev/null 2>&1; then
        key_output="$(garage key info --show-secret "$KEY_NAME")"
    else
        key_output="$(garage key create "$KEY_NAME")"
    fi
    local access_key secret_key
    access_key="$(echo "$key_output" | awk '/^Key ID:/ {print $NF}')"
    secret_key="$(echo "$key_output" | awk '/^Secret key:/ {print $NF}')"
    if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
        echo "$key_output"
        echo "エラー: キー情報の解析に失敗した．上の出力から手動で設定する" >&2
        return 1
    fi

    # 3. バケット: 無ければ作成し，キーに読み書き権限を付与する（allow は再実行しても問題ない）
    if ! garage bucket info "$BUCKET" >/dev/null 2>&1; then
        garage bucket create "$BUCKET"
    fi
    garage bucket allow --read --write --owner "$BUCKET" --key "$KEY_NAME" >/dev/null

    cat > "$ENV_FILE" <<EOF
export AWS_ACCESS_KEY_ID="$access_key"
export AWS_SECRET_ACCESS_KEY="$secret_key"
export AWS_DEFAULT_REGION="garage"
export AWS_ENDPOINT_URL="http://localhost:$S3_PORT"
EOF
    chmod 600 "$ENV_FILE"
    echo "キー $KEY_NAME とバケット $BUCKET を用意した（認証情報: $ENV_FILE）"
}

cmd_start() {
    if container_running; then
        echo "$NAME は起動済み"
    elif container_exists; then
        "$RUNTIME" start "$NAME" >/dev/null
    else
        "$RUNTIME" run -d \
            --name "$NAME" \
            -p "$S3_PORT:3900" \
            -p "$WEB_PORT:3902" \
            -p "$ADMIN_PORT:3903" \
            -v "$SCRIPT_DIR/garage.toml:/etc/garage.toml:ro" \
            -v "${NAME}-meta:/var/lib/garage/meta" \
            -v "${NAME}-data:/var/lib/garage/data" \
            "$IMAGE" /garage server >/dev/null
    fi
    echo "Garage 起動待機中..."
    wait_until "Garage の起動" garage status
    init_cluster
    echo "Garage 準備完了"
    print_info
}

cmd_stop() {
    if container_exists; then
        # データはボリュームに残す
        "$RUNTIME" rm -f "$NAME" >/dev/null
        echo "$NAME を停止・削除した（ボリューム ${NAME}-meta / ${NAME}-data は保持）"
    else
        echo "$NAME は存在しない"
    fi
}

cmd_status() {
    if container_running; then
        echo "$NAME: 起動中"
        garage status
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
        read -r -p "$NAME とボリューム ${NAME}-meta / ${NAME}-data を削除する．よろしいか [y/N]: " ans
        [ "$ans" = "y" ] || { echo "中止した"; return 1; }
    fi
    cmd_stop
    "$RUNTIME" volume rm "${NAME}-meta" "${NAME}-data" >/dev/null 2>&1 && echo "ボリュームを削除した" || true
    rm -f "$ENV_FILE"
}

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    purge) cmd_purge ;;
    *) echo "使い方: $0 {start|stop|status|logs|purge}" >&2; exit 1 ;;
esac
