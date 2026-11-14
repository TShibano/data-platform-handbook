# OpenMetadata

## 概要

- ライセンス: Apache-2.0
- バージョン: 2.0.1（公式 compose は GitHub Release `2.0.1-release` の `docker-compose.yml`．MySQL 版）
- イメージ: `docker.io/openmetadata/{db,server,ingestion}:2.0.1`
- 構成: mysql / elasticsearch / execute-migrate-all（マイグレーション，一度だけ実行） / openmetadata-server / ingestion（Airflow）

## 起動

設定は `.env` で与える（[../README.md の「設定方法（.env）」](../README.md#設定方法env)）．`.env` が無ければ既定値で起動する．

```bash
cp .env.example .env        # 必要な行だけ編集する
./run.sh config             # 実際に使われる値を確認する
./run.sh start              # podman machine のメモリが 6GB 以上必要
./run.sh ingest             # 先に ../sample-db/run.sh start しておく
```

設定できる変数（同時起動用のポートずらし，イメージ，ingest 用の管理者ログイン，起動待ちの秒数）と既定値は [.env.example](.env.example) を参照．

## アクセス情報

- UI / API: `http://localhost:8585`（初期ログイン `admin@open-metadata.org` / `admin`）
- 管理ポート: `http://localhost:8586/healthcheck`
- Airflow（ingestion コンテナ）: `http://localhost:8080`（`OM_ALT_PORTS=1` なら 18080）

## upstream から変えている点

公式 compose（`compose.upstream.yml`）はバイト列を変えずにコミットし，変更はすべて `compose.override.yml` と `.env`（`run.sh` の既定値）で行う．

- イメージ: upstream の既定は `docker.getcollate.io/openmetadata/*:2.0.0` だが，このミラーは匿名 pull の制限が厳しく実機で `toomanyrequests` になったため，同一イメージが公開されている `docker.io/openmetadata/*:2.0.1` を既定にしている
- mysql のデータ: upstream は `./docker-volume/db-data` への bind mount だが，名前付きボリューム `om-db-data` に置き換えている
- ポート: `ports: !override` で upstream と同じ値を明示している（`compose.altports.yml` で同時起動用にずらすため）
- メモリ: 各サービスに `mem_limit` を付けている（内訳は `compose.override.yml` のコメント）

## インジェスト

`./run.sh ingest` は次を行う．

1. `Containerfile.ingestion`（公式 ingestion イメージ + postgres / mysql / dbt コネクタ）をビルド
2. 管理者でログインし，ingestion-bot の JWT を API から取得（値はログに出さず，一時ファイルの定義に埋め込んで実行後に消す）
3. メタデータ（`configs/ingestion/postgres_metadata.yaml`）とリネージ（`postgres_lineage.yaml`）を別パイプラインで取り込む
4. 検索・リネージ API で，`public` のテーブル数が 5 件，`customer_order_summary` の上流が 3 件であることを検証する
