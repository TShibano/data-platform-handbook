# 各製品の run.sh から source する，起動設定（.env）の読み込み処理
#
# 使い方（run.sh 側）:
#   . "$SCRIPT_DIR/../lib/env.sh"
#   env_load "$SCRIPT_DIR"                         # .env（または ENV_FILE）を解析する
#   env_var MINIO_S3_PORT 9000                     # 実際に使う値を決め，出所を記録する
#   env_var MINIO_ROOT_PASSWORD minioadmin secret  # config 表示でマスクする
#   env_print_config                               # config サブコマンド用の一覧表示
#   env_secret "$MINIO_ROOT_PASSWORD"              # 秘密値を表示用にマスクする（start / status 用）
#
# 優先順位は docker compose / podman-compose と揃える:
#   シェルで明示的に与えた環境変数 > .env（ENV_FILE） > スクリプトの既定値
# compose の ${VAR:-default} と同じく，空文字列は未設定として扱う．
#
# .env は source せず，KEY=VALUE 行として解析する．
#   - source すると任意のコードが実行され，既存の環境変数も上書きしてしまうため
#   - 解析した値はいったん内部変数に保持し，env_var で宣言された変数にだけ反映する．
#     .env に NAME や PATH 等を書いても run.sh 内部の変数は壊れない
# 対応する書式: 空行，# から始まるコメント行，先頭の export，'...' / "..." のクォート，
# クォートしない値の後ろの「 #」以降のコメント．値の中の ${VAR} 展開やエスケープは扱わない．
# bash 3.2（macOS 標準）でも動くよう，連想配列や [[ -v ]] は使わない．

# 読み込んだ env ファイルのパス（無ければ空）
ENV_FILE_LOADED=""
# env_var で宣言した変数名（config 表示の順序）
ENV_DECLARED=()
# env ファイルに書かれていた変数名
ENV_FILE_KEYS=()
# compose.yaml だけが使う変数名（config で「未使用」の注意を出さない）
ENV_COMPOSE_ONLY=()
# 1 なら秘密値をマスクせずに表示する（config --show-secrets で立てる）
ENV_SHOW_SECRETS=0

# 前後の空白を除く
_env_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# env ファイルを解析する．引数はスクリプトのディレクトリ
#   ENV_FILE 未指定: <スクリプトのディレクトリ>/.env を読む（無ければ既定値で動く）
#   ENV_FILE 指定:   そのファイルを読む（相対パスはカレントディレクトリ基準．無ければエラー）
env_load() {
    local script_dir="$1" file
    if [ -n "${ENV_FILE:-}" ]; then
        file="$ENV_FILE"
        if [ ! -f "$file" ]; then
            echo "エラー: ENV_FILE=$file が見つからない" >&2
            exit 1
        fi
    else
        file="$script_dir/.env"
        [ -f "$file" ] || return 0
    fi
    file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
    ENV_FILE_LOADED="$file"

    local line key value lineno=0 q rest
    # 最終行に改行が無くても読めるようにする
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="$(_env_trim "${line%$'\r'}")"
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in export[[:space:]]*) line="$(_env_trim "${line#export}")" ;; esac
        case "$line" in
            *=*) ;;
            *) echo "警告: $file:$lineno: KEY=VALUE 形式ではないので無視する" >&2; continue ;;
        esac
        key="$(_env_trim "${line%%=*}")"
        value="$(_env_trim "${line#*=}")"
        if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "警告: $file:$lineno: 変数名 '$key' が不正なので無視する" >&2
            continue
        fi
        q="${value:0:1}"
        if [ "$q" = "'" ] || [ "$q" = '"' ]; then
            # クォート: 閉じクォートまでを値とし，その後ろ（コメント等）は捨てる
            rest="${value:1}"
            case "$rest" in
                *"$q"*) value="${rest%%"$q"*}" ;;
                *) echo "警告: $file:$lineno: クォートが閉じていないので無視する" >&2; continue ;;
            esac
        else
            # クォート無し: 「空白 + #」以降はコメント
            value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"
        fi
        ENV_FILE_KEYS+=("$key")
        printf -v "__ENV_FILE_$key" '%s' "$value"
    done < "$file"
}

