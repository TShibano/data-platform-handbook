#!/usr/bin/env bash
# SeaweedFS を weed mini（全コンポーネントを1プロセスに同梱）で起動・停止する
# 使い方: ./run.sh {start|stop|status|logs|purge|config [--show-secrets]}
#   設定は同じディレクトリの .env で与える（cp .env.example .env して編集する．無ければ既定値）．
#   別ファイルは ENV_FILE=.env.bench ./run.sh start のように指定する．
#   優先順位: シェルの環境変数 > .env > 既定値（config で実際の値と出所を確認できる）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/env.sh"
env_load "$SCRIPT_DIR"

# 既定値は .env.example と compose.yaml に揃える
env_var CONTAINER_RUNTIME podman
env_var SEAWEEDFS_IMAGE docker.io/chrislusf/seaweedfs:4.53
env_var SEAWEEDFS_S3_PORT 8333
env_var SEAWEEDFS_ADMIN_PORT 12535
env_var SEAWEEDFS_MASTER_PORT 9333
env_var SEAWEEDFS_FILER_PORT 8888
# 管理UIはパスワード未設定だとコンテナ内の 127.0.0.1 にしかバインドされないため必ず指定する
env_var SEAWEEDFS_ADMIN_PASSWORD admin secret
# S3 の認証情報は s3.json で定義する（相対パスはこのディレクトリ基準）
env_var SEAWEEDFS_S3_CONFIG ./s3.json
# s3.json の ${SEAWEEDFS_S3_ACCESS_KEY} / ${SEAWEEDFS_S3_SECRET_KEY} を置き換える値．
# 同名の環境変数としてコンテナに渡し，SeaweedFS が s3.json の読み込み時に展開する
env_var SEAWEEDFS_S3_ACCESS_KEY handbook-access-key
env_var SEAWEEDFS_S3_SECRET_KEY handbook-secret-key-change-me secret

RUNTIME="$CONTAINER_RUNTIME"
NAME="handbook-seaweedfs"
VOLUME="${NAME}-data"
IMAGE="$SEAWEEDFS_IMAGE"
S3_PORT="$SEAWEEDFS_S3_PORT"
ADMIN_PORT="$SEAWEEDFS_ADMIN_PORT"
MASTER_PORT="$SEAWEEDFS_MASTER_PORT"
FILER_PORT="$SEAWEEDFS_FILER_PORT"
ADMIN_PASSWORD="$SEAWEEDFS_ADMIN_PASSWORD"
S3_CONFIG="$(env_abs_path "$SEAWEEDFS_S3_CONFIG" "$SCRIPT_DIR")"
S3_ACCESS_KEY="$SEAWEEDFS_S3_ACCESS_KEY"
S3_SECRET_KEY="$SEAWEEDFS_S3_SECRET_KEY"

container_exists() { "$RUNTIME" container inspect "$NAME" >/dev/null 2>&1; }
container_running() {
    [ "$("$RUNTIME" container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]
}

# 既存コンテナが SEAWEEDFS_S3_ACCESS_KEY を環境変数として持つか（s3.json のキーを ${VAR} 参照にしたため，持たないコンテナでは認証情報が捨てられ全 S3 リクエストが拒否される）
check_container_env() {
    container_exists || return 0
    # grep -q へのパイプは pipefail 下で SIGPIPE を失敗と誤判定し得るため，変数に受けて case で調べる
    local env_list
    env_list="$("$RUNTIME" container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME")"
    case $'\n'"$env_list" in
        *$'\n'SEAWEEDFS_S3_ACCESS_KEY=*) return 0 ;;
    esac
    {
        echo "エラー: 既存のコンテナ $NAME は秘密値を環境変数で渡す前の run.sh / compose で作られている．"
        echo "  このままでは s3.json の \${SEAWEEDFS_S3_ACCESS_KEY} 等が解決できず，全 S3 リクエストが拒否される．"
        echo "  ./run.sh stop && ./run.sh start でコンテナを作り直す（ボリュームのデータは残る）"
    } >&2
    exit 1
}

# 指定コマンドが成功するまで最大60秒待つ
wait_until() {
    local desc="$1"; shift
    for _ in $(seq 1 60); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "タイムアウト: ${desc}（$RUNTIME logs $NAME で確認する）" >&2
    return 1
}

print_info() {
    # 秘密値はマスクする（平文は ./run.sh config --show-secrets）
    echo "  S3 API:    http://localhost:${S3_PORT}（$S3_ACCESS_KEY / $(env_secret "$S3_SECRET_KEY")．定義: ${S3_CONFIG}）"
    echo "  管理UI:    http://localhost:${ADMIN_PORT}（admin / $(env_secret "$ADMIN_PASSWORD")）"
    echo "  秘密値の平文: $0 config --show-secrets"
    echo "  Master UI: http://localhost:$MASTER_PORT"
    echo "  Filer UI:  http://localhost:$FILER_PORT"
}

cmd_start() {
    env_print_source
    check_container_env
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
            -p "$S3_PORT:8333" \
            -p "$ADMIN_PORT:12535" \
            -p "$MASTER_PORT:9333" \
            -p "$FILER_PORT:8888" \
            -e SEAWEEDFS_S3_ACCESS_KEY="$S3_ACCESS_KEY" \
            -e SEAWEEDFS_S3_SECRET_KEY="$S3_SECRET_KEY" \
            -v "$S3_CONFIG:/config/s3.json:ro" \
            -v "$VOLUME:/data" \
            "$IMAGE" mini \
            -dir=/data \
            -s3.config=/config/s3.json \
            -admin.password="$ADMIN_PASSWORD" >/dev/null
    fi
    echo "SeaweedFS 起動待機中..."
    # master が応答してもボリュームサーバ登録前は PUT が失敗するため，書き込み先を割り当てられるまで待つ
    wait_until "ボリュームの準備" sh -c "curl -s 'http://localhost:$MASTER_PORT/dir/assign' | grep -q '\"fid\"'"
    # S3 API は master より遅れて起動するため個別に待つ（未認証アクセスは 403 になるので応答の有無だけ見る）
    wait_until "S3 API の起動" curl -s -o /dev/null "http://localhost:$S3_PORT"
    echo "SeaweedFS 準備完了"
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
        check_container_env
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
    config) shift; env_print_config "$@" ;;
    *) echo "使い方: $0 {start|stop|status|logs|purge|config [--show-secrets]}" >&2; exit 1 ;;
esac
