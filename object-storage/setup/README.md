# S3互換オブジェクトストレージの起動手順

S3互換オブジェクトストレージ5製品（MinIO / AIStor / RustFS / Garage / SeaweedFS）を，ローカルの単一ノード構成で起動するための設定とスクリプトをまとめる．
各製品とも `compose.yaml`（`docker compose` / `podman compose` 両対応）と `run.sh`（`docker run` 相当のシェルスクリプト）の2通りで起動できる．

- 情報の確認日: 2026-11-12（各製品の出典は各ディレクトリの README に記載）
- 動作実績: `../benchmark/scripts/` のベンチマーク用スクリプト（Podman, macOS, Apple Silicon）をもとにしている．ただし本ディレクトリの設定そのものは，MinIO（ソースビルド方式，2026-11-13 に Podman で実ビルド・起動・PUT/GET を確認）を除き実起動での検証をしていない
- ホストポートは製品ごとにずらしてあり，5製品を同時に起動できる

## 製品比較

| 製品 | ライセンス | イメージ:タグ | S3 API | Web UI | 既定の認証情報 | 単一ノード起動 |
|---|---|---|---|---|---|---|
| [MinIO](minio/) | AGPL-3.0 | `localhost/handbook-minio:RELEASE.2025-10-15T17-29-55Z`（公式ソース `minio/minio` の最終タグをローカルでビルド） | 9000 | あり（9001） | `minioadmin` / `minioadmin` | 可 |
| [AIStor](aistor/) | 商用（AIStor Free 契約 / Enterprise） | `quay.io/minio/aistor/minio:RELEASE.2026-09-19T17-05-25Z` | 9010 | あり（9011） | `minioadmin` / `minioadmin` | 可（Free は単一ノードのみ．ライセンスファイルが必要） |
| [RustFS](rustfs/) | Apache-2.0 | `docker.io/rustfs/rustfs:1.0.5` | 9020 | あり（9021） | `rustfsadmin` / `rustfsadmin`（本ディレクトリの既定値．公式は変更を強く推奨） | 可 |
| [Garage](garage/) | AGPL-3.0 | `docker.io/dxflrs/garage:v2.5.0` | 3900 | なし（Admin API 3903 のみ） | run.sh: 起動時に生成し `.garage_env` へ出力 / compose: 環境変数で指定 | 可（`replication_factor = 1`） |
| [SeaweedFS](seaweedfs/) | Apache-2.0 | `docker.io/chrislusf/seaweedfs:4.53` | 8333 | あり（管理UI 12535，master 9333，filer 8888） | `s3.json` で定義（`handbook-access-key` / `handbook-secret-key-change-me`） | 可（`weed mini`） |

### ホストポート割当

| 製品 | ポート |
|---|---|
| MinIO | 9000（S3），9001（コンソール） |
| AIStor | 9010（S3），9011（コンソール） |
| RustFS | 9020（S3），9021（コンソール） |
| Garage | 3900（S3），3902（静的 Web 公開），3903（Admin API） |
| SeaweedFS | 8333（S3），12535（管理UI），9333（master），8888（filer） |

