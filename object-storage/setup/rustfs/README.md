# RustFS

## 概要

- ライセンス: Apache-2.0
- 位置付け: Rust で実装された S3 互換オブジェクトストレージ．MinIO の代替を志向しており，コンソールや環境変数の構成も MinIO に近い
- ステータス: alpha / beta / RC を経て 2026-09-16 に 1.0.0 が GA．2026-11-12 時点の最新安定版は 1.0.5（2026-11-10）
- イメージ: `docker.io/rustfs/rustfs:1.0.5`（amd64 / arm64．glibc 版の `1.0.5-glibc` もある）

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

設定できる変数（イメージ，ポート，認証情報）と既定値は [.env.example](.env.example) を参照．

コンテナに渡している主な環境変数（公式ドキュメントより）:

| 変数 | 値 | 意味 |
|---|---|---|
| `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` | 上記 | 管理者の認証情報．空だと起動しない |
| `RUSTFS_VOLUMES` | `/data` | データディレクトリ |
| `RUSTFS_ADDRESS` | `:9000` | S3 API の待ち受け |
| `RUSTFS_CONSOLE_ADDRESS` | `:9001` | コンソールの待ち受け |
| `RUSTFS_CONSOLE_ENABLE` | `true` | コンソールを有効化 |

## アクセス情報

- S3 エンドポイント: `http://localhost:9020`
- Web コンソール: `http://localhost:9021`
- 認証情報: `rustfsadmin` / `rustfsadmin`（本ディレクトリの既定値．公式リポジトリの compose と同じ値）
- ヘルスチェック: `curl -f http://localhost:9020/health`

## データ永続化

名前付きボリューム `handbook-rustfs-data` をコンテナの `/data` にマウントする．compose と run.sh で共通．

コンテナは非 root ユーザー `rustfs`（UID 10001）で動く．ホストのディレクトリをバインドマウントする場合は，事前に `chown -R 10001:10001 <ディレクトリ>` が必要（しないと permission denied になる）．このため本手順では名前付きボリュームを使っている．

## 停止・削除

```bash
podman compose down               # コンテナ停止・削除（ボリュームは残る）
podman compose down -v            # ボリュームも削除

./run.sh stop                     # コンテナ停止・削除（ボリュームは残る）
./run.sh purge                    # ボリュームも削除
```

## 注意点

- 公式ドキュメントは「`rustfsadmin` を認証情報に使わないこと」と明記している．localhost 以外へ公開する場合は `openssl rand -base64 24` 等で生成した値を `.env` の `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` に設定する
- 1.0 GA から2か月程度で，パッチリリースが2週間程度の間隔で出ている．固定タグを定期的に見直すこと
- 本手順は単一ノード・単一ドライブ．複数ノード構成は `--network host` と `RUSTFS_VOLUMES="http://node{1...4}:9000/data/rustfs{0...3}"` のような指定が必要（公式ドキュメント参照）
- コンソールの URL パス（ルート直下か `/rustfs/console/` 等のサブパスか）は 1.0.5 で実機未確認（要確認）

## 出典（2026-11-12 確認）

- Docker での起動手順: https://docs.rustfs.com/installation/docker/
- GitHub（リリース，docker-compose.yml，Dockerfile）: https://github.com/rustfs/rustfs
- イメージタグ一覧: https://hub.docker.com/r/rustfs/rustfs/tags
