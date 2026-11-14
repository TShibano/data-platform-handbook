#!/usr/bin/env bash
# OpenMetadata のスタックを起動・停止し，サンプル DB をインジェストする
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
env_var OM_ALT_PORTS 0
# upstream compose の ${VAR} 置換に使う変数（export して compose に渡す）
env_var OPENMETADATA_DB_IMAGE docker.io/openmetadata/db:2.0.1
env_var OPENMETADATA_SERVER_IMAGE docker.io/openmetadata/server:2.0.1
env_var OPENMETADATA_INGESTION_IMAGE docker.io/openmetadata/ingestion:2.0.1
# ingest が ingestion-bot の JWT を取るためにログインする管理者
env_var OM_ADMIN_EMAIL admin@open-metadata.org
env_var OM_ADMIN_PASSWORD admin secret
env_var OM_START_TIMEOUT 600
# .env に書いた upstream compose の変数は --env-file で compose に渡るので，config で注意を出さない
env_compose_only $(compose_file_vars "$SCRIPT_DIR/compose.upstream.yml")

# シェルの環境変数は compose の --env-file より優先されるため，run.sh が決めた値がそのまま効く
export OPENMETADATA_DB_IMAGE OPENMETADATA_SERVER_IMAGE OPENMETADATA_INGESTION_IMAGE

# --- 固定値（.env では変えない） ---
# upstream compose の取得元．バージョンを上げるときは fetch-compose --force で取り直してコミットする．
# 上の OPENMETADATA_*_IMAGE と Containerfile.ingestion の FROM / pip のバージョンも揃えること．
OM_RELEASE=2.0.1
OM_COMPOSE_URL="https://github.com/open-metadata/OpenMetadata/releases/download/${OM_RELEASE}-release/docker-compose.yml"
# openmetadata-server のポートは compose.override.yml にリテラルで書いてあり，
# compose.altports.yml でも変えない（DataHub と衝突しないため）
UI_PORT=8585
ADMIN_PORT=8586
# preflight の要求メモリ（MiB）とディスク（GB）
REQUIRED_MEM_MIB=6144
REQUIRED_DISK_GB=13
INGESTION_IMAGE_TAG="om-ingestion:local"
UPSTREAM_COMPOSE="$SCRIPT_DIR/compose.upstream.yml"
OM_BASE_URL="http://localhost:${UI_PORT}"

# --- 期待値定数（../sample-db/sample-data/01_schema.sql の内容に対応） ---
# public スキーマのテーブル総数．
# テーブル: customers / orders / order_items（3）
# ビュー  : order_details / customer_order_summary（2）
EXPECTED_PUBLIC_TABLES=5
# customer_order_summary は customers / orders / order_items の 3 テーブルを
# 直接 JOIN・集約したビュー（01_schema.sql 参照）．上流エッジは 3 件になるはず．
EXPECTED_UPSTREAM_EDGES=3

case "$OM_ALT_PORTS" in
    0|1) ;;
    *) die "OM_ALT_PORTS は 0 か 1 で指定すること（現在: ${OM_ALT_PORTS}）" ;;
esac

# compose に渡す -f 引数．OM_ALT_PORTS=1 のときだけ compose.altports.yml
# （DataHub と同時起動する際のポートずらし）を 3 枚目として重ねる
COMPOSE_FILES=(-f compose.upstream.yml -f compose.override.yml)
if [ "$OM_ALT_PORTS" = "1" ]; then
    COMPOSE_FILES+=(-f compose.altports.yml)
fi

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
        fetch_upstream_compose "$OM_COMPOSE_URL" "$UPSTREAM_COMPOSE"
    fi
}

