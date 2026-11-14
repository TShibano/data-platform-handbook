#!/usr/bin/env bash
# インジェスト対象のサンプル DB（PostgreSQL）を起動・停止する
# 使い方: ./run.sh {start|stop|status|logs|purge|config [--show-secrets]}
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
env_var SAMPLE_DB_IMAGE docker.io/library/postgres:16-alpine
env_var SAMPLE_DB_START_TIMEOUT 120
export SAMPLE_DB_IMAGE

# 接続情報は検証用の固定値で秘密ではない（compose.yaml と各ツールの recipe に同じ値を書いている）
CONTAINER_NAME="sample_postgres"
DB_USER="sample_user"
DB_PASSWORD="sample_password"
DB_NAME="sampledb"
DB_PORT=5432

compose() {
    local env_args=()
    [ -n "$ENV_FILE_LOADED" ] && env_args=(--env-file "$ENV_FILE_LOADED")
    (cd "$SCRIPT_DIR" && "${COMPOSE_CMD[@]}" ${env_args[@]+"${env_args[@]}"} -f compose.yaml "$@")
}

compose_prepare() {
    require_podman
    compose_cmd
}

psql_exec() { podman exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" "$@"; }

print_info() {
    echo "  接続情報: postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"
    echo "  コンテナからは host.containers.internal:${DB_PORT} で到達できる想定"
}

cmd_start() {
    env_print_source
    # 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）
    preflight 2048 2

    log_info "サンプル DB (postgres) を起動する．"
    compose up -d || die "compose up に失敗した．"

    # --- 初期化 SQL の完了を待つ ---
    # postgres の公式イメージは /docker-entrypoint-initdb.d/ 配下の .sql を
    # ファイル名順に実行してから接続を受け付ける．pg_isready が通っても
    # 初期化 SQL の実行中は接続を拒否するため，実際に SELECT が通るまでを
    # もって完了とみなす．
    local interval=3 elapsed=0 ready=0
    log_info "初期化 SQL の完了を待機する（タイムアウト ${SAMPLE_DB_START_TIMEOUT}秒）．"
    while [ "$elapsed" -lt "$SAMPLE_DB_START_TIMEOUT" ]; do
        if psql_exec -c 'SELECT 1;' >/dev/null 2>&1; then
            ready=1
            break
        fi
        log_info "待機中...（${elapsed}/${SAMPLE_DB_START_TIMEOUT}秒）"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    if [ "$ready" -ne 1 ]; then
        log_error "タイムアウトまでに SELECT が通らなかった．"
        die "ログを確認すること: $0 logs"
    fi
    log_info "SELECT 1 が通った．初期化 SQL 完了を確認．"

    check_data
    log_info "サンプル DB が起動し，SELECT で検証済み．"
    print_info
}

# テーブル / ビュー一覧と，集約ビューに実データが入っているかを確認する
check_data() {
    echo "=== テーブル / ビュー一覧 ==="
    psql_exec -c '\dt+' -c '\dv+'
    echo

    local summary_count details_count
    summary_count="$(psql_exec -tAc 'SELECT count(*) FROM customer_order_summary;')"
    details_count="$(psql_exec -tAc 'SELECT count(*) FROM order_details;')"
    echo "=== 投入データ件数 ==="
    echo "  customer_order_summary: ${summary_count} 行"
    echo "  order_details:          ${details_count} 行"
    echo

    if [ "$summary_count" -lt 1 ] || [ "$details_count" -lt 1 ]; then
        die "ビューに想定したデータが入っていない．初期化 SQL を確認すること（初期化 SQL は初回しか流れないため，作り直すなら $0 purge）．"
    fi
}

cmd_stop() {
    compose_prepare
    compose down
    log_info "サンプル DB を停止した（データボリュームは保持）．"
}

cmd_purge() {
    if [ "${FORCE:-0}" != "1" ]; then
        read -r -p "サンプル DB と sample-pg-data ボリュームを削除する．よろしいか [y/N]: " ans
        [ "$ans" = "y" ] || { echo "中止した"; return 1; }
    fi
    compose_prepare
    compose down -v
    log_info "サンプル DB とデータボリュームを削除した．"
}

cmd_status() {
    compose_prepare
    echo "=== compose ps ==="
    compose ps
    echo
    if psql_exec -c 'SELECT 1;' >/dev/null 2>&1; then
        echo "$CONTAINER_NAME: 起動中（SELECT 1 が通る）"
        print_info
    else
        echo "$CONTAINER_NAME: 停止中または初期化中（SELECT 1 が通らない）"
        exit 1
    fi
}

cmd_logs() {
    compose_prepare
    compose logs -f
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
