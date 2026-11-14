# データカタログツールの起動手順

データカタログツール2製品（OpenMetadata / DataHub）と，インジェスト対象のサンプル DB を，Podman 上のローカル環境で起動するための設定とスクリプトをまとめる．
各ディレクトリの `run.sh` で起動・停止・インジェストを行い，起動設定は `.env` で与える．

- 動作実績: 2026-09-05 に macOS（Apple Silicon，podman machine）で両ツールの起動・インジェスト・API 検証をした（結果は [../evaluation/docs/comparison.md](../evaluation/docs/comparison.md)）．その後 `run.sh` と `.env` の方式へ書き換えたが，書き換え後に実起動まで確認したのはサンプル DB だけで，両ツールは compose の解決結果（`compose config`）までの確認に留まる（2026-11-14）
- 両ツールはポートとメモリを取り合うため，同時には起動しない（[同時起動](#同時起動)）
- object-storage の各製品とはホストポートが重ならない

## 製品比較

| 製品 | ライセンス | バージョン | UI | 初期ログイン | 要求メモリ（preflight） | サービス数 |
|---|---|---|---|---|---|---|
| [OpenMetadata](openmetadata/) | Apache-2.0 | 2.0.1（`docker.io/openmetadata/*:2.0.1`） | 8585 | `admin@open-metadata.org` / `admin` | 6GB | 5（mysql，elasticsearch，マイグレーション，server，ingestion=Airflow） |
| [DataHub](datahub/) | Apache-2.0 | 1.7.0（`acryldata/*:v1.7.0`） | 9002 | `datahub` / `datahub` | 8GB | 7（mysql，opensearch，kafka，system-update，gms，frontend，actions） |
| [サンプル DB](sample-db/) | PostgreSQL License | `docker.io/library/postgres:16-alpine` | - | `sample_user` / `sample_password`（検証用固定値） | 2GB | 1 |

機能面の比較は [../evaluation/docs/comparison.md](../evaluation/docs/comparison.md) にまとめている．

### ホストポート割当

| 製品 | ポート |
|---|---|
| OpenMetadata | 8585（UI / API），8586（管理），3306（mysql），9200 / 9300（elasticsearch），8080（ingestion=Airflow） |
| DataHub | 9002（UI），8080（GMS），4319，3306（mysql），9200（opensearch），9092（kafka） |
| サンプル DB | 5432 |

OpenMetadata と DataHub は 3306 / 9200 / 8080 が衝突する．ポート番号は `.env` では変えられない（各 `compose.override.yml` の `ports: !override` にリテラルで書いてある．podman-compose 1.6.0 が `!override` タグの中の `${VAR}` を展開しないため）．

## 構成

```
setup/
├── README.md
├── lib/                    # 各 run.sh から source する共通処理
│   ├── env.sh              #   .env の読み込み（object-storage/setup/lib/env.sh の複製）
│   ├── common.sh           #   ログ・podman / compose の検出・upstream compose の取得
│   └── preflight.sh        #   起動前の前提チェック（単体でも実行できる）
├── openmetadata/
│   ├── run.sh
│   ├── .env.example
│   ├── compose.upstream.yml    # 公式配布の compose（バイト列を変えずにコミット）
│   ├── compose.override.yml    # 本リポジトリ向けの上書き（ポート・ボリューム・メモリ）
│   ├── compose.altports.yml    # 同時起動用にポートをずらす上書き（*_ALT_PORTS=1 のときだけ重ねる）
│   ├── Containerfile.ingestion # インジェスト用の拡張イメージ（公式イメージを FROM）
│   └── configs/                # インジェスト定義
├── datahub/                # openmetadata/ と同じ形
└── sample-db/              # インジェスト対象の PostgreSQL（compose.yaml・初期化 SQL）
```

スタックの起動は compose が担い，`run.sh` はその薄いラッパーにしている．object-storage と違い，両ツールは複数サービスの構成で `docker run` 相当を書くのは現実的でないため．Containerfile は公式イメージを `FROM` する拡張レイヤ（インジェスト用）に専念させる．

## 前提環境

- [Podman](https://podman.io/) **4.7 以上**
  （rootless で `host.containers.internal` を解決できる版．インジェストがサンプル DB へ到達するのに要る）
- [podman-compose](https://github.com/containers/podman-compose) **1.6.0 以上**，
  または `docker compose` **2.24 以上**（compose ファイルの `!override` タグを解釈できる版）
- `curl` / `python3` / `base64`（起動待機・インジェスト結果の検証に使う）
- podman machine のメモリ: OpenMetadata は 6GB，DataHub は 8GB 以上（不足していると `start` が止まり，変更コマンドを案内する）

ディストリ同梱の podman / podman-compose は上記より古いことがある．
前提を満たしているかは次で確認できる（各 `run.sh start` も起動前に同じ検査をする）．

```sh
./lib/preflight.sh [要求メモリMiB] [要求ディスクGB]
```

コンテナランタイムは podman のみ対応（object-storage と違い `CONTAINER_RUNTIME=docker` は無い）．`podman exec` / `podman build` / `podman machine` を前提にしているため．

### 対応 OS

| 実行環境 | 対応 |
| --- | --- |
| macOS（`podman machine` 経由） | 対応．検証済み |
| Linux ネイティブ（rootless / rootful） | 対応 |
| Windows + WSL2（ディストリの中に Podman を入れる） | 対応．Linux ネイティブと同じ扱い |
| Windows + Podman Desktop（`podman machine`） | 対応．macOS と同じ扱い |
| Windows ネイティブ（Git Bash / MSYS2 / PowerShell） | **非対応** |

スクリプトは `podman machine` の有無で振る舞いを変える．OS 名では判定しない．

**Windows では WSL2 のディストリの中で実行すること．** Git Bash や MSYS2 から
直接動かすとパス変換で `podman run` のマウント指定が壊れるため対象外とし，
`preflight` が明示的にエラーで止める．

補足: rootless かつ cgroup v1 の環境では compose の `mem_limit` が無視される
（podman が警告を出して続行する）．メモリを取り合って OOM しやすくなるため，
cgroup v2 の環境を推奨する．

## 起動・停止

典型的な流れは「サンプル DB 起動 → 比較したいツールを起動 → インジェスト → 確認 → 停止」．

```bash
./sample-db/run.sh start        # インジェスト対象の DB．どちらのツールを試す場合も先に起動する

cd openmetadata                 # DataHub なら cd datahub
./run.sh start                  # 起動し，UI が応答するまで待つ（初回は数分）
./run.sh ingest                 # サンプル DB を取り込み，検索・リネージ API で結果を検証する
./run.sh status                 # コンテナのヘルスと UI / API への到達を確認する
./run.sh logs [service...]      # ログを追う（省略時は全サービス）
./run.sh config                 # 実際に使われる設定値と出所を表示する（秘密値はマスク）
./run.sh config --show-secrets  # 秘密値も平文で表示する
./run.sh stop                   # 停止（データはボリュームに残る）
./run.sh purge                  # 停止してボリュームも削除（確認あり．FORCE=1 で確認省略）
./run.sh fetch-compose [--force]  # compose.upstream.yml を公式から取り直す（バージョンを上げるとき）
```

サンプル DB の `run.sh` は `start|stop|status|logs|purge|config` のみ．`podman compose up -d` でも起動できる（`.env` も読む）．

OpenMetadata / DataHub は compose ファイルを3枚重ねて起動するため，compose を直接使わず `run.sh` 経由で操作する．

### 同時起動

両ツールは 3306 / 9200 / 8080 で衝突し，メモリも合計 14GB を超えるため，同時には起動しない．
どうしても同時に起動したい場合は，`.env` に `OM_ALT_PORTS=1` / `DATAHUB_ALT_PORTS=1` を書くと `compose.altports.yml` を重ねてポートをずらす（ずらし先は各 `.env.example` を参照）．メモリ要求は変わらないため推奨はしない．

## 設定方法（.env）

object-storage/setup と同じ方式（詳細は [object-storage/setup/README.md の「設定方法（.env）」](../../object-storage/setup/README.md#設定方法env)）．

```bash
cd openmetadata
cp .env.example .env         # 全変数が既定値付き・コメント付きで列挙してある
vi .env                      # 変えたい行だけ編集する
./run.sh config              # 実際に使われる値を確認する
./run.sh start
```

- `.env.example` はコミット対象，`.env` は秘密値を含み得るのでコミットしない（`.gitignore` で `*/.env` と `*/.env.*` を除外し，`*/.env.example` だけ戻している）
- `.env` が無ければ既定値で動く（`.env.example` の値と同じ）
- 優先順位: シェルで明示的に与えた環境変数 > `.env`（`ENV_FILE` で指定したファイル） > 既定値
- 別の設定ファイルを使うときは `ENV_FILE=.env.alt ./run.sh start`

### compose への渡し方

data-catalog 固有の点は，`run.sh` が compose のラッパーであること．

- `run.sh` が使う変数のうち upstream compose の `${VAR}` 置換に使うもの（イメージタグ，DataHub のトークン用 salt / signing key）は，`run.sh` が値を決めて `export` する．シェルの環境変数は compose の `--env-file` より優先されるため，`run.sh config` に表示される値がそのまま compose に効く
- 読み込んだ `.env` は `--env-file` で compose にも渡す．そのため `.env.example` に無い upstream compose の変数（OpenMetadata の `SMTP_*` など）も `.env` に書けば効く．`run.sh config` はそれらを「compose.yaml 専用」と表示し，どちらでも使わない変数は綴り間違いの可能性として注意を出す
- 以前の `configs/openmetadata.env` / `configs/datahub.env`（コミット対象の compose 用変数ファイル）は `.env.example` と `run.sh` の既定値に統合した

### 秘密値

| 製品 | `.env` の変数 | 使われ方 | 既定値 |
|---|---|---|---|
| OpenMetadata | `OM_ADMIN_EMAIL` / `OM_ADMIN_PASSWORD` | `run.sh ingest` が ingestion-bot の JWT を取るためのログイン（サーバの初期値を変えるものではない） | `admin@open-metadata.org` / `admin` |
| DataHub | `DATAHUB_TOKEN_SERVICE_SALT` / `DATAHUB_TOKEN_SERVICE_SIGNING_KEY` | 同名の環境変数で GMS などに渡る | ローカル検証用の固定値 |

サンプル DB の接続情報は各ツールのインジェスト定義（`configs/`）にも同じ値を書いているため，`.env` では変えられない．検証用の固定値で秘密ではない．

## サンプル DB

スキーマ・データの内容と，この構成にした理由は [sample-db/README.md](sample-db/README.md) を参照．
