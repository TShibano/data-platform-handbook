# MinIO AIStor

## 概要

- ライセンス: 商用（プロプライエタリ）．AIStor Free（無料）と AIStor Enterprise（有償・サポート付き）がある
- 位置付け: MinIO 社の商用版オブジェクトストレージ．コミュニティ版 MinIO の開発終了後，MinIO 社が案内している移行先
- AIStor Free の条件（公式ドキュメント・料金ページより）
  - 単一ノード（単一ドライブ / 複数ドライブ）構成のみ．分散構成は不可
  - サポートはコミュニティ Slack とドキュメントのみ
  - 再配布は禁止
  - ライセンス文書では，レプリケーション，ティアリング・ライフサイクル遷移，保存時暗号化，プロファイリング，**性能試験（performance testing）**，テレメトリ等が Free の対象外と記載されている．一方，料金ページの FAQ は「単一ノードで AIStor の全機能を含む」としており，記述が食い違う（要確認）
  - 容量上限・ライセンス期間は公式ページに記載が見当たらない（要確認）

## 事前準備: ライセンスファイル

AIStor の起動にはライセンスが必要．

1. https://www.min.io/pricing の Free tier で「Get Started」からライセンスを取得する
2. ダウンロードしたファイルをこのディレクトリに `minio.license` として置く（別の場所なら `AISTOR_LICENSE_FILE` で指定）

`minio.license` は個人に紐づく情報なので，リポジトリにはコミットしない（`../.gitignore` で除外している）．

ライセンス無しの場合: `RELEASE.2025-12-20T04-58-37Z` 以降はライセンス無しでも起動でき，オフラインモードになる．このとき S3 操作は全て拒否され，Admin API とコンソールのみ使える（コンソールからライセンスを登録できる）．run.sh はライセンスファイルが無いと警告を出してこのモードで起動する．compose はライセンスファイルのマウントを前提としている．

## 起動

```bash
# compose（minio.license が必要）
podman compose up -d        # または docker compose up -d

# スクリプト
./run.sh start              # docker を使う場合: CONTAINER_RUNTIME=docker ./run.sh start
```

| 変数 | 既定値 |
|---|---|
| `AISTOR_IMAGE` | `quay.io/minio/aistor/minio:RELEASE.2026-09-19T17-05-25Z` |
| `AISTOR_LICENSE_FILE` | `./minio.license` |
| `AISTOR_S3_PORT` | `9010` |
| `AISTOR_CONSOLE_PORT` | `9011` |
| `AISTOR_ROOT_USER` / `AISTOR_ROOT_PASSWORD` | `minioadmin` / `minioadmin` |

起動コマンドは公式手順どおり `minio server /mnt/data --license /minio.license`．

## アクセス情報

- S3 エンドポイント: `http://localhost:9010`
- Web コンソール: `http://localhost:9011`
- 既定の認証情報: `minioadmin` / `minioadmin`（公式手順の既定値）
- ルート認証情報を `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` で変更できるかは，コミュニティ版 MinIO からの類推であり AIStor の文書では未確認（要確認）

## データ永続化

名前付きボリューム `handbook-aistor-data` をコンテナの `/mnt/data` にマウントする．compose と run.sh で共通．

## 停止・削除

```bash
podman compose down               # コンテナ停止・削除（ボリュームは残る）
podman compose down -v            # ボリュームも削除

./run.sh stop                     # コンテナ停止・削除（ボリュームは残る）
./run.sh purge                    # ボリュームも削除
```

## 注意点

- compose でライセンスファイルが存在しない場合，docker は同名のディレクトリを自動作成してしまい起動に失敗する．podman はマウントエラーになる．先に `minio.license` を置くこと
- Free ライセンスでは性能試験が対象外と読める記述があるため，ベンチマーク用途で使う前にライセンス条項を確認すること
- イメージタグ: quay.io 上の安定版の最新は `RELEASE.2026-09-19T17-05-25Z`（`latest` と同一ダイジェストを確認）．別系統として `11.0.0-edge` 等の新しい形式のタグも出ており，今後の版番号体系は要確認
- TLS を使う場合は証明書ディレクトリを `/etc/minio/certs` にマウントし `--certs-dir /etc/minio/certs` を付ける（公式手順）

## 出典（2026-11-12 確認）

- コンテナでの起動手順: https://docs.min.io/aistor/installation/container/install/
- ライセンス（オフラインモード，Free の制限）: https://docs.min.io/aistor/operations/licenses/
- 料金・Free tier: https://www.min.io/pricing
- Free 契約: https://www.min.io/legal/aistor-free-agreement
- イメージタグ一覧: https://quay.io/repository/minio/aistor/minio?tab=tags
