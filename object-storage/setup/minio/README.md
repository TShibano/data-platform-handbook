# MinIO（コミュニティ版）

## 概要

- ライセンス: AGPL-3.0
- 位置付け: 長らく S3 互換ストレージの事実上の標準だったが，コミュニティ版は開発を終えている
  - 2025年に Web コンソールから管理機能（ユーザー・ポリシー管理，設定等）が削除され，オブジェクトブラウザのみになった
  - コミュニティ版はソース配布のみとなり，ビルド済みバイナリ・公式イメージの提供は終了した．GitHub の README には「THIS REPOSITORY IS NO LONGER MAINTAINED.」と記載されている
  - GitHub リポジトリ `minio/minio` は 2026-04-25 にアーカイブ（読み取り専用）された
  - 後継として MinIO 社は商用の AIStor（Free / Enterprise）を案内している（[../aistor/](../aistor/)）
- 本手順では，公式リポジトリ [minio/minio](https://github.com/minio/minio) の最終リリースタグ `RELEASE.2025-10-15T17-29-55Z` のソースを，同じディレクトリの [Dockerfile](Dockerfile) でビルドして使う

## ソースからビルドする理由

- 公式イメージが匿名で取得できない（2026-11-12 確認）
  - `quay.io/minio/minio`: レジストリが匿名ユーザーに pull 権限を与えない（トークンの actions が空，manifest 取得は HTTP 401）
  - `docker.io/minio/minio`: Docker Hub API でリポジトリが見つからない（`object not found`）
- コミュニティフォークのイメージ（`pgsty/minio` 等）は第三者の配布物で，継続性や配布元の信頼性を自分で評価する必要がある
- 公式ソースの固定タグを Go 公式イメージでビルドすれば，配布元は GitHub の `minio/minio` と Docker 公式イメージ（`golang`，`alpine`）だけになり，内容も追跡できる

## イメージの構成

[Dockerfile](Dockerfile) はマルチステージビルドで，compose.yaml と run.sh の両方から使う．

| ステージ | ベースイメージ | 内容 |
|---|---|---|
| build | `docker.io/library/golang:1.24.13-trixie` | `git clone --depth 1 --branch $MINIO_VERSION` で公式ソースを取得し，`CGO_ENABLED=0 go build -tags kqueue -trimpath` でビルド |
| runtime | `docker.io/library/alpine:3.24.4` | `minio` バイナリと `LICENSE` / `CREDITS`（`/licenses/`）のみを配置し，非 root（UID 10001）で実行 |

- Go のバージョン: タグ時点の `go.mod` は `go 1.24.0` / `toolchain go1.24.8` を要求する．これを満たす Go 1.24 系の最終パッチ `1.24.13` を使う．git を同梱する Debian 版（trixie）を選んだ（alpine 版には git が無い）．`GOTOOLCHAIN=local` で別バージョンのツールチェーンの自動ダウンロードは抑止している
- ldflags: 本家 `Makefile` の `build` / `hotfix-vars` ターゲットと同じく `buildscripts/gen-ldflags.go` で生成する（`-s -w` と `cmd.Version` / `cmd.ReleaseTag` / `cmd.CommitID` 等の `-X`）．公式リリースと同様に `MINIO_RELEASE=RELEASE` を渡すので，`minio --version` は `RELEASE.2025-10-15T17-29-55Z` を表示する
- runtime に alpine を選んだ理由: distroless（`gcr.io/distroless/static`）はより小さいがバージョンタグが無くダイジェストでしか固定できず，シェルも無いため `podman exec` での調査がしにくい．alpine はタグで固定でき，CA 証明書も同梱している
- 本家のリリース用 Dockerfile（`Dockerfile.release`）は `dl.min.io` からビルド済みバイナリを取得する方式で，現在は使えない．ベースも `ubi-micro:latest` でタグ固定されていないため踏襲していない
- アーキテクチャ: ビルドホストのアーキテクチャ（`TARGETARCH`．未設定なら `go env GOARCH`）でネイティブビルドする．Apple Silicon（arm64）と amd64 のどちらでもビルドできる．ベースイメージはいずれも arm64 / amd64 のマルチアーキテクチャイメージ
- `mc`（MinIO Client）は別リポジトリ（`minio/mc`）のため同梱しない．ホスト側の `mc` や AWS CLI を使う（[../README.md](../README.md)）

### ビルド時間・ディスクの目安

- 初回ビルドは依存モジュールのダウンロード（数百 MB）とコンパイルで数分かかる．実測（2026-11-13，Apple Silicon，Podman 6.2.0 / libkrun マシン既定値 5 CPU・2 GiB メモリ）では，ベースイメージの pull を含めて約 2 分 15 秒だった
- `RUN --mount=type=cache` で Go のモジュール・ビルドキャッシュを再利用するので，2回目以降のビルドは速い
- ディスク: Go イメージ `golang:1.24.13-trixie` が約 940 MB，Podman ではビルドステージの中間イメージ（`<none>`）が約 1.1 GB 残る．これにモジュール・ビルドキャッシュが加わる．最終イメージ `localhost/handbook-minio` は約 116 MB（alpine 約 9 MB + バイナリ）
- 不要になった中間イメージ・キャッシュは `podman image prune` / `podman builder prune`（Docker は `docker builder prune`）で削除できる

## 起動

```bash
# compose（初回はビルドが走る）
podman compose up -d --build        # または docker compose up -d --build

# スクリプト（イメージが無ければビルドしてから起動する）
./run.sh start                      # docker を使う場合: CONTAINER_RUNTIME=docker ./run.sh start
./run.sh build                      # 強制的に再ビルドする
```

環境変数で上書きできる項目:

| 変数 | 既定値 | 備考 |
|---|---|---|
| `MINIO_VERSION` | `RELEASE.2025-10-15T17-29-55Z` | ビルドする公式リポジトリのタグ（compose / run.sh 共通） |
| `MINIO_IMAGE` | `localhost/handbook-minio:$MINIO_VERSION` | run.sh のみ．既存イメージを使う場合に指定（無ければこのタグでビルドする） |
| `MINIO_S3_PORT` | `9000` | |
| `MINIO_CONSOLE_PORT` | `9001` | |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | `minioadmin` / `minioadmin` | |

### バージョンを変える

`MINIO_VERSION` に公式リポジトリのタグ名（`RELEASE.YYYY-MM-DDThh-mm-ssZ` 形式）を指定してビルドし直す．タグ一覧は `gh api 'repos/minio/minio/tags?per_page=20' --jq '.[].name'` で確認できる．

```bash
MINIO_VERSION=RELEASE.2025-09-07T16-13-09Z ./run.sh build
./run.sh stop && MINIO_VERSION=RELEASE.2025-09-07T16-13-09Z ./run.sh start

MINIO_VERSION=RELEASE.2025-09-07T16-13-09Z podman compose up -d --build
```

- 古いタグは `go.mod` の要求 Go バージョンが異なる場合がある．Dockerfile の `GO_IMAGE` を `--build-arg GO_IMAGE=docker.io/library/golang:<ver>` で合わせる
- ダウングレードはデータ形式の互換性が保証されないため，ボリュームを作り直す（`./run.sh purge`）

### ベンチマーク用の公式イメージを使う

ベンチマーク（`../../benchmark/scripts/start_minio.sh`）では `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` を使っていた．このイメージがローカルにキャッシュ済みであれば，run.sh で差し替えられる．

```bash
MINIO_IMAGE=quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z ./run.sh start
```

公式イメージは root で動くため，同じボリュームを本手順のイメージ（非 root）と使い回すと権限エラーになり得る．切り替えるときは `./run.sh purge` でボリュームを作り直す．

## アクセス情報

- S3 エンドポイント: `http://localhost:9000`
- Web コンソール: `http://localhost:9001`
- 既定の認証情報: `minioadmin` / `minioadmin`（ルートユーザー．S3 のアクセスキー / シークレットとしてもそのまま使える）
- ヘルスチェック: `curl -f http://localhost:9000/minio/health/live`

## データ永続化

名前付きボリューム `handbook-minio-data` をコンテナの `/data` にマウントする．compose と run.sh で共通．

- イメージ内の `/data` は実行ユーザー（UID 10001）所有で作ってあり，空のボリュームを初めてマウントしたときにこの所有者が引き継がれる
- 以前の手順（`pgsty/minio` イメージ）で作ったボリュームが残っていると，所有者が異なり書き込めない場合がある．`./run.sh purge` で削除してから起動する

## 停止・削除

```bash
podman compose down               # コンテナ停止・削除（ボリュームは残る）
podman compose down -v            # ボリュームも削除

./run.sh stop                     # コンテナ停止・削除（ボリュームは残る）
./run.sh purge                    # ボリュームも削除（FORCE=1 で確認を省略）

podman image rm localhost/handbook-minio:RELEASE.2025-10-15T17-29-55Z   # ビルドしたイメージの削除
```

## 注意点

- AGPLv3: ビルドしたイメージを第三者に配布したり，改変してネットワーク越しにサービス提供したりする場合は，対応するソースの提供義務がある．本手順は改変せずにビルドしており，ライセンス文は `/licenses/` に同梱している
- セキュリティ修正が入らない: `minio/minio` はアーカイブ済みで，`RELEASE.2025-10-15T17-29-55Z` 以降のリリースは無い．その後に見つかった脆弱性は修正されないため，検証・学習用途に限り，外部公開や本番利用はしない
  - ビルドに使う Go 1.24 もサポート終了済み（Go は直近2系列のみサポート．2026-11-13 時点の最新は 1.27.4 / 1.26.11）で，標準ライブラリ（`net/http`，`crypto/tls` 等）の修正もバイナリに入らない．`GO_IMAGE` を新しい Go に変えてビルドできるかは要確認
- Web コンソールは管理機能が削除された版（オブジェクトブラウザのみ）．ユーザー・ポリシー管理は `mc admin` 等で行う
- 単一ノード・単一ドライブ構成のため，イレイジャーコーディングによる冗長性は無い
- `minioadmin` は既知の値なので，localhost 以外に公開する場合は必ず変更する
- macOS + Podman では，名前付きボリュームとビルドキャッシュの実体は Podman マシン（Linux VM）内にある

### 代替の選択肢

- コミュニティフォーク [pgsty/silo](https://github.com/pgsty/silo)（旧 `pgsty/minio`）: 管理機能付き Web コンソールを同梱し，本家アーカイブ後もリリースを続けている（最新は `docker.io/pgsty/silo:RELEASE.2026-11-12T00-00-00Z`）．2026-08-06 に `silo` へ改名し，最終 MinIO 名義リリースは `docker.io/pgsty/minio:RELEASE.2026-08-04T00-00-00Z`（2026-11-12 確認）．第三者配布である点に注意
- 商用の AIStor Free（[../aistor/](../aistor/)）

## 出典（2026-11-13 確認）

- MinIO GitHub（アーカイブ表示・README・タグ）: https://github.com/minio/minio ， https://github.com/minio/minio/tags
- 最終リリース `RELEASE.2025-10-15T17-29-55Z`（2025-10-16 公開）: https://github.com/minio/minio/releases/tag/RELEASE.2025-10-15T17-29-55Z
- ビルド方法（タグ時点のソース）: https://github.com/minio/minio/blob/RELEASE.2025-10-15T17-29-55Z/Makefile ， https://github.com/minio/minio/blob/RELEASE.2025-10-15T17-29-55Z/buildscripts/gen-ldflags.go ， https://github.com/minio/minio/blob/RELEASE.2025-10-15T17-29-55Z/go.mod ， https://github.com/minio/minio/blob/RELEASE.2025-10-15T17-29-55Z/Dockerfile.release
- Go 公式イメージ: https://hub.docker.com/_/golang/tags?name=1.24.13
- alpine 公式イメージ: https://hub.docker.com/_/alpine/tags
- Go のリリース一覧・サポート方針: https://go.dev/dl/ ， https://go.dev/doc/devel/release#policy
- コミュニティフォーク: https://github.com/pgsty/silo ， https://hub.docker.com/r/pgsty/minio/tags （2026-11-12 確認）
- コンソール機能削減の報道: https://blocksandfiles.com/2025/06/19/minio-removes-management-features-from-basic-community-edition-object-storage-code/
- メンテナンスモード移行の報道: https://linuxiac.com/minio-ends-active-development/
