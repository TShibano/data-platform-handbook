#!/usr/bin/env bash
# DataHub のスタックを起動・停止し，サンプル DB をインジェストする
# 使い方: ./run.sh {start|stop|status|logs [service...]|purge|ingest|fetch-compose [--force]|config [--show-secrets]}
#   設定は同じディレクトリの .env で与える（cp .env.example .env して編集する．無ければ既定値）．
#   別ファイルは ENV_FILE=.env.bench ./run.sh start のように指定する．
#   優先順位: シェルの環境変数 > .env > 既定値（config で実際の値と出所を確認できる）
#   スタック自体は compose が起動する（upstream + override を重ねる）．run.sh はそのラッパー
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../lib/env.sh"
# preflight.sh は common.sh も読み込む
. "$SCRIPT_DIR/../lib/preflight.sh"
env_load "$SCRIPT_DIR"

# 既定値は .env.example に揃える
env_var DATAHUB_ALT_PORTS 0
# upstream compose の ${VAR} 置換に使う変数（export して compose に渡す）．
# DATAHUB_VERSION はイメージタグなので v 接頭辞付き（v なしだと manifest unknown で pull に失敗する）
env_var DATAHUB_VERSION v1.7.0
env_var UI_INGESTION_DEFAULT_CLI_VERSION 1.7.0
env_var DATAHUB_TOKEN_SERVICE_SALT local-lab-not-a-secret-salt-9f2c7a1d secret
env_var DATAHUB_TOKEN_SERVICE_SIGNING_KEY local-lab-not-a-secret-signing-key-3e81b4c0 secret
env_var DATAHUB_START_TIMEOUT 900
# .env に書いた upstream compose の変数は --env-file で compose に渡るので，config で注意を出さない
env_compose_only $(compose_file_vars "$SCRIPT_DIR/compose.upstream.yml")

# シェルの環境変数は compose の --env-file より優先されるため，run.sh が決めた値がそのまま効く
export DATAHUB_VERSION UI_INGESTION_DEFAULT_CLI_VERSION DATAHUB_TOKEN_SERVICE_SALT DATAHUB_TOKEN_SERVICE_SIGNING_KEY

# --- 固定値（.env では変えない） ---
# upstream compose の取得元（git タグなので v は URL 側で付ける）．
# バージョンを上げるときは fetch-compose --force で取り直してコミットする．
# 上の DATAHUB_VERSION / UI_INGESTION_DEFAULT_CLI_VERSION と Containerfile.ingestion の pip のバージョンも揃えること．
DATAHUB_RELEASE=1.7.0
DATAHUB_COMPOSE_URL="https://raw.githubusercontent.com/datahub-project/datahub/v${DATAHUB_RELEASE}/docker/quickstart/docker-compose.quickstart-profile.yml"
# frontend-quickstart の UI ポートは compose.override.yml にリテラルで書いてあり，
# compose.altports.yml でも変えない（OpenMetadata と衝突しないため）
UI_PORT=9002
# preflight の要求メモリ（MiB）とディスク（GB）．7 サービス構成で OpenMetadata より大きい
REQUIRED_MEM_MIB=8192
REQUIRED_DISK_GB=13
INGESTION_IMAGE_TAG="dh-ingestion:local"
RECIPE_NAME="postgres_to_datahub.yml"
UPSTREAM_COMPOSE="$SCRIPT_DIR/compose.upstream.yml"

case "$DATAHUB_ALT_PORTS" in
    0|1) ;;
    *) die "DATAHUB_ALT_PORTS は 0 か 1 で指定すること（現在: $DATAHUB_ALT_PORTS）" ;;
esac

# DataHub の upstream compose は全サービスに profiles: が付いており，
# --profile を指定しないとサービスが 1 つも起動しない．
# quickstart プロファイルで 7 サービスすべてが対象になる．
#
# compose に渡す -f 引数．DATAHUB_ALT_PORTS=1 のときだけ compose.altports.yml
# （OpenMetadata と同時起動する際のポートずらし）を 3 枚目として重ねる．
# 同時に，ホスト側から到達するときの GMS ポートもここで決める．
# compose.altports.yml 側でポート番号を変えたら，ここも合わせて変えること．
COMPOSE_FILES=(--profile quickstart -f compose.upstream.yml -f compose.override.yml)
GMS_PORT=8080
if [ "$DATAHUB_ALT_PORTS" = "1" ]; then
    COMPOSE_FILES+=(-f compose.altports.yml)
    GMS_PORT=28080
