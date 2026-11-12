# Garage

## 概要

- ライセンス: AGPL-3.0
- 位置付け: フランスの Deuxfleurs が開発する軽量な S3 互換ストレージ．地理分散した小規模ノード群での運用を想定しており，単一バイナリで動く
- 最新安定版: v2.5.0（2026-11-12 時点．Docker Hub の `dxflrs/garage` では日付付きのコミットハッシュタグも頻繁に出るが，固定には `vX.Y.Z` 形式を使う）
- 既存ベンチマーク（`../../benchmark/scripts/setup_garage.sh`）は v2.3.0 で Podman 上の動作実績がある

## 起動

compose と run.sh で初期化の方法が異なる．

### compose（自動初期化）

v2.3.0 以降の `garage server --single-node --default-bucket` を使い，起動時にレイアウト設定・既定キー・既定バケットを自動作成する．

```bash
podman compose up -d        # または docker compose up -d
```

| 変数 | 既定値 |
|---|---|
| `GARAGE_IMAGE` | `docker.io/dxflrs/garage:v2.5.0` |
| `GARAGE_DEFAULT_ACCESS_KEY` | `GKhandbook0000000000000000` |
| `GARAGE_DEFAULT_SECRET_KEY` | `handbook-garage-secret-change-me` |
| `GARAGE_DEFAULT_BUCKET` | `handbook` |
| `GARAGE_S3_PORT` / `GARAGE_WEB_PORT` / `GARAGE_ADMIN_PORT` | `3900` / `3902` / `3903` |

- キー ID は8文字以上の英数字と `-_.`，シークレットは16文字以上の印字可能 ASCII である必要がある（v2.5.0 のソースで確認）
- 既定キーにはバケット作成権限が付く

### run.sh（CLI で明示的に初期化）

`/garage server` で起動した後，CLI でクラスタを初期化する．処理は冪等で，再実行しても既存の設定は壊さない．

```bash
./run.sh start              # docker を使う場合: CONTAINER_RUNTIME=docker ./run.sh start
source .garage_env          # AWS_ACCESS_KEY_ID 等が設定される
```

`start` が行う処理:

1. `garage status` が `NO ROLE ASSIGNED`（未割り当て）または `pending...`（未適用）を返す場合のみ，レイアウトを設定・適用する
   ```bash
   garage node id -q                          # <hash>@<addr> の hash 部分を使う
   garage layout assign -z dc1 -c 10G <node_id>
   garage layout apply --version 1
   ```
2. キー `handbook-key` が無ければ `garage key create handbook-key` で作成する．既にあれば `garage key info --show-secret handbook-key` でシークレットを取得する
3. バケット `handbook` が無ければ作成し，`garage bucket allow --read --write --owner handbook --key handbook-key` で権限を付与する
4. 認証情報を `.garage_env` に書き出す（パーミッション 600）

| 変数 | 既定値 |
|---|---|
| `GARAGE_CAPACITY` | `10G`（レイアウトに登録する容量．実際の上限ではなくデータ配置の重み） |
| `GARAGE_KEY_NAME` | `handbook-key` |
| `GARAGE_BUCKET` | `handbook` |

run.sh で作ったキーにはバケット作成権限が無い．追加でバケットを作る場合は `podman exec handbook-garage /garage bucket create <name>` を使うか，`garage key allow --create-bucket handbook-key` で権限を付ける．

## アクセス情報

- S3 エンドポイント: `http://localhost:3900`
- リージョン: `garage`（`garage.toml` の `s3_region`．クライアント側も合わせる）
- 認証情報: compose は上表の既定キー，run.sh は `.garage_env`
- Admin API: `http://localhost:3903`（`garage.toml` の `admin_token` で認証）
- 静的 Web サイト公開: `http://<bucket>.web.garage.localhost:3902`（バケット側で website 設定が必要）
- Web UI: 公式には無い．サードパーティ製の Web UI は存在するが，本手順では扱わない
- CLI: `podman exec handbook-garage /garage <サブコマンド>`（イメージにシェルが無いため `/garage` を直接実行する）

## 設定ファイル

`garage.toml` は公式 Quick Start をもとに次を変えている．

- `metadata_dir` / `data_dir` を `/var/lib/garage/{meta,data}` にして名前付きボリュームに載せる（公式例の `/tmp` は再起動で消える）
- バインドアドレスを公式例の `[::]` ではなく，ベンチマークで実績のある `0.0.0.0` にする
- `rpc_secret` / `admin_token` はローカル検証用の固定値．共有環境では `openssl rand -hex 32` / `openssl rand -base64 32` で再生成するか，環境変数 `GARAGE_RPC_SECRET` / `GARAGE_ADMIN_TOKEN` で上書きする

## データ永続化

名前付きボリューム `handbook-garage-meta`（メタデータ，SQLite）と `handbook-garage-data`（オブジェクト本体）を使う．compose と run.sh で共通．

## 停止・削除

```bash
podman compose down               # コンテナ停止・削除（ボリュームは残る）
podman compose down -v            # ボリュームも削除

./run.sh stop                     # コンテナ停止・削除（ボリュームは残る）
./run.sh purge                    # ボリュームと .garage_env も削除
```

## 注意点

- `--single-node` は「レイアウトのバージョンが1以下」かつ「他ノードがいない」場合のみ動く．run.sh で初期化した後に compose で起動すること自体は可能だが，その後 run.sh 側のキー（`handbook-key`）と compose 側の既定キーが併存する
- `replication_factor = 1` なのでデータの冗長性は無い．複数ノードにする場合は全ノードで同じ `rpc_secret` と `replication_factor` が必要
- `db_engine = "sqlite"` は公式 Quick Start に合わせた．本番向けのメタデータエンジンの選択は公式の設定リファレンスを参照
- S3 API の対応範囲は製品ごとに異なる．Garage で未対応の S3 機能は公式の「S3 compatibility」ページで確認する（v2.5.0 時点の対応状況は要確認）

## 出典（2026-11-12 確認）

- Quick Start（設定例，CLI 手順，`--single-node`）: https://garagehq.deuxfleurs.fr/documentation/quick-start/
- 設定リファレンス（環境変数による上書き）: https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/
- CLI 定義（v2.5.0）: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/src/garage/cli/structs.rs
- 既定キーの検証処理（v2.5.0）: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/src/garage/server.rs
- イメージタグ一覧: https://hub.docker.com/r/dxflrs/garage/tags