print_info() {
    echo "  UI: $OM_BASE_URL"
    echo "  初期ログイン: $OM_ADMIN_EMAIL / $(env_secret "$OM_ADMIN_PASSWORD")（平文: $0 config --show-secrets）"
    if [ "$OM_ALT_PORTS" = "1" ]; then
        echo "  OM_ALT_PORTS=1: mysql 13306，elasticsearch 19200/19300，ingestion (Airflow) 18080"
    else
        echo "  mysql 3306，elasticsearch 9200/9300，ingestion (Airflow) 8080"
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
    if [ "$OM_ALT_PORTS" = "1" ]; then
        log_info "OM_ALT_PORTS=1: compose.altports.yml を重ねる（mysql/elasticsearch/ingestion のポートをずらす）．"
    fi

    log_info "OpenMetadata スタックを起動する（初回はイメージ pull とマイグレーションで数分かかる）．"
    if ! compose up -d; then
        die "compose up に失敗した．ログを確認すること: $0 logs"
    fi

    if wait_http "$OM_BASE_URL" "$OM_START_TIMEOUT" 5; then
        log_info "OpenMetadata が起動した．"
        print_info
        print_next_steps
    else
        log_error "$OM_BASE_URL がタイムアウトまでに応答しなかった．"
        log_error "状態確認: $0 status"
        log_error "ログ確認: $0 logs [service]"
        exit 1
    fi
}

cmd_stop() {
    compose_prepare
    compose down
    log_info "OpenMetadata スタックを停止した（データボリュームは保持）．"
}

cmd_purge() {
    if [ "${FORCE:-0}" != "1" ]; then
        read -r -p "OpenMetadata スタックと mysql (openmetadata_db / airflow_db)・elasticsearch のデータボリュームを削除する．よろしいか [y/N]: " ans
        [ "$ans" = "y" ] || { echo "中止した"; return 1; }
    fi
    compose_prepare
    compose down -v
    log_info "OpenMetadata スタックとデータボリュームを削除した．"
}

# 独立したテストスイートは作らない方針のため，検証はここに埋め込む
cmd_status() {
    compose_prepare

    echo "=== compose ps ==="
    compose ps
    echo

    # healthcheck が定義されているコンテナのヘルス状態を見る．
    # container_name は upstream compose の値と一致させる．
    echo "=== ヘルスチェック ==="
    local all_healthy=1 c health
    for c in openmetadata_mysql openmetadata_elasticsearch openmetadata_server; do
        if ! podman container exists "$c" 2>/dev/null; then
            echo "  $c: コンテナが存在しない"
            all_healthy=0
            continue
        fi
        health="$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}(healthcheck定義なし){{end}}' "$c" 2>/dev/null || echo "(取得失敗)")"
        echo "  $c: $health"
        if [ "$health" != "healthy" ] && [ "$health" != "(healthcheck定義なし)" ]; then
            all_healthy=0
        fi
    done
    echo

    local admin_url="http://localhost:${ADMIN_PORT}/healthcheck"
    local ui_ok=0 admin_ok=0 code
    echo "=== 到達確認 ==="
    code="$(curl -s -o /dev/null -w '%{http_code}' "$OM_BASE_URL" 2>/dev/null || true)"
    case "$code" in
        2??|3??) echo "  UI ($OM_BASE_URL): OK (HTTP $code)"; ui_ok=1 ;;
        *) echo "  UI ($OM_BASE_URL): NG (HTTP ${code:-N/A})" ;;
    esac
    code="$(curl -s -o /dev/null -w '%{http_code}' "$admin_url" 2>/dev/null || true)"
    case "$code" in
        2??|3??) echo "  admin healthcheck ($admin_url): OK (HTTP $code)"; admin_ok=1 ;;
        *) echo "  admin healthcheck ($admin_url): NG (HTTP ${code:-N/A})" ;;
    esac
    echo

    echo "=== まとめ ==="
    if [ "$all_healthy" -eq 1 ] && [ "$ui_ok" -eq 1 ] && [ "$admin_ok" -eq 1 ]; then
        echo "  OpenMetadata は正常に稼働している．"
        print_info
    else
        echo "  異常あり．詳細は上記の各項目を確認すること．ログ: $0 logs"
        exit 1
    fi
}