fi
UI_URL="http://localhost:${UI_PORT}"
GMS_URL="http://localhost:${GMS_PORT}"

# compose を呼ぶ．読み込んだ設定ファイルがあれば --env-file で同じものを渡す
# （ENV_FILE=.env.bench のときに compose が別の .env を読まないようにするため）
compose() {
    local env_args=()
    [ -n "$ENV_FILE_LOADED" ] && env_args=(--env-file "$ENV_FILE_LOADED")
    (cd "$SCRIPT_DIR" && "${COMPOSE_CMD[@]}" ${env_args[@]+"${env_args[@]}"} "${COMPOSE_FILES[@]}" "$@")
}

# start 以外で compose を使う前の準備（preflight はリソース確認まで含むので start だけで行う）
compose_prepare() {
    require_podman
    compose_cmd
}

ensure_upstream_compose() {
    if [ ! -f "$UPSTREAM_COMPOSE" ]; then
        log_info "compose.upstream.yml が無いので取得する．"
        fetch_upstream_compose "$DATAHUB_COMPOSE_URL" "$UPSTREAM_COMPOSE"
    fi
}

# upstream compose の bind mount 先ディレクトリを作る．
# podman-compose 1.6.0 は bind mount の create_host_path を尊重するとは限らないため，
# 事前に mkdir -p しておくのが安全．
#
# ${HOME}/.datahub/plugins と ${HOME}/.datahub/search は DataHub 専用のディレクトリ
# なので無条件に作成する（公式の `datahub docker quickstart` も同様に作成する）．
#
# 一方 ${HOME}/.aws は DataHub 専用ではなく AWS CLI 等が使う汎用ディレクトリのため，
# 存在しない環境で本リポジトリが勝手に作るのは避ける．
# 既に ${HOME}/.aws があるときだけ ${HOME}/.aws/sso/cache を補って作る．
# ${HOME}/.aws が無い場合は作らずに warn だけ出す
# （datahub-actions-quickstart コンテナの起動に失敗する可能性があるが，
#  他サービスには影響しない見込み．失敗した場合は必要に応じて
#  手動で `mkdir -p ~/.aws/sso/cache` するか，datahub-actions-quickstart を
#  対象から外して調査すること）．
ensure_host_dirs() {
    mkdir -p "${HOME}/.datahub/plugins"
    mkdir -p "${HOME}/.datahub/search"

    # SELinux enforcing のディストリでは，再ラベルしていない bind mount を
    # コンテナから読めない．upstream compose の bind mount に `:z` を付ける手段が
    # ないため（compose.override.yml のコメント参照），ホスト側のディレクトリを
    # 直接ラベル付けする．chcon は自分の所有ファイルに対してなら root 不要．
    if selinux_enforcing; then
        if command -v chcon >/dev/null 2>&1; then
            log_info "SELinux enforcing を検出．${HOME}/.datahub を container_file_t にラベル付けする．"
            if ! chcon -Rt container_file_t "${HOME}/.datahub" 2>/dev/null; then
                log_warn "${HOME}/.datahub の再ラベルに失敗した．コンテナが plugins/search を読めない場合は次を手で実行すること．
  chcon -Rt container_file_t ${HOME}/.datahub"
            fi
        else
            log_warn "SELinux enforcing だが chcon が見つからない．コンテナが ${HOME}/.datahub を読めない可能性がある．"
        fi
    fi

    if [ -d "${HOME}/.aws" ]; then
        mkdir -p "${HOME}/.aws/sso/cache"
    else
        log_warn "${HOME}/.aws が存在しないため作成しない（datahub-actions-quickstart 用の bind mount 対象だが，汎用ディレクトリを本リポジトリの都合で新規作成するのは避ける方針）．"
        log_warn "datahub-actions-quickstart の起動に失敗する場合は $0 logs datahub-actions-quickstart で確認すること．"
    fi
}

