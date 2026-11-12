# S3互換オブジェクトストレージの起動手順

S3互換オブジェクトストレージ5製品（MinIO / AIStor / RustFS / Garage / SeaweedFS）を，ローカルの単一ノード構成で起動するための設定とスクリプトをまとめる．
各製品とも `compose.yaml`（`docker compose` / `podman compose` 両対応）と `run.sh`（`docker run` 相当のシェルスクリプト）の2通りで起動できる．

- 情報の確認日: 2026-11-12（各製品の出典は各ディレクトリの README に記載）
- 動作実績: `../benchmark/scripts/` のベンチマーク用スクリプト（Podman, macOS, Apple Silicon）をもとにしている．ただし本ディレクトリの設定そのものは実起動での検証をしていない
- ホストポートは製品ごとにずらしてあり，5製品を同時に起動できる

## 製品比較

| 製品 | ライセンス | イメージ:タグ | S3 API | Web UI | 既定の認証情報 | 単一ノード起動 |
|---|---|---|---|---|---|---|
| [MinIO](minio/) | AGPL-3.0 | `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z`（コミュニティフォーク） | 9000 | あり（9001） | `minioadmin` / `minioadmin` | 可 |
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

いずれも環境変数で変更できる（変数名は各 README を参照）．
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

# スクリプト（既定は podman．docker を使う場合は CONTAINER_RUNTIME=docker）
./run.sh start
./run.sh status
./run.sh logs
./run.sh stop                # 停止・コンテナ削除（データは残る）
./run.sh purge               # コンテナとボリュームを削除（確認あり．FORCE=1 で確認省略）
```

compose と run.sh は同じコンテナ名・同じボリューム名（`handbook-<製品名>-data` など）を使うため，どちらで起動しても同じデータを参照する．ただし同時には起動できない（コンテナ名が衝突する）．

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

- `minio/mc` リポジトリも GitHub 上でアーカイブ済み（2026-11-12 確認）で，ホスト側への `mc` の入手方法（Homebrew 等で現在も入手できるか）は要確認．`pgsty/minio` イメージには `mcli`（`mc` 互換エイリアスあり）が同梱されているので，`podman exec handbook-minio mcli ...` でも試せる
- Garage では `mc alias set` の後，リージョンを `garage` にする必要がある場合がある（要確認）

## ディレクトリ構成

```
setup/
  README.md          # このファイル
  minio/             # README.md, compose.yaml, run.sh
  aistor/            # README.md, compose.yaml, run.sh（ライセンスファイル minio.license は各自配置）
  rustfs/            # README.md, compose.yaml, run.sh
  garage/            # README.md, compose.yaml, garage.toml, run.sh
  seaweedfs/         # README.md, compose.yaml, s3.json, run.sh
```