# 引数省略時は全サービス．
# service: mysql / elasticsearch / execute-migrate-all / openmetadata-server / ingestion
cmd_logs() {
    compose_prepare
    compose logs -f "$@"
}

# サンプル DB (../sample-db) を OpenMetadata へインジェストし，結果を API で検証する．
# 1. Containerfile.ingestion をビルド
# 2. ingestion-bot の JWT を API から動的に取得
# 3. メタデータインジェスト（テーブル・ビュー・コメント）を実行
# 4. リネージインジェスト（view -> table のリネージ）を実行
# 5. 検索 API とリネージ API で結果を検証
# 前提: このスタックと ../sample-db の両方が起動していること．
cmd_ingest() {
    require_podman

    # Linux ネイティブ向けの補正．SELinux enforcing なら bind mount を再ラベルし，
    # host.containers.internal が未定義な環境では --add-host で補う．
    # machine モード（macOS 等）ではどちらも空になる．
    local mount_suffix
    mount_suffix="$(selinux_mount_suffix)"
    container_host_args

    # --- 0. 前提の到達確認 ---
    log_info "OpenMetadata サーバへの到達を確認する．"
    if ! curl -fsS -o /dev/null "${OM_BASE_URL}/api/v1/system/version"; then
        die "OpenMetadata サーバ (${OM_BASE_URL}) に到達できない．先に $0 start を実行すること．"
    fi

    log_info "サンプル DB (postgres) への到達を確認する．"
    if ! podman exec sample_postgres psql -U sample_user -d sampledb -c 'SELECT 1;' >/dev/null 2>&1; then
        die "サンプル DB に到達できない．先に ../sample-db/run.sh start を実行すること．"
    fi

    # --- 1. イメージビルド ---
    # ビルドコンテキストはこのディレクトリ（Containerfile が configs/ を COPY する）
    log_info "Containerfile.ingestion をビルドする．"
    podman build -f "$SCRIPT_DIR/Containerfile.ingestion" -t "$INGESTION_IMAGE_TAG" "$SCRIPT_DIR"

    # --- 2. ingestion-bot の JWT を API から動的に取得する ---
    # OpenMetadata は初期セットアップ時に ingestion-bot 用の JWT を自動生成して
    # 保持しており，GET /users/token/{id} でいつでも取得し直せる（既定では
    # 有効期限なし＝Unlimited）．この値は「公開されている既定値」ではなく，
    # このデプロイ固有にサーバが生成した値なのでログに出力しない．
    #
    # 管理者ログインは OM_ADMIN_EMAIL / OM_ADMIN_PASSWORD を使う（既定は OpenMetadata の
    # 初期値 admin@open-metadata.org / admin．password は API 仕様上 base64 で渡す）．
    log_info "管理者 ($OM_ADMIN_EMAIL) でログインしてアクセストークンを取得する．"
    local password_b64 login_body login_response admin_token bot_id bot_jwt
    password_b64="$(printf '%s' "$OM_ADMIN_PASSWORD" | base64)"
    # メールアドレスとパスワードを JSON 文字列として安全に埋め込む
    login_body="$(python3 -c 'import json,sys; print(json.dumps({"email": sys.argv[1], "password": sys.argv[2]}))' "$OM_ADMIN_EMAIL" "$password_b64")"
    login_response="$(curl -fsS -X POST "${OM_BASE_URL}/api/v1/users/login" \
        -H 'Content-Type: application/json' \
        -d "$login_body")" || die "管理者ログインに失敗した．OM_ADMIN_EMAIL / OM_ADMIN_PASSWORD を確認すること（$0 config）．"
    admin_token="$(printf '%s' "$login_response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')"
    [ -n "$admin_token" ] || die "管理者のアクセストークン取得に失敗した．"

    log_info "ingestion-bot のユーザ ID を取得する．"
    bot_id="$(curl -fsS "${OM_BASE_URL}/api/v1/users/name/ingestion-bot" \
        -H "Authorization: Bearer ${admin_token}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    [ -n "$bot_id" ] || die "ingestion-bot のユーザ ID 取得に失敗した．"

    log_info "ingestion-bot の JWT を取得する（GET /users/token/{id}）．"
    bot_jwt="$(curl -fsS "${OM_BASE_URL}/api/v1/users/token/${bot_id}" \
        -H "Authorization: Bearer ${admin_token}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["JWTToken"])')"
    [ -n "$bot_jwt" ] || die "ingestion-bot の JWT 取得に失敗した．"
    log_info "JWT 取得完了（値はログに出さない）．"

    # --- 3. recipe の一時コピーにトークンを埋め込む ---
    # configs/ingestion/*.yaml のプレースホルダはリポジトリにコミットする値であり
    # 秘密ではない．実際のトークンはここで一時ファイルに書き出し，終了時に削除する．
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    local f
    for f in postgres_metadata.yaml postgres_lineage.yaml; do
        sed "s#REPLACE_WITH_INGESTION_BOT_JWT#${bot_jwt}#" \
            "$SCRIPT_DIR/configs/ingestion/$f" > "$TMP_DIR/$f"
    done
    chmod 600 "$TMP_DIR"/*.yaml

    # --- 4. メタデータインジェスト ---
    log_info "メタデータインジェストを実行する（テーブル・ビュー・コメント）．"
    if ! podman run --rm \
        ${CONTAINER_HOST_ARGS[@]+"${CONTAINER_HOST_ARGS[@]}"} \
        -v "$TMP_DIR/postgres_metadata.yaml:/opt/ingestion/configs/ingestion/postgres_metadata.yaml:ro${mount_suffix}" \
        "$INGESTION_IMAGE_TAG" ingest -c /opt/ingestion/configs/ingestion/postgres_metadata.yaml; then
        die "メタデータインジェストに失敗した．"
    fi

    # --- 5. リネージインジェスト ---
    # postgres_lineage.yaml は source.type: postgres-lineage を使っており，
    # これも `metadata ingest`（MetadataWorkflow）で実行する．
    # `metadata lineage` サブコマンドは別物（1 本の生 SQL を指定サービスに対して
    # 手動でリネージ登録する ad-hoc コマンド）で，今回のような
    # DatabaseServiceQueryLineagePipeline recipe の実行には使わない
    # （実機で試して WorkflowInitErrorHandler のエラーになることを確認済み）．
    log_info "リネージインジェストを実行する（view -> table のリネージ）．"
    if ! podman run --rm \
        ${CONTAINER_HOST_ARGS[@]+"${CONTAINER_HOST_ARGS[@]}"} \
        -v "$TMP_DIR/postgres_lineage.yaml:/opt/ingestion/configs/ingestion/postgres_lineage.yaml:ro${mount_suffix}" \
        "$INGESTION_IMAGE_TAG" ingest -c /opt/ingestion/configs/ingestion/postgres_lineage.yaml; then
        die "リネージインジェストに失敗した．"
    fi

    # --- 6. API で結果を検証する ---

    # schemaFilterPattern（public 限定）が効いているかを件数一致で確認する．
    # 以前は「1 件以上ヒットすれば OK」という緩い判定だったため，
    # information_schema まで丸ごと取り込まれていても検知できなかった．
    log_info "public スキーマのテーブル総数を確認する．"
    local tables_result tables_total table_names
    tables_result="$(curl -fsS "${OM_BASE_URL}/api/v1/tables?databaseSchema=sample_postgres.sampledb.public&limit=100" \
        -H "Authorization: Bearer ${admin_token}")"
    tables_total="$(printf '%s' "$tables_result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["paging"]["total"])')"
    table_names="$(printf '%s' "$tables_result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join(sorted(t["name"] for t in d["data"])))')"
    if [ "$tables_total" -ne "$EXPECTED_PUBLIC_TABLES" ]; then
        die "public スキーマのテーブル総数が期待値と一致しない（期待: ${EXPECTED_PUBLIC_TABLES}，実測: ${tables_total}）．schemaFilterPattern の設定を確認すること．"
    fi
    log_info "public スキーマのテーブル総数は期待どおり ${tables_total} 件（${table_names}）．"

    # sample_postgres サービス（sample_postgres.sampledb データベース）配下に
    # information_schema のスキーマが取り込まれていないことを確認する．
    log_info "sample_postgres 配下に information_schema が存在しないことを確認する．"
    local schemas_result
    schemas_result="$(curl -fsS "${OM_BASE_URL}/api/v1/databaseSchemas?database=sample_postgres.sampledb&limit=100" \
        -H "Authorization: Bearer ${admin_token}")"
    if printf '%s' "$schemas_result" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(s["name"] == "information_schema" for s in d["data"]) else 1)'; then
        die "sample_postgres 配下に information_schema が残っている．schemaFilterPattern の設定を確認すること．"
    fi
    log_info "sample_postgres 配下に information_schema は存在しない．"

    # 検索インデックスへの反映がわずかに遅れることがあるため軽くリトライする．
    # ここは「customers がヒットするか」という存在確認のみで，件数自体は
    # トークナイズやスコアリングの都合で環境依存に揺れうるため厳密一致はさせない．
    log_info "検索 API で customers テーブルがヒットするか確認する．"
    local search_ok=0 search_result hit_count search_pretty
    for _ in 1 2 3 4 5; do
        search_result="$(curl -fsS "${OM_BASE_URL}/api/v1/search/query?q=customers&index=table_search_index" \
            -H "Authorization: Bearer ${admin_token}")"
        hit_count="$(printf '%s' "$search_result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hits",{}).get("total",{}).get("value",0))')"
        if [ "$hit_count" -gt 0 ]; then
            search_ok=1
            break
        fi
        sleep 3
    done

    # json.tool の出力を先に変数へ確定してから head で切り詰める．
    # python3 -m json.tool を head に直結すると，head が先に読み終えてパイプを
    # 閉じた際に python3 が SIGPIPE を受けて非 0 終了し，pipefail 経由で
    # スクリプト全体が異常終了することがある（実機で確認済み）．
    search_pretty="$(printf '%s' "$search_result" | python3 -m json.tool)"
    echo "=== 検索 API: q=customers ==="
    printf '%s\n' "$search_pretty" | head -60 || true
    echo

    [ "$search_ok" -eq 1 ] || die "検索 API で customers がヒットしなかった．"
    log_info "検索 API で customers がヒットした（${hit_count} 件）．"

    log_info "リネージ API で customer_order_summary の上流を確認する．"
    local view_fqn="sample_postgres.sampledb.public.customer_order_summary"
    local lineage_result upstream_count
    lineage_result="$(curl -fsS "${OM_BASE_URL}/api/v1/lineage/table/name/${view_fqn}?upstreamDepth=2&downstreamDepth=1" \
        -H "Authorization: Bearer ${admin_token}")"

    echo "=== リネージ API: ${view_fqn} ==="
    printf '%s\n' "$lineage_result" | python3 -m json.tool
    echo

    upstream_count="$(printf '%s' "$lineage_result" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("upstreamEdges", [])))')"
    if [ "$upstream_count" -ne "$EXPECTED_UPSTREAM_EDGES" ]; then
        die "customer_order_summary の上流エッジ数が期待値と一致しない（期待: ${EXPECTED_UPSTREAM_EDGES}，実測: ${upstream_count}）．"
    fi
    log_info "customer_order_summary の上流に期待どおり ${upstream_count} 件のエッジを確認した．"

    log_info "インジェストと検証が完了した．"
}

cmd_fetch_compose() {
    local force=0
    case "${1:-}" in
        '') ;;
        --force) force=1 ;;
        *) echo "使い方: $0 fetch-compose [--force]" >&2; exit 1 ;;
    esac
    fetch_upstream_compose "$OM_COMPOSE_URL" "$UPSTREAM_COMPOSE" "$force"
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