print_info() {
    echo "  UI: $UI_URL"
    echo "  初期ログイン: datahub / datahub"
    echo "  GMS: $GMS_URL"
    if [ "$DATAHUB_ALT_PORTS" = "1" ]; then
        echo "  DATAHUB_ALT_PORTS=1: mysql 23306，opensearch 29200，gms 28080"
    else
        echo "  mysql 3306，opensearch 9200，kafka 9092"
    fi
}

# start はスタックを起動するだけでサンプル DB は取り込まないため，次の手順を案内する
print_next_steps() {
    echo "次の手順: サンプル DB を取り込むには $0 ingest"
    echo "  （サンプル DB が未起動なら先に $(cd "$SCRIPT_DIR/../sample-db" && pwd)/run.sh start）"
}

cmd_start() {
    env_print_source
    # 前提チェック（podman / compose provider / 依存コマンド / メモリ・ディスク）
    preflight "$REQUIRED_MEM_MIB" "$REQUIRED_DISK_GB"
    ensure_upstream_compose
    ensure_host_dirs
    if [ "$DATAHUB_ALT_PORTS" = "1" ]; then
        log_info "DATAHUB_ALT_PORTS=1: compose.altports.yml を重ねる（mysql/opensearch/gms のポートをずらす）．"
    fi

    log_info "DataHub スタックを起動する（初回はイメージ pull とシステム更新ジョブで数分かかる．OpenMetadata より起動が遅い）．"
    if ! compose up -d; then
        die "compose up に失敗した．ログを確認すること: $0 logs"
    fi

    # DataHub は system-update-quickstart の完了待ちなどがあり OpenMetadata より
    # 起動が遅いため，タイムアウトを長めに取る．
    if wait_http "$UI_URL" "$DATAHUB_START_TIMEOUT" 5; then
        log_info "DataHub が起動した．"
        print_info
        print_next_steps
    else
        log_error "$UI_URL がタイムアウトまでに応答しなかった．"
        log_error "状態確認: $0 status"
        log_error "ログ確認: $0 logs [service]"
        exit 1
    fi
}

cmd_stop() {
    compose_prepare
    compose down
    log_info "DataHub スタックを停止した（データボリュームは保持）．"
}

cmd_purge() {
    if [ "${FORCE:-0}" != "1" ]; then
        read -r -p "DataHub スタックと mysql / opensearch / kafka-broker のデータボリューム（mysqldata / osdata / broker）を削除する．よろしいか [y/N]: " ans
        [ "$ans" = "y" ] || { echo "中止した"; return 1; }
    fi
    compose_prepare
    compose down -v
    log_info "DataHub スタックとデータボリュームを削除した．"
}

# 独立したテストスイートは作らない方針のため，検証はここに埋め込む
cmd_status() {
    compose_prepare

    echo "=== compose ps ==="
    compose ps
    echo

    # upstream compose は container_name を明示していないため，
    # podman-compose が自動採番したコンテナ名（<project>_<service>_1 等）を
    # 決め打ちにせず，compose が付与するラベル（com.docker.compose.service）で
    # 実際のコンテナ名を引く．
    # healthcheck が定義されているのは upstream 上で次の 4 つ．
    echo "=== ヘルスチェック ==="
    local all_healthy=1 svc cname health
    for svc in datahub-gms-quickstart kafka-broker mysql opensearch; do
        cname="$(podman ps -a --filter "label=com.docker.compose.service=${svc}" --format '{{.Names}}' | head -n1)"
        if [ -z "$cname" ]; then
            echo "  $svc: コンテナが見つからない"
            all_healthy=0
            continue
        fi
        health="$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}(healthcheck定義なし){{end}}' "$cname" 2>/dev/null || echo "(取得失敗)")"
        echo "  $svc ($cname): $health"
        if [ "$health" != "healthy" ] && [ "$health" != "(healthcheck定義なし)" ]; then
            all_healthy=0
        fi
    done
    echo

    # GMS のヘルスエンドポイントは upstream の healthcheck 定義
    # （curl http://datahub-gms:8080/health）に合わせて /health を使う．
    local gms_health_url="${GMS_URL}/health"
    local ui_ok=0 gms_ok=0 code
    echo "=== 到達確認 ==="
    code="$(curl -s -o /dev/null -w '%{http_code}' "$UI_URL" 2>/dev/null || true)"
    case "$code" in
        2??|3??) echo "  UI ($UI_URL): OK (HTTP $code)"; ui_ok=1 ;;
        *) echo "  UI ($UI_URL): NG (HTTP ${code:-N/A})" ;;
    esac
    code="$(curl -s -o /dev/null -w '%{http_code}' "$gms_health_url" 2>/dev/null || true)"
    case "$code" in
        2??|3??) echo "  GMS health ($gms_health_url): OK (HTTP $code)"; gms_ok=1 ;;
        *) echo "  GMS health ($gms_health_url): NG (HTTP ${code:-N/A})" ;;
    esac
    echo

    echo "=== まとめ ==="
    if [ "$all_healthy" -eq 1 ] && [ "$ui_ok" -eq 1 ] && [ "$gms_ok" -eq 1 ]; then
        echo "  DataHub は正常に稼働している．"
        print_info
    else
        echo "  異常あり．詳細は上記の各項目を確認すること．ログ: $0 logs"
        exit 1
    fi
}