いずれも各ディレクトリの `.env` で変更できる（[設定方法（.env）](#設定方法env)，変数名は各ディレクトリの `.env.example` を参照）．
`../benchmark/scripts/` のスクリプトとはコンテナ名（`handbook-*`）は異なるが，MinIO（9000/9001），Garage（3900/3903），SeaweedFS（8333/9333/8888）はホストポートが重なるため，ベンチマーク用コンテナと同時には起動しない．

### 位置付けの要点

- MinIO コミュニティ版は 2026-04-25 に GitHub リポジトリがアーカイブされ，ソース配布のみになった．公式イメージは取得できないため，本手順ではコミュニティフォークのイメージを使う（詳細は [minio/README.md](minio/README.md)）
- AIStor は MinIO 社の商用版．無料の Free tier があるが，単一ノード限定でライセンス登録が必要
- RustFS は Rust 製の MinIO 代替．2026-09 に 1.0 が GA になった
- Garage は地理分散・小規模運用向けの軽量実装．公式の Web UI は無い
- SeaweedFS は分散ファイルシステムに S3 ゲートウェイを載せた構成で，`weed mini` で全コンポーネントを1プロセスで起動できる

## 起動・停止

各ディレクトリで次のどちらかを実行する．

```bash
# compose（docker compose でも同じ）
podman compose up -d
podman compose down          # 停止（データは名前付きボリュームに残る）

# スクリプト（既定は podman．docker を使う場合は .env に CONTAINER_RUNTIME=docker）
./run.sh start
./run.sh config              # 実際に使われる設定値と出所を表示する（パスワード類はマスク）
./run.sh status
./run.sh logs
./run.sh stop                # 停止・コンテナ削除（データは残る）
./run.sh purge               # コンテナとボリュームを削除（確認あり．FORCE=1 で確認省略）
```

compose と run.sh は同じコンテナ名・同じボリューム名（`handbook-<製品名>-data` など）を使うため，どちらで起動しても同じデータを参照する．ただし同時には起動できない（コンテナ名が衝突する）．

## 設定方法（.env）

ポート・認証情報・イメージタグ等の起動設定は，各製品ディレクトリの `.env` に書く．コマンド実行時に `MINIO_S3_PORT=19000 ./run.sh start` のように環境変数を付ける方式だと，後から何を与えて起動したか追えないため，設定をファイルに残す方式にしている．

```bash
cd minio
cp .env.example .env         # 全変数が既定値付き・コメント付きで列挙してある
vi .env                      # 変えたい行だけ編集する
./run.sh config              # 実際に使われる値を確認する
./run.sh start               # または podman compose up -d（--build は MinIO のみ）
```

- `.env.example` はコミット対象，`.env` は認証情報を含み得るのでコミットしない（`.gitignore` で `*/.env` と `*/.env.*` を除外し，`*/.env.example` だけ戻している）
- `.env` が無ければ既定値で動く（`.env.example` の値と同じ）．compose.yaml の `${VAR:-default}` と run.sh の既定値は揃えてある
- 空の値（`KEY=`）は未設定として扱い，既定値になる（compose の `${VAR:-default}` と同じ）

### 優先順位

compose と run.sh で同じ順にしてある．

1. シェルで明示的に与えた環境変数（`MINIO_S3_PORT=19000 ./run.sh start`．一時的に試すとき用）
2. `.env`（`ENV_FILE` で指定したファイル）
3. 既定値

`docker compose` / `podman-compose` はプロジェクトディレクトリ（compose.yaml のあるディレクトリ）の `.env` を自動で読み，シェルの環境変数を優先する．run.sh も同じ挙動になるよう実装している．

### 別の設定ファイルを使う（ENV_FILE）

```bash
cp .env.example .env.bench   # .env.* もコミットされない（.env.example を除く）
ENV_FILE=.env.bench ./run.sh start                # 相対パスはカレントディレクトリ基準．無ければエラー
podman compose --env-file .env.bench up -d        # compose 側は --env-file で指定する
```

### config サブコマンド

`./run.sh config` は，run.sh が実際に使う値と出所（`env`=シェルの環境変数，`file`=設定ファイル，`default`=既定値）を表示する．パスワード・シークレットは `****（文字数）` にマスクする．`.env` に run.sh が使わない変数があれば，compose 専用か綴り間違いかを注意として出す．`start` も最初に読み込んだ設定ファイルのパスを1行表示する．

```
$ MINIO_S3_PORT=19000 ./run.sh config
設定ファイル: /…/object-storage/setup/minio/.env
出所: env=シェルの環境変数，file=設定ファイル，default=run.sh の既定値
  CONTAINER_RUNTIME            [default]  podman
  MINIO_VERSION                [default]  RELEASE.2025-10-15T17-29-55Z
  MINIO_IMAGE                  [default]  localhost/handbook-minio:RELEASE.2025-10-15T17-29-55Z
  MINIO_S3_PORT                [env]      19000
  MINIO_CONSOLE_PORT           [file]     19101
  MINIO_ROOT_USER              [default]  minioadmin
  MINIO_ROOT_PASSWORD          [file]     ****（10文字）
```

compose 側で解決後の値を確認するには `podman compose config`（`docker compose config`）を使う．

### run.sh での読み込み方式

読み込み処理は5製品共通の [lib/env.sh](lib/env.sh) にまとめ，各 run.sh から source している．

- `.env` を `source`（`set -a; . .env`）せず，`KEY=VALUE` 行として解析する．理由は次の2つ
  - `source` は既に設定済みの環境変数を上書きしてしまい，compose と優先順位が逆になる
  - `source` は `.env` に書かれた任意のコマンドを実行してしまう．設定ファイルはデータとして扱いたい
- 解析した値はいったん内部に保持し，run.sh が宣言した変数（`.env.example` に載っている変数）にだけ反映する．`.env` に `PATH` 等を書いても run.sh の動作は変わらない
- 対応する書式: 空行，`#` で始まるコメント行，先頭の `export`，`'...'` / `"..."` のクォート，クォートしない値の後ろの ` # コメント`．値の中の `${VAR}` 展開やエスケープ（`\n` 等）は扱わない（compose は展開するので，両者で結果が変わる書き方は避ける）
- bash 3.2（macOS 標準の `/bin/bash`）で動くようにしている

### コンテナに渡す環境変数

`.env` をコンテナに丸ごと渡す（`--env-file` / compose の `env_file:`）ことはしない．`.env` にはポートやイメージタグなどコンテナに無関係な変数も入っているためで，run.sh は `-e MINIO_ROOT_USER=...` のように，compose は `environment:` で，必要な変数だけを明示的にマッピングしている．

### Garage の `.garage_env` との違い

Garage の run.sh が `start` 時に書き出す `garage/.garage_env` は，Garage が生成した S3 認証情報（`AWS_ACCESS_KEY_ID` 等）の**出力**で，`source garage/.garage_env` してクライアント側で使う．起動設定の**入力**である `.env` とは別物で，`.env` に書いても `.garage_env` の内容は変わらない（`.garage_env` も `.gitignore` で除外している）．

## 共通の動作確認手順

### 接続情報

| 製品 | エンドポイント | アクセスキー / シークレット | リージョン | 備考 |
|---|---|---|---|---|
| MinIO | `http://localhost:9000` | `minioadmin` / `minioadmin` | `us-east-1` | |
| AIStor | `http://localhost:9010` | `minioadmin` / `minioadmin` | `us-east-1` | ライセンス未登録だと S3 操作は全て拒否される |
| RustFS | `http://localhost:9020` | `rustfsadmin` / `rustfsadmin` | `us-east-1` | |
| Garage | `http://localhost:3900` | run.sh: `source garage/.garage_env` / compose: `GKhandbook0000000000000000` / `handbook-garage-secret-change-me` | `garage` | バケット `handbook` は作成済み．run.sh で作ったキーにはバケット作成権限が無いので `mb` は省略する |
| SeaweedFS | `http://localhost:8333` | `handbook-access-key` / `handbook-secret-key-change-me` | `us-east-1`（任意） | |

### AWS CLI

```bash
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin
export AWS_DEFAULT_REGION=us-east-1
# 新しめの AWS CLI / SDK は既定で追加チェックサムを送るため，S3互換製品によっては失敗する．
# 既存ベンチマーク（boto3）でも when_required を指定しているので揃える
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
EP=http://localhost:9000

aws --endpoint-url "$EP" s3 mb s3://handbook
echo "hello object storage" > /tmp/hello.txt
aws --endpoint-url "$EP" s3 cp /tmp/hello.txt s3://handbook/hello.txt   # PUT
aws --endpoint-url "$EP" s3 ls s3://handbook/
aws --endpoint-url "$EP" s3 cp s3://handbook/hello.txt -                # GET（標準出力へ）
```

### MinIO Client（mc）

```bash
mc alias set local-minio http://localhost:9000 minioadmin minioadmin
mc mb local-minio/handbook
mc cp /tmp/hello.txt local-minio/handbook/hello.txt   # PUT
mc ls local-minio/handbook
mc cat local-minio/handbook/hello.txt                 # GET
```

- `minio/mc` リポジトリも GitHub 上でアーカイブ済み（2026-11-12 確認）で，ホスト側への `mc` の入手方法（Homebrew 等で現在も入手できるか）は要確認．MinIO はソースからビルドしたイメージ（`mc` は同梱しない）を使うので，ホスト側の `mc` か AWS CLI（`aws --endpoint-url http://localhost:9000 s3 ...`）を使う
- Garage では `mc alias set` の後，リージョンを `garage` にする必要がある場合がある（要確認）

## ディレクトリ構成

```
setup/
  README.md          # このファイル
  lib/env.sh         # 各 run.sh が source する .env 読み込み処理
  minio/             # README.md, .env.example, compose.yaml, Dockerfile, run.sh
  aistor/            # README.md, .env.example, compose.yaml, run.sh（ライセンスファイル minio.license は各自配置）
  rustfs/            # README.md, .env.example, compose.yaml, run.sh
  garage/            # README.md, .env.example, compose.yaml, garage.toml, run.sh
  seaweedfs/         # README.md, .env.example, compose.yaml, s3.json, run.sh
```

各製品ディレクトリの `.env`（各自が `.env.example` から作る）と `garage/.garage_env`（run.sh の出力）はコミットしない．
