# サンプル S3

OpenMetadata と DataHub に**同じデータレイクを取り込んで比較する**ための，S3 互換オブジェクトストレージ（MinIO）上のサンプルデータ．
[sample-db](../sample-db/) と同じ EC ドメインの注文明細を，メダリオン構成（bronze / silver / gold）の parquet として置く．

このディレクトリだけで完結しており，どちらのツールのスタックとも独立に起動できる．

```
sample-s3/
├── README.md               # 本ファイル
├── run.sh                  # start / load / stop / status / logs / purge / config
├── .env.example            # 起動設定（MinIO のバージョン・待機秒数）
├── compose.yaml            # MinIO の compose 定義
├── openmetadata.json       # OpenMetadata 用マニフェスト（バケット直下にアップロードする）
└── generator/
    ├── Containerfile       # parquet 生成用イメージ（Python 3.13 + polars + boto3）
    └── generate.py         # データ生成とアップロード
```

## 起動と停止

```sh
./run.sh start     # MinIO を起動し，parquet を生成してアップロードする
./run.sh load      # データだけ作り直す（バケットを空にしてから全ファイルを再生成する）
./run.sh status    # 起動状態とバケット内のオブジェクト一覧
./run.sh stop      # 停止（データはボリュームに残る）
./run.sh purge     # 停止してボリュームも削除（確認あり．FORCE=1 で確認省略）
```