# 引数省略時は全サービス．
# service: mysql / opensearch / kafka-broker / system-update-quickstart /
#          datahub-gms-quickstart / frontend-quickstart / datahub-actions-quickstart
cmd_logs() {
    compose_prepare
    compose logs -f "$@"
}

# サンプル DB (../sample-db) を DataHub へインジェストし，結果を API で検証する．
# 1. Containerfile.ingestion をビルド
# 2. recipe (configs/recipes/postgres_to_datahub.yml) でインジェストを実行
# 3. GMS の API で結果（検索・リネージ）を検証
# 前提: このスタックと ../sample-db の両方が起動していること．
#
# OpenMetadata と異なり，DataHub の quickstart GMS は既定で認証を要求しない
# （ローカル検証環境のため未認証で到達できる）．そのため JWT 等のトークン取得は不要．
cmd_ingest() {
    require_podman

    # Linux ネイティブ向けの補正．SELinux enforcing なら bind mount を再ラベルし，
    # host.containers.internal が未定義な環境では --add-host で補う．
    # machine モード（macOS 等）ではどちらも空になる．
    local mount_suffix
    mount_suffix="$(selinux_mount_suffix)"
    container_host_args

    # --- 0. 前提の到達確認 ---
    log_info "DataHub GMS への到達を確認する．"
    if ! curl -fsS -o /dev/null "${GMS_URL}/health"; then
        die "DataHub GMS (${GMS_URL}) に到達できない．先に $0 start を実行すること（DATAHUB_ALT_PORTS は start 時と揃える）．"
    fi

    log_info "サンプル DB (postgres) への到達を確認する．"
    if ! podman exec sample_postgres psql -U sample_user -d sampledb -c 'SELECT 1;' >/dev/null 2>&1; then
        die "サンプル DB に到達できない．先に ../sample-db/run.sh start を実行すること．"
    fi

    # --- 1. イメージビルド ---
    # ビルドコンテキストはこのディレクトリ（Containerfile が configs/ を COPY する）
    log_info "Containerfile.ingestion をビルドする．"
    podman build -f "$SCRIPT_DIR/Containerfile.ingestion" -t "$INGESTION_IMAGE_TAG" "$SCRIPT_DIR"

    # --- 2. recipe の一時コピーに GMS ポートを埋め込む ---
    # configs/recipes/${RECIPE_NAME} はどのポートでも動くよう REPLACE_WITH_GMS_PORT
    # というプレースホルダのままコミットしている．実際のポート（既定 8080 /
    # DATAHUB_ALT_PORTS=1 なら 28080）は起動設定で決まるため，ここで
    # 一時ファイルへ sed 置換してからマウントする
    # （OpenMetadata 側で jwtToken を埋め込むのと同じ方式）．
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    sed "s#REPLACE_WITH_GMS_PORT#${GMS_PORT}#" \
        "$SCRIPT_DIR/configs/recipes/${RECIPE_NAME}" > "$TMP_DIR/${RECIPE_NAME}"
    chmod 600 "$TMP_DIR/${RECIPE_NAME}"

    # --- 3. インジェスト実行 ---
    # DATAHUB_TELEMETRY_ENABLED=false: acryl-datahub は既定で終了時に利用統計を
    # track.datahubproject.io へ送ろうとし，このホストがサンドボックスから
    # 到達できないため接続タイムアウトのリトライで無駄に待たされる
    # （実機で確認済み）．検証環境として外部送信も避けたいので無効化する．
    log_info "recipe (${RECIPE_NAME}, GMS ポート ${GMS_PORT}) でインジェストを実行する．"
    if ! podman run --rm \
        ${CONTAINER_HOST_ARGS[@]+"${CONTAINER_HOST_ARGS[@]}"} \
        -e DATAHUB_TELEMETRY_ENABLED=false \
        -v "$TMP_DIR/${RECIPE_NAME}:/opt/ingestion/configs/recipes/${RECIPE_NAME}:ro${mount_suffix}" \
        "$INGESTION_IMAGE_TAG" ingest -c "/opt/ingestion/configs/recipes/${RECIPE_NAME}"; then
        die "インジェストに失敗した．"
    fi

    # --- 4. API で結果を検証する ---
    log_info "検索 API で customers データセットがヒットするか確認する．"
    local search_ok=0 search_result hit_count search_pretty
    for _ in 1 2 3 4 5; do
        search_result="$(curl -fsS -X POST "${GMS_URL}/entities?action=search" \
            -H 'Content-Type: application/json' \
            -d '{"input":"customers","entity":"dataset","start":0,"count":10}')"
        hit_count="$(printf '%s' "$search_result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("value",{}).get("numEntities",0))')"
        if [ "$hit_count" -gt 0 ]; then
            search_ok=1
            break
        fi
        sleep 3
    done

    # json.tool を head に直結すると SIGPIPE で pipefail に引っかかることがあるため，
    # いったん変数に確定してから切り詰める（OpenMetadata 側と同じ）．
    search_pretty="$(printf '%s' "$search_result" | python3 -m json.tool)"
    echo "=== 検索 API: q=customers ==="
    printf '%s\n' "$search_pretty" | head -40 || true
    echo

    [ "$search_ok" -eq 1 ] || die "検索 API で customers がヒットしなかった．"
    log_info "検索 API で customers がヒットした（${hit_count} 件）．"

    log_info "リネージ API で customer_order_summary の上流を確認する（upstreamLineage aspect）．"
    local view_urn="urn:li:dataset:(urn:li:dataPlatform:postgres,sampledb.public.customer_order_summary,PROD)"
    local view_urn_enc lineage_result upstream_count
    view_urn_enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$view_urn")"
    lineage_result="$(curl -fsS "${GMS_URL}/aspects/${view_urn_enc}?aspect=upstreamLineage&version=0")"

    echo "=== リネージ API: ${view_urn} ==="
    printf '%s\n' "$lineage_result" | python3 -m json.tool
    echo

    upstream_count="$(printf '%s' "$lineage_result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("aspect",{}).get("com.linkedin.dataset.UpstreamLineage",{}).get("upstreams",[])))')"
    if [ "$upstream_count" -lt 1 ]; then
        die "customer_order_summary の上流リネージが 1 件も取れなかった．"
    fi
    log_info "customer_order_summary の上流に ${upstream_count} 件のデータセットを確認した．"

    log_info "インジェストと検証が完了した．"
}

cmd_fetch_compose() {
    local force=0
    case "${1:-}" in
        '') ;;
        --force) force=1 ;;
        *) echo "使い方: $0 fetch-compose [--force]" >&2; exit 1 ;;
    esac
    fetch_upstream_compose "$DATAHUB_COMPOSE_URL" "$UPSTREAM_COMPOSE" "$force"
}

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    logs) shift; cmd_logs "$@" ;;
    purge) cmd_purge ;;
    ingest) cmd_ingest ;;
    fetch-compose) shift; cmd_fetch_compose "$@" ;;
    config) shift; env_print_config "$@" ;;
    *) echo "使い方: $0 {start|stop|status|logs [service...]|purge|ingest|fetch-compose [--force]|config [--show-secrets]}" >&2; exit 1 ;;
esac
