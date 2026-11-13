# SeaweedFS

## 概要

- ライセンス: Apache-2.0
- 位置付け: 小さなファイルを大量に扱うことを得意とする分散ファイルシステム．master / volume / filer の上に S3 ゲートウェイを載せる構成で，WebDAV や Iceberg REST カタログ等も同梱する
- 最新版: 4.53（2026-11-08）．リリース間隔が短い（1週間程度）
- 単一ノード起動: `weed mini` が master・volume・filer・S3・WebDAV・管理UIを1プロセスで起動する．公式イメージの既定コマンドも `mini -dir=/data`
  - 既存ベンチマーク（`../../benchmark/scripts/start_seaweedfs.sh`）は `weed server -s3 -filer ...` を使っている．`weed server` は手動設定が前提の本番向け構成で，管理UIは含まれない
  - 本手順では管理UIまで1コンテナで使える `weed mini` を採用した

## 起動

設定は `.env` で与える（[../README.md の「設定方法（.env）」](../README.md#設定方法env)）．`.env` が無ければ既定値で起動する．

```bash
cp .env.example .env        # 必要な行だけ編集する
./run.sh config             # 実際に使われる値を確認する
```

```bash
# compose
podman compose up -d        # または docker compose up -d

# スクリプト
./run.sh start              # docker を使う場合は .env に CONTAINER_RUNTIME=docker
```

設定できる変数（イメージ，ポート，管理UIのパスワード，`s3.json` のパス）と既定値は [.env.example](.env.example) を参照．`SEAWEEDFS_S3_CONFIG` は run.sh / compose 共通で，相対パスはこのディレクトリ基準．

コンテナ内では `weed mini -dir=/data -s3.config=/config/s3.json -admin.password=<パスワード>` を実行する．

## S3 の認証設定

`s3.json` で ID（identity）ごとに認証情報と許可する操作を定義し，`-s3.config` で読み込ませる．

```json
{
  "identities": [
    {
      "name": "handbook_admin",
      "credentials": [{ "accessKey": "handbook-access-key", "secretKey": "handbook-secret-key-change-me" }],
      "actions": ["Admin", "Read", "List", "Tagging", "Write"]
    }
  ]
}
```

- 認証情報が1件も無い場合，SeaweedFS は全 S3 操作を匿名で許可する（「Allow All」モード）．1件でも定義すると全リクエストに署名が必要になる
- 簡易な代替として，環境変数 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`（と任意で `S3_BUCKET`）を渡すと，`mini` ユーザーの認証情報と初期バケットが作られる
- 管理UIや `weed shell` からも ID を追加できる

## アクセス情報

- S3 エンドポイント: `http://localhost:8333`
- S3 認証情報: `handbook-access-key` / `handbook-secret-key-change-me`（`s3.json`）
- 管理UI: `http://localhost:12535`（ユーザー名 `admin`，パスワード `admin`）
- Master UI: `http://localhost:9333`
- Filer UI: `http://localhost:8888`

## データ永続化

名前付きボリューム `handbook-seaweedfs-data` をコンテナの `/data` にマウントする．compose と run.sh で共通．

## 停止・削除

```bash
podman compose down               # コンテナ停止・削除（ボリュームは残る）
podman compose down -v            # ボリュームも削除

./run.sh stop                     # コンテナ停止・削除（ボリュームは残る）
./run.sh purge                    # ボリュームも削除
```

## 注意点

- 管理UIの既定ポートは 12535 に変わった（旧既定の 23646 も後方互換のため併せて待ち受ける．既存ベンチマークの `start_seaweedfs_admin.sh` は 23646 を使っている）
- `weed mini` の管理UIは，パスワード・mTLS・`-admin.allowInsecureBind` のいずれも無いとコンテナ内の 127.0.0.1 にしかバインドせず，ポート公開してもホストから開けない．このため `-admin.password` を必ず指定している
- `weed mini` は単一の master を持つ開発・単一ノード向け構成．複製や高可用性が必要なら `weed server` や個別コンポーネントでの構成にする
- 起動直後は master が応答してもボリュームサーバの登録前で PUT が失敗することがある．run.sh は `/dir/assign` が成功するまで待つ（既存ベンチマークで得た知見）
- イメージは既定で FIPS 140-3 モードが有効（無効化は `GODEBUG=fips140=off`）
- 匿名テレメトリが既定で有効．無効化は `-master.telemetry=false`

## 出典（2026-11-12 確認）

- Quick Start with weed mini: https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini
- `weed mini` のフラグ・管理UIのバインド判定（4.53）: https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/mini.go
- Dockerfile・エントリポイント（4.53）: https://github.com/seaweedfs/seaweedfs/blob/4.53/docker/Dockerfile.go_build ， https://github.com/seaweedfs/seaweedfs/blob/4.53/docker/entrypoint.sh
- `s3.json` の書式例: https://github.com/seaweedfs/seaweedfs/blob/4.53/docker/compose/s3.json
- リリース一覧: https://github.com/seaweedfs/seaweedfs/releases
- イメージタグ一覧: https://hub.docker.com/r/chrislusf/seaweedfs/tags
