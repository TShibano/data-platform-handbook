# Garage

## 概要

- ライセンス: AGPL-3.0
- 位置付け: フランスの Deuxfleurs が開発する軽量な S3 互換ストレージ．地理分散した小規模ノード群での運用を想定しており，単一バイナリで動く
- 最新安定版: v2.5.0（2026-11-12 時点．Docker Hub の `dxflrs/garage` では日付付きのコミットハッシュタグも頻繁に出るが，固定には `vX.Y.Z` 形式を使う）
- 既存ベンチマーク（`../../benchmark/scripts/setup_garage.sh`）は v2.3.0 で Podman 上の動作実績がある

## 起動

compose と run.sh で初期化の方法が異なる．

設定は `.env` で与える（[../README.md の「設定方法（.env）」](../README.md#設定方法env)）．`.env` が無ければ既定値で起動する．

```bash
cp .env.example .env        # 必要な行だけ編集する
./run.sh config             # 実際に使われる値を確認する
```

設定できる変数と既定値は [.env.example](.env.example) を参照（共通: イメージ，ポート，秘密値（`GARAGE_RPC_SECRET` / `GARAGE_ADMIN_TOKEN`） / run.sh のみ: 容量，キー名，バケット名 / compose のみ: 既定キー，既定バケット）．

`.env` は起動設定の**入力**で，run.sh が書き出す `.garage_env`（生成された S3 認証情報の**出力**）とは別物．`.env` に `AWS_ACCESS_KEY_ID` 等を書いても Garage のキーにはならない．

### compose（自動初期化）

v2.3.0 以降の `garage server --single-node --default-bucket` を使い，起動時にレイアウト設定・既定キー・既定バケットを自動作成する．

```bash
podman compose up -d        # または docker compose up -d
```

既定キーは `.env` の `GARAGE_DEFAULT_ACCESS_KEY` / `GARAGE_DEFAULT_SECRET_KEY`（既定値は `GKhandbook0000000000000000` / `handbook-garage-secret-change-me`），既定バケットは `GARAGE_DEFAULT_BUCKET`（既定値 `handbook`）で指定する．

- キー ID は8文字以上の英数字と `-_.`，シークレットは16文字以上の印字可能 ASCII である必要がある（v2.5.0 のソースで確認）
- 既定キーにはバケット作成権限が付く

### run.sh（CLI で明示的に初期化）

`/garage server` で起動した後，CLI でクラスタを初期化する．処理は冪等で，再実行しても既存の設定は壊さない．

```bash
./run.sh start              # docker を使う場合は .env に CONTAINER_RUNTIME=docker
source .garage_env          # AWS_ACCESS_KEY_ID 等が設定される（.env とは別の，run.sh の出力ファイル）
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

容量（`GARAGE_CAPACITY`，既定 `10G`．実際の上限ではなくデータ配置の重み），キー名（`GARAGE_KEY_NAME`，既定 `handbook-key`），バケット名（`GARAGE_BUCKET`，既定 `handbook`）は `.env` で変更できる．

run.sh で作ったキーにはバケット作成権限が無い．追加でバケットを作る場合は `podman exec handbook-garage /garage bucket create <name>` を使うか，`garage key allow --create-bucket handbook-key` で権限を付ける．

## アクセス情報

- S3 エンドポイント: `http://localhost:3900`
- リージョン: `garage`（`garage.toml` の `s3_region`．クライアント側も合わせる）
- 認証情報: compose は上表の既定キー，run.sh は `.garage_env`
- Admin API: `http://localhost:3903`（`.env` の `GARAGE_ADMIN_TOKEN` をベアラートークンにする．例: `curl -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" http://localhost:3903/v2/GetClusterStatus`）
- 静的 Web サイト公開: `http://<bucket>.web.garage.localhost:3902`（バケット側で website 設定が必要）
- Web UI: 公式には無い．サードパーティ製の Web UI は存在するが，本手順では扱わない
- CLI: `podman exec handbook-garage /garage <サブコマンド>`（イメージにシェルが無いため `/garage` を直接実行する）

## 設定ファイル

`garage.toml` は公式 Quick Start をもとに次を変えている．

- `metadata_dir` / `data_dir` を `/var/lib/garage/{meta,data}` にして名前付きボリュームに載せる（公式例の `/tmp` は再起動で消える）
- バインドアドレスを公式例の `[::]` ではなく，ベンチマークで実績のある `0.0.0.0` にする
- 秘密値（`rpc_secret` / `admin_token`）は書かない．次節のとおり環境変数で渡す

## 秘密値（rpc_secret / admin_token）

Garage は設定ファイルの秘密値を環境変数で与えられる（v0.8.2 以降）．本ディレクトリではこれを使い，`garage.toml` には秘密値を書かず，`.env` の値を run.sh（`-e`）/ compose（`environment:`）から同名の環境変数としてコンテナに渡す．

| `.env` の変数 | Garage の設定項目 | 既定値 | 生成例 |
|---|---|---|---|
| `GARAGE_RPC_SECRET` | `rpc_secret`（ノード間通信の共有鍵．32バイトの16進文字列＝64文字） | `00ba16ef…07cb`（以前 `garage.toml` に書いていた固定値） | `openssl rand -hex 32` |
| `GARAGE_ADMIN_TOKEN` | `admin.admin_token`（Admin API のベアラートークン） | `handbook-admin-token-change-me`（同上） | `openssl rand -base64 32` |

- 既定値はリポジトリで公開されているダミー値．localhost 以外へ公開する場合や共有環境では必ず `.env` で変更する
- 仕様（v2.5.0 のソースと設定リファレンスで確認）: 環境変数（`GARAGE_RPC_SECRET` 等）は設定ファイルの値より優先される．設定ファイル側のキーは省略してよい（`Option` 型で，環境変数・`*_file` のいずれかで埋まればよい）．`garage status` 等の CLI も同じ環境変数を読む．`podman exec` はコンテナ作成時の環境変数を引き継ぐので，run.sh の CLI 呼び出しもそのまま動く
- `*_FILE` 版（`GARAGE_RPC_SECRET_FILE` 等．ファイルのパーミッションが 600 でないと拒否される）もあるが，`.env` で値を直接与える他製品と揃えるため使っていない
- `GARAGE_RPC_SECRET` の形式は run.sh が起動前に検査する（compose では Garage が `Invalid RPC secret` で起動に失敗する）
- `metrics_token`（`/metrics` のトークン）は設定していない．Garage の既定どおり `/metrics` は認証なしで読める．必要なら `garage.toml` の `[admin]` に `metrics_token` を書くか，コンテナに `GARAGE_METRICS_TOKEN` を渡す（compose で空文字列を渡したときの扱いは未確認のため，変数化はしていない）
- `.env` を変えても既存のコンテナには反映されない（環境変数はコンテナ作成時に固定される）．run.sh は `./run.sh stop && ./run.sh start`，compose は `podman compose up -d --force-recreate` で再作成する
- 単一ノードなら，既存ボリュームのまま `GARAGE_RPC_SECRET` を変えてよい（ノード ID は `metadata_dir` の鍵で決まり，`rpc_secret` とは独立．2026-11-13 に変更前後で `garage status` とレイアウト・キー・バケットが維持されることを確認）．複数ノードにする場合は全ノードで同じ値が必要
- 旧版（`garage.toml` に `rpc_secret` を書いていた版）の run.sh / compose で作ったコンテナは `GARAGE_RPC_SECRET` を持たないため，`garage.toml` 更新後は CLI が `No RPC secret provided` で失敗し，再起動もできない．run.sh の `start` / `status` はこれを検出してエラーにするので，`./run.sh stop && ./run.sh start`（compose は `podman compose up -d --force-recreate`）で作り直す．データはボリュームに残る
- 秘密値は `./run.sh config` / `start` / `status` ではマスク表示する．平文は `./run.sh config --show-secrets`

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

## 出典（2026-11-12 確認．秘密値の環境変数の項は 2026-11-13 確認）

- Quick Start（設定例，CLI 手順，`--single-node`）: https://garagehq.deuxfleurs.fr/documentation/quick-start/
- 設定リファレンス（環境変数による上書き）: https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/ （v2.5.0 時点の原文: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/doc/book/reference-manual/configuration.md の「`rpc_secret`, `rpc_secret_file` or `GARAGE_RPC_SECRET`…」「`admin_token`…」節）
- 秘密値の環境変数（`GARAGE_RPC_SECRET` / `GARAGE_ADMIN_TOKEN` / `GARAGE_METRICS_TOKEN` と `_FILE` 版）の定義と，設定ファイル値より優先する処理（v2.5.0）: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/src/garage/secrets.rs
- 設定項目が省略可能（`Option`）であること（v2.5.0）: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/src/util/config.rs
- CLI も環境変数の `rpc_secret` を使うこと（v2.5.0）: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/src/garage/main.rs
- CLI 定義（v2.5.0）: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/src/garage/cli/structs.rs
- 既定キーの検証処理（v2.5.0）: https://git.deuxfleurs.fr/Deuxfleurs/garage/src/tag/v2.5.0/src/garage/server.rs
- イメージタグ一覧: https://hub.docker.com/r/dxflrs/garage/tags
