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

設定できる変数（イメージ，ポート，管理UIのパスワード，S3 のアクセスキー / シークレット，`s3.json` のパス）と既定値は [.env.example](.env.example) を参照．`SEAWEEDFS_S3_CONFIG` は run.sh / compose 共通で，相対パスはこのディレクトリ基準．

コンテナ内では `weed mini -dir=/data -s3.config=/config/s3.json -admin.password=<パスワード>` を実行し，環境変数 `SEAWEEDFS_S3_ACCESS_KEY` / `SEAWEEDFS_S3_SECRET_KEY` を渡す．

## S3 の認証設定

`s3.json` で ID（identity）ごとに認証情報と許可する操作を定義し，`-s3.config` で読み込ませる．キーは直書きせず `${VAR}` で環境変数を参照し，値は `.env` から渡す．

```json
{
  "identities": [
    {
      "name": "handbook_admin",
      "credentials": [{ "accessKey": "${SEAWEEDFS_S3_ACCESS_KEY}", "secretKey": "${SEAWEEDFS_S3_SECRET_KEY}" }],
      "actions": ["Admin", "Read", "List", "Tagging", "Write"]
    }
  ]
}
```

| `.env` の変数 | 既定値（以前 `s3.json` に直書きしていた値） | 生成例 |
|---|---|---|
| `SEAWEEDFS_S3_ACCESS_KEY` | `handbook-access-key` | `openssl rand -hex 16` |
| `SEAWEEDFS_S3_SECRET_KEY` | `handbook-secret-key-change-me` | `openssl rand -base64 30` |

- 仕組み（4.53 のソースで確認）: `-s3.config` で読んだ静的設定ファイルの `accessKey` / `secretKey` に含まれる `${VAR}` を，SeaweedFS がプロセスの環境変数で置き換える．run.sh は `-e`，compose は `environment:` で同名の環境変数をコンテナに渡す．置き換えは JSON を解析した後に行われるので，`"` や `\` を含む値でも JSON のエスケープは不要（2026-11-13 に `"` と `\` を含むシークレットで compose 経由の署名付きリクエストが通ることを確認）
- 参照先の変数が未設定または空の認証情報は捨てられる（警告ログ `dropping credential`）．設定ファイルを指定していて ID が1件も残らない場合は，匿名許可ではなく全リクエスト拒否になる．run.sh / compose とも空の値は既定値に置き換えるので，通常は起きない
- `.env` を変えても既存のコンテナには反映されない．run.sh は `./run.sh stop && ./run.sh start`，compose は `podman compose up -d --force-recreate` で作り直す．同じボリュームのまま変えてよく，作り直した後は旧キーが拒否される（2026-11-13 に run.sh / compose の両方で確認）
- 旧版（`s3.json` にキーを直書きしていた版）で作ったコンテナは `SEAWEEDFS_S3_ACCESS_KEY` を持たないため，更新後の `s3.json` で再起動すると全 S3 リクエストが拒否される．run.sh の `start` / `status` はこれを検出してエラーにするので，上の手順で作り直す
- 別の `s3.json`（`SEAWEEDFS_S3_CONFIG`）を使う場合も，キーは `${VAR}` 参照にして値を環境変数で渡すのがよい．run.sh / compose が渡すのは `SEAWEEDFS_S3_ACCESS_KEY` / `SEAWEEDFS_S3_SECRET_KEY` の2つだけなので，ID を増やす場合は compose.yaml / run.sh の環境変数も増やす
- 認証情報が1件も無い（`-s3.config` も環境変数も無い）場合，SeaweedFS は全 S3 操作を匿名で許可する（「Allow All」モード）．1件でも定義すると全リクエストに署名が必要になる
- 別の方式として，環境変数 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` を渡すと `admin-<アクセスキー先頭8文字>` という名前の Admin 権限の ID が作られる（4.53 のソースで確認．`weed mini` の起動メッセージでは `mini` ユーザーと説明されている）．本手順は ID 名と許可操作を `s3.json` で明示したいので，`${VAR}` 参照方式を採用した．また `AWS_*` はコンテナ内の他のクライアント処理にも読まれ得る汎用名なので避けた
- 管理UIや `weed shell` からも ID を追加できる
- 秘密値（S3 シークレット，管理UIのパスワード）は `./run.sh config` / `start` / `status` ではマスク表示する．平文は `./run.sh config --show-secrets`

## アクセス情報

- S3 エンドポイント: `http://localhost:8333`
- S3 認証情報: `.env` の `SEAWEEDFS_S3_ACCESS_KEY` / `SEAWEEDFS_S3_SECRET_KEY`（既定値 `handbook-access-key` / `handbook-secret-key-change-me`）
- 管理UI: `http://localhost:12535`（ユーザー名 `admin`，パスワードは `.env` の `SEAWEEDFS_ADMIN_PASSWORD`．既定値 `admin`）
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

## 出典（2026-11-12 確認．S3 認証情報の環境変数の項は 2026-11-13 確認）

- Quick Start with weed mini: https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini
- `weed mini` のフラグ・管理UIのバインド判定（4.53）: https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/command/mini.go
- Dockerfile・エントリポイント（4.53）: https://github.com/seaweedfs/seaweedfs/blob/4.53/docker/Dockerfile.go_build ， https://github.com/seaweedfs/seaweedfs/blob/4.53/docker/entrypoint.sh
- `s3.json` の書式例: https://github.com/seaweedfs/seaweedfs/blob/4.53/docker/compose/s3.json
- 静的設定ファイルの `${VAR}` 展開（`expandCredentialEnvRefs`），`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` からの ID 作成（`loadEnvironmentVariableCredentials`），設定ファイル指定時に ID が無ければ全拒否する判定（4.53．2026-11-13 確認）: https://github.com/seaweedfs/seaweedfs/blob/4.53/weed/s3api/auth_credentials.go
- リリース一覧: https://github.com/seaweedfs/seaweedfs/releases
- イメージタグ一覧: https://hub.docker.com/r/chrislusf/seaweedfs/tags