# 変数を宣言し，実際に使う値を決める: env_var <名前> <既定値> [secret]
#   環境変数（空でない） > env ファイルの値（空でない） > 既定値
env_var() {
    local name="$1" default="$2" kind="${3:-}" f="__ENV_FILE_$1" origin
    ENV_DECLARED+=("$name")
    [ "$kind" = "secret" ] && printf -v "__ENV_SECRET_$name" '%s' 1
    if [ -n "${!name:-}" ]; then
        origin=env
    elif [ -n "${!f:-}" ]; then
        printf -v "$name" '%s' "${!f}"
        origin=file
    else
        printf -v "$name" '%s' "$default"
        origin=default
    fi
    printf -v "__ENV_ORIGIN_$name" '%s' "$origin"
}

# compose.yaml だけが使う変数を宣言する: env_compose_only <名前>...
env_compose_only() { ENV_COMPOSE_ONLY+=("$@"); }

# 相対パスを基準ディレクトリからの絶対パスにする（compose がプロジェクトディレクトリ基準で解決するのに合わせる）
env_abs_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$2" "${1#./}" ;;
    esac
}

# 読み込んだ env ファイルを1行で表示する（start / config で使う）
env_print_source() {
    if [ -n "$ENV_FILE_LOADED" ]; then
        echo "設定ファイル: $ENV_FILE_LOADED"
    else
        echo "設定ファイル: なし（既定値と環境変数のみ）"
    fi
}

# 秘密値を表示用に整形する: env_secret <値>
#   既定は「****（文字数）」．ENV_SHOW_SECRETS=1（config --show-secrets）のときだけ平文
#   端末のスクロールバックやログに秘密値を残さないため，start / status の表示もこれを通す
env_secret() {
    if [ "$ENV_SHOW_SECRETS" = "1" ]; then
        printf '%s' "$1"
    else
        printf '****（%s文字）' "${#1}"
    fi
}

# config サブコマンド: 実際に使われる値と出所を表示する（secret はマスク）
#   引数に --show-secrets を与えると secret も平文で表示する
env_print_config() {
    case "${1:-}" in
        '') ;;
        --show-secrets) ENV_SHOW_SECRETS=1 ;;
        *) echo "使い方: config [--show-secrets]" >&2; exit 1 ;;
    esac
    env_print_source
    echo "出所: env=シェルの環境変数，file=設定ファイル，default=run.sh の既定値"
    local name value o s
    for name in ${ENV_DECLARED[@]+"${ENV_DECLARED[@]}"}; do
        value="${!name}"
        s="__ENV_SECRET_$name"
        [ -n "${!s:-}" ] && value="$(env_secret "$value")"
        o="__ENV_ORIGIN_$name"
        printf '  %-28s %-10s %s\n' "$name" "[${!o}]" "$value"
    done
    # env ファイルにあるが run.sh が使わない変数（compose 専用か，綴り間違い）
    local key d found
    for key in ${ENV_FILE_KEYS[@]+"${ENV_FILE_KEYS[@]}"}; do
        found=0
        for d in ${ENV_DECLARED[@]+"${ENV_DECLARED[@]}"}; do
            [ "$d" = "$key" ] && { found=1; break; }
        done
        for d in ${ENV_COMPOSE_ONLY[@]+"${ENV_COMPOSE_ONLY[@]}"}; do
            [ "$d" = "$key" ] && { found=2; break; }
        done
        case "$found" in
            0) echo "  注意: $key は run.sh でも compose.yaml でも使わない（綴り間違いの可能性）" ;;
            2) echo "  参考: $key は compose.yaml 専用（run.sh では使わない）" ;;
        esac
    done
    if [ "$ENV_SHOW_SECRETS" != "1" ]; then
        echo "（秘密値を平文で見るには: $0 config --show-secrets）"
    fi
}