- MinIO の公式イメージは配布終了しているため，[object-storage/setup/minio](../../../object-storage/setup/minio/) の Dockerfile で公式ソースをビルドしたイメージ（`localhost/handbook-minio:<タグ>`）を使う．object-storage 側と同じタグなので，どちらかでビルド済みならそれを使う．初回のビルドは数分かかる
- `podman compose up -d` でも MinIO は起動できるが，データの投入は `run.sh start` / `load` だけが行う
- 設定（MinIO のバージョン・待機秒数）は `.env` で与える（[.env.example](.env.example)，方式は [../README.md の「設定方法（.env）」](../README.md#設定方法env)）

接続情報（**検証用の固定値であり秘密ではない**．各ツールのインジェスト定義にも同じ値を書いているため `.env` では変えられない）．

| 項目 | 値 |
| --- | --- |
| S3 エンドポイント（ホスト側から） | `http://localhost:9100` |
| S3 エンドポイント（コンテナ内から） | `http://host.containers.internal:9100` |
| Web コンソール | `http://localhost:9101` |
| アクセスキー / シークレット | `sample_s3_user` / `sample_s3_password` |
| リージョン | `us-east-1`（MinIO は見ないが，S3 クライアントの署名に必要） |
| バケット | `sample-lake` |

ホストの AWS CLI からは次で中身を見られる．

```sh
AWS_ACCESS_KEY_ID=sample_s3_user AWS_SECRET_ACCESS_KEY=sample_s3_password \
  aws --endpoint-url http://localhost:9100 --region us-east-1 s3 ls --recursive s3://sample-lake/
```

## データの構成

Hive 形式のパーティション（`dt=YYYY-MM-DD`）で，2026-11-01〜2026-11-15 の 15 日分を置く．1 日 1 ファイル．

```
s3://sample-lake/
├── openmetadata.json                                  # OpenMetadata 用マニフェスト
├── bronze/orders/dt=2026-11-01/part-0000.parquet      # 〜 dt=2026-11-15
├── silver/orders/dt=2026-11-01/part-0000.parquet
└── gold/daily_sales/dt=2026-11-01/part-0000.parquet
```

| 層 / テーブル | 内容 | 列 | 行数（15 日合計） |
| --- | --- | --- | --- |
| `bronze/orders` | 受信したままの注文明細．全列が文字列で，status の表記揺れ（`PLACED` / `shipped ` 等）と再送による重複行を含む | `order_id`，`line_no`，`customer_id`，`product_name`，`quantity`，`unit_price`，`status`，`ordered_at`（すべて string），`_ingested_at`（timestamp），`_source` | 253 |
| `silver/orders` | 型付け・重複除去・status の正規化（小文字化）をし，`amount = quantity × unit_price` を足したもの．`ordered_at` は UTC の timestamp | `order_id`（int64），`line_no`（int32），`customer_id`（int64），`product_name`，`quantity`（int32），`unit_price`（double），`amount`（double），`status`，`ordered_at`（timestamp） | 240 |
| `gold/daily_sales` | 商品別の日次売上（キャンセルを除く） | `product_name`，`order_count`，`total_quantity`（int64），`total_amount`（double） | 75 |

- **乱数は使っていない．** 注文 ID から値を決定的に計算するので，何度作り直しても同じ内容になる（取り込み結果が変わったときに，ツールのせいかデータのせいかを切り分けられるようにするため）
- `dt` はパスにだけあり，parquet の列には含めていない（Hive 形式の慣例どおり）
- `customer_id` は sample-db の顧客（1〜20）に合わせてあるが，sample-db とは独立に生成していて，DB から吸い出したものではない
- 層の間の変換は `generator/generate.py` の中で行っていて，カタログから見えるリネージは無い．parquet には SQL のような変換の記録が無いため，両ツールとも bronze → silver → gold のリネージは自動では取れない（[evaluation/plans/002](../../evaluation/plans/002-issue1-datalake-example.md) の 3.2．API で明示登録するかは未決）

## OpenMetadata 用マニフェスト（openmetadata.json）

OpenMetadata の S3 コネクタ（Storage サービス）は，**バケット直下の `openmetadata.json`** を読んで，どのパスを 1 つの Container（テーブル相当）として扱うかを決める．このディレクトリの [openmetadata.json](openmetadata.json) を `run.sh start` / `load` がアップロードしている．

```json
{
  "entries": [
    {"dataPath": "bronze/*/**/*.parquet", "structureFormat": "parquet", "isPartitioned": true, "autoPartitionDetection": true},
    {"dataPath": "silver/*/**/*.parquet", "structureFormat": "parquet", "isPartitioned": true, "autoPartitionDetection": true},
    {"dataPath": "gold/*/**/*.parquet",   "structureFormat": "parquet", "isPartitioned": true, "autoPartitionDetection": true}
  ]
}
```

### マニフェストが無いとどうなるか

バケット（`sample-lake`）が Container として 1 件登録されるだけで，中のファイルの構造（列）は取り込まれない．parquet を取り込むには，マニフェストで「どこにどの形式のデータがあるか」を教える必要がある．

**束ねる仕組みは DataHub と非対称になっている．** DataHub はインジェスト側の設定（recipe の `path_specs`）で束ね方を決めるのに対し，OpenMetadata は**データレイク側にファイルを置く**．レイクの書き手（データを置く側）に手を入れる必要があるので，運用での受け入れやすさに関わる（[evaluation/plans/002](../../evaluation/plans/002-issue1-datalake-example.md) の 2.7）．

### 各項目（OpenMetadata 2.0.1 の `containerMetadataConfig` で確認）

| 項目 | 意味 | ここでの値 |
| --- | --- | --- |
| `dataPath` | バケット直下からの相対パス．glob（`*` = 1 階層，`**` = 任意の深さ，`?` = 1 文字）が使える | `bronze/*/**/*.parquet` など |
| `structureFormat` | スキーマ推論に使う形式（`parquet` / `csv` / `json` / `avro` など）．省略すると拡張子から判定する | `parquet` |
| `isPartitioned` | パーティション付きのデータとして扱うか | `true` |
| `autoPartitionDetection` | `dataPath` が glob のとき，パスの `key=value` から Hive 形式のパーティション列を自動検出する．値が全部 `YYYY-MM-DD` なら DATE，整数なら INT，それ以外は VARCHAR | `true` |
| `partitionColumns` | パーティション列の明示定義（`name` / `dataType`）．指定すると自動検出より優先される | 指定なし |
| `depth` | glob を使わない書き方で，`dataPath` の何階層下までを Container として切り出すか | 指定なし（0） |
| `excludePaths` / `excludePatterns` | glob で探すときに除外するパス．既定で `_delta_log`，`_temporary`，`_spark_metadata`，`.tmp`，`_SUCCESS` を除外する | 指定なし |
| `separator` | CSV などの区切り文字 | 指定なし |
| `unstructuredData` | 画像・PDF など非構造データとして，ファイルごとに Container にする | 指定なし（false） |

glob を使うと，マッチしたファイルを「最初の `key=value` の手前まで」のパス（例 `bronze/orders`）でまとめ，それぞれを 1 つの Container にする．そのため上の 3 行で，層の下にテーブルを足しても（`silver/customers/dt=.../` など）マニフェストを書き換えずに Container が増える．

- スキーマはマッチしたファイルのうち**1 ファイルだけ**から推論する（全ファイルのスキーマをマージしない）．ファイル間で列が違う場合は片方しか見えない
- マニフェストはバケット直下に置くほか，インジェスト設定の `storageMetadataConfigSource` でローカル / HTTP / 別の S3 などに置いた共通マニフェストを指定することもできる（この場合はバケットごとの `containerName` を書く）

### 取り込み結果（2026-11-14 実測）

`../openmetadata/run.sh ingest sample-s3` で次の 4 件が登録される．

| Container | 列 |
| --- | --- |
| `sample_s3.sample-lake` | なし（バケット） |
| `sample_s3.sample-lake.bronze/orders` | `dt`（DATE）+ 10 列（parquet の string は STRING，timestamp は DATETIME） |
| `sample_s3.sample-lake.silver/orders` | `dt`（DATE）+ 9 列（int は INT，double は FLOAT） |
| `sample_s3.sample-lake.gold/daily_sales` | `dt`（DATE）+ 4 列 |

自動検出したパーティション列 `dt` が先頭の列として足される．

## GUI から取り込む

`run.sh ingest` を使わずに各ツールの画面から登録するときの設定．どちらのツールもサンプル S3 とは別の compose ネットワークで動くため，エンドポイントは `localhost` ではなく `http://host.containers.internal:9100` を指定する．

設定値は `run.sh ingest`（CLI）で動作を確認した定義と同じものだが，GUI からの登録そのものはまだ試していない．メニュー名はバージョンで変わることがある．

### OpenMetadata

1. Settings → Services → Storage → Add New Service で **S3** を選ぶ
2. 接続設定
   - AWS Access Key ID / AWS Secret Access Key: `sample_s3_user` / `sample_s3_password`
   - AWS Region: `us-east-1`
   - Endpoint URL: `http://host.containers.internal:9100`
   - Bucket Names: `sample-lake`（空ならすべてのバケット）
3. Test Connection．`GetMetrics` は警告になるが問題ない（バケットのオブジェクト数・サイズを AWS CloudWatch から取る処理で，MinIO には無い）
4. メタデータのインジェストを追加する．Storage Metadata Config Source は指定しない（既定でバケット直下の `openmetadata.json` を読む）

インジェストは OpenMetadata スタックの `ingestion` コンテナ（Airflow）が実行する．Linux ネイティブの podman では，このコンテナから `host.containers.internal` を引けないことがある（`run.sh ingest` は `--add-host` で補っているが，GUI 経由の実行には効かない）．

CLI で使っている定義は [../openmetadata/configs/ingestion/s3_storage.yaml](../openmetadata/configs/ingestion/s3_storage.yaml)．

### DataHub

1. Ingestion（Data Sources）→ Create new source で **S3 Data Lake** を選ぶ
2. recipe（YAML）に次を入れる．認証情報は Secrets に登録して `${SECRET_NAME}` で参照してもよい

   ```yaml
   source:
     type: s3
     config:
       platform: s3
       path_specs:
         - include: "s3://sample-lake/{layer}/{table}"
           table_name: "{layer}.{table}"
       aws_config:
         aws_access_key_id: sample_s3_user
         aws_secret_access_key: sample_s3_password
         aws_region: us-east-1
         aws_endpoint_url: http://host.containers.internal:9100
   ```

3. スケジュールを決めて実行する

インジェストは `datahub-actions` コンテナが実行し，実行時に `acryl-datahub[s3]`（`.env` の `UI_INGESTION_DEFAULT_CLI_VERSION` の版）を pip で入れる．そのためコンテナからインターネットに出られる必要がある．

DataHub は `openmetadata.json` を使わず，`path_specs` で束ね方を決める．
- `{table}` の位置のフォルダが 1 データセットになり，その下の `dt=...` は自動でパーティションとして扱われる（`autodetect_partitions`，既定 true）
- `{layer}` は名前付き変数で，bronze / silver / gold のどれにも一致する．`bronze/orders` と `silver/orders` は表示名が同じ `orders` になるため，`table_name` で層名を付けている（URN はパスから作るので，表示名に関係なく別データセットになる）
- スキーマ推論に使うのは既定で**最新のパーティション**（`traversal_method: MAX`，ここでは `dt=2026-11-15`）だけ

CLI で使っている定義は [../datahub/configs/recipes/s3_to_datahub.yml](../datahub/configs/recipes/s3_to_datahub.yml)．

### DataHub の取り込み結果（2026-11-14 実測）

`../datahub/run.sh ingest sample-s3` で 3 データセットが登録される．

| URN の name | 表示名 | 列 |
| --- | --- | --- |
| `sample-lake/bronze/orders` | `bronze.orders` | 10 列（parquet の列そのまま） |
| `sample-lake/silver/orders` | `silver.orders` | 9 列 |
| `sample-lake/gold/daily_sales` | `gold.daily_sales` | 4 列 |

OpenMetadata との違い:
- パーティション列 `dt` はスキーマに足されない（`add_partition_columns_to_schema` が既定で false のため）
- カスタムプロパティの `schema_inferred_from` が `.../dt=2026-11-15/part-0000.parquet`，`number_of_partitions` が `1` になる．既定の `traversal_method: MAX` で最新のパーティションしか辿らないため（全パーティションを数えるなら `traversal_method: ALL`）
- バケット・層のフォルダは Container として階層化され，データセットはその下に並ぶ
- MinIO への接続に path 形式の指定（`aws_advanced_config` の `addressing_style`）は不要だった
