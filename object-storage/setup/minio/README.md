# MinIO（コミュニティ版）

## 概要

- ライセンス: AGPL-3.0
- 位置付け: 長らく S3 互換ストレージの事実上の標準だったが，コミュニティ版は開発を終えている
  - 2025年に Web コンソールから管理機能（ユーザー・ポリシー管理，設定等）が削除され，オブジェクトブラウザのみになった
  - コミュニティ版はソース配布のみとなり，ビルド済みバイナリ・公式イメージの提供は終了した．GitHub の README には「THIS REPOSITORY IS NO LONGER MAINTAINED.」と記載されている
  - GitHub リポジトリ `minio/minio` は 2026-04-25 にアーカイブ（読み取り専用）された
  - 後継として MinIO 社は商用の AIStor（Free / Enterprise）を案内している（[../aistor/](../aistor/)）
- 本手順では，AGPLv3 のコミュニティフォーク [pgsty/minio](https://github.com/pgsty/silo/tree/minio) の最終 MinIO 名義リリース `RELEASE.2026-08-04T00-00-00Z` を使う
  - フォークは管理機能付きの Web コンソール（georgmangold/console のフォーク）を同梱している
  - フォークは 2026-08-06 に `pgsty/silo`（PGSTY Silo）へ改名し，以降のリリースはバイナリ名・イメージ名が `silo` になった（最新は `docker.io/pgsty/silo:RELEASE.2026-11-12T00-00-00Z`）．`MINIO_*` 環境変数やデータ形式は互換と説明されている

### 公式イメージについて

2026-11-12 時点で次を確認した．

- `quay.io/minio/minio`: レジストリが匿名ユーザーに pull 権限を与えない（トークンの actions が空，manifest 取得は HTTP 401）
- `docker.io/minio/minio`: Docker Hub API でリポジトリが見つからない（`object not found`）

ベンチマーク（`../../benchmark/scripts/start_minio.sh`）では `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` を使っていた．このイメージがローカルにキャッシュ済みであれば，`MINIO_IMAGE` で差し替えて使える．

```bash
MINIO_IMAGE=quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z ./run.sh start
```

## 起動

```bash
# compose
podman compose up -d        # または docker compose up -d

# スクリプト
./run.sh start              # docker を使う場合: CONTAINER_RUNTIME=docker ./run.sh start
```

環境変数で上書きできる項目:

| 変数 | 既定値 |
|---|---|
| `MINIO_IMAGE` | `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z` |
| `MINIO_S3_PORT` | `9000` |
| `MINIO_CONSOLE_PORT` | `9001` |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | `minioadmin` / `minioadmin` |

## アクセス情報

- S3 エンドポイント: `http://localhost:9000`
- Web コンソール: `http://localhost:9001`
- 既定の認証情報: `minioadmin` / `minioadmin`（ルートユーザー．S3 のアクセスキー / シークレットとしてもそのまま使える）
- ヘルスチェック: `curl -f http://localhost:9000/minio/health/live`

## データ永続化

名前付きボリューム `handbook-minio-data` をコンテナの `/data` にマウントする．compose と run.sh で共通．

## 停止・削除

```bash
podman compose down               # コンテナ停止・削除（ボリュームは残る）
podman compose down -v            # ボリュームも削除

./run.sh stop                     # コンテナ停止・削除（ボリュームは残る）
./run.sh purge                    # ボリュームも削除
```

## 注意点

- フォークは MinIO 社とは無関係のコミュニティ版．長期利用する場合は `pgsty/silo` への移行可否を含めて継続性を評価すること
- `pgsty/minio` の最終リリース以降のセキュリティ修正は `pgsty/silo` 側にしか入らない
- 単一ノード・単一ドライブ構成のため，イレイジャーコーディングによる冗長性は無い
- `minioadmin` は既知の値なので，localhost 以外に公開する場合は必ず変更する
- macOS + Podman では，名前付きボリュームの実体は Podman マシン（Linux VM）内にある

## 出典（2026-11-12 確認）

- MinIO GitHub（アーカイブ表示・README）: https://github.com/minio/minio
- コミュニティフォーク（minio ブランチ / 現 silo）: https://github.com/pgsty/silo/tree/minio ， https://github.com/pgsty/silo
- フォークのイメージタグ: https://hub.docker.com/r/pgsty/minio/tags ， https://hub.docker.com/r/pgsty/silo/tags
- コンソール機能削減の報道: https://blocksandfiles.com/2025/06/19/minio-removes-management-features-from-basic-community-edition-object-storage-code/
- メンテナンスモード移行の報道: https://linuxiac.com/minio-ends-active-development/
