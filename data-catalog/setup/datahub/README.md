# DataHub

## 概要

- ライセンス: Apache-2.0
- バージョン: 1.7.0（公式 compose は `docker/quickstart/docker-compose.quickstart-profile.yml` の `v1.7.0` タグ）
- イメージ: `acryldata/*:v1.7.0`
- 構成: mysql / opensearch / kafka-broker / system-update（一度だけ実行） / datahub-gms / frontend / datahub-actions．全サービスに `profiles: quickstart` が付いているため，`run.sh` は `--profile quickstart` を付けて compose を呼ぶ

## 起動

設定は `.env` で与える（[../README.md の「設定方法（.env）」](../README.md#設定方法env)）．`.env` が無ければ既定値で起動する．

```bash
cp .env.example .env        # 必要な行だけ編集する
./run.sh config             # 実際に使われる値を確認する
./run.sh start              # podman machine のメモリが 8GB 以上必要．OpenMetadata より起動が遅い
./run.sh ingest             # 先に ../sample-db/run.sh start しておく
```

設定できる変数（同時起動用のポートずらし，イメージタグ，トークンの salt / signing key，起動待ちの秒数）と既定値は [.env.example](.env.example) を参照．

## アクセス情報

- UI: `http://localhost:9002`（初期ログイン `datahub` / `datahub`）
- GMS: `http://localhost:8080`（`DATAHUB_ALT_PORTS=1` なら 28080）．quickstart の GMS は認証を要求しない

## upstream から変えている点

公式 compose（`compose.upstream.yml`）はバイト列を変えずにコミットし，変更はすべて `compose.override.yml` と `.env`（`run.sh` の既定値）で行う．

- 既定値の無い変数（`DATAHUB_VERSION` / `UI_INGESTION_DEFAULT_CLI_VERSION` / `DATAHUB_TOKEN_SERVICE_SALT` / `DATAHUB_TOKEN_SERVICE_SIGNING_KEY`）を `run.sh` が与える．salt と signing key は公式 quickstart では実行ごとのランダム値だが，ここでは再現性のため固定値にしている
- `DATAHUB_VERSION` はイメージタグなので v 接頭辞付き（`v1.7.0`）．PyPI の `acryl-datahub` と compose 取得元の git タグ（`run.sh` の `DATAHUB_RELEASE`）は v なしで，表記が違う
- ポート: `ports: !override` で明示している（`compose.altports.yml` で同時起動用にずらすため）
- メモリ: 主要 6 サービスに `mem_limit` を付けている（合計 8g．内訳は `compose.override.yml` のコメント）
- `start` は upstream の bind mount 先（`~/.datahub/plugins`，`~/.datahub/search`）を事前に作る．`~/.aws` は汎用ディレクトリなので，存在しないときは作らず警告だけ出す

## インジェスト

`./run.sh ingest` は次を行う．

1. `Containerfile.ingestion`（`python:3.11-slim` + `acryl-datahub[datahub-rest,postgres,mysql,dbt]==1.7.0`）をビルド
2. recipe（`configs/recipes/postgres_to_datahub.yml`）の GMS ポートを起動設定に合わせて埋め込み，取り込む（テレメトリ送信は無効化）
3. 検索・リネージ API で，`customers` がヒットし，`customer_order_summary` に上流があることを検証する
