# MinIO（コミュニティ版）を公式ソースからビルドして実行するイメージ
#
# 公式のビルド済みイメージ・バイナリは配布終了しており，github.com/minio/minio はソース配布のみ
# （2026-04-25 アーカイブ済み）のため，固定タグのソースを Go 公式イメージでビルドする．
# compose.yaml と run.sh の両方から使う．
#
#   podman build -t localhost/handbook-minio:RELEASE.2025-10-15T17-29-55Z .
#   podman build --build-arg MINIO_VERSION=RELEASE.2025-09-07T16-13-09Z -t ... .

# ビルドステージ: go.mod（go 1.24.0 / toolchain go1.24.8）に合わせ，Go 1.24 系の最終パッチを使う．
# git を同梱する Debian 版（trixie）を選ぶ（alpine 版には git が無い）．
ARG GO_IMAGE=docker.io/library/golang:1.24.13-trixie
# 実行ステージ: シェルと busybox があり調査しやすい alpine を使う（tag 固定）
ARG RUNTIME_IMAGE=docker.io/library/alpine:3.24.4

FROM ${GO_IMAGE} AS build

# 公式リポジトリの最終リリースタグ（2026-11-13 確認）
ARG MINIO_VERSION=RELEASE.2025-10-15T17-29-55Z
ARG MINIO_REPO=https://github.com/minio/minio.git
# BuildKit / Buildah が自動で設定する．未設定ならビルドホストのアーキテクチャになる
ARG TARGETOS
ARG TARGETARCH

# イメージ同梱の Go をそのまま使い，ツールチェーンの自動ダウンロードはさせない
ENV CGO_ENABLED=0 \
    GOTOOLCHAIN=local

WORKDIR /src
RUN git clone --depth 1 --branch "${MINIO_VERSION}" "${MINIO_REPO}" .

# 本家 Makefile の build / hotfix-vars ターゲットと同じ方法でビルドする．
#   - バージョン情報は buildscripts/gen-ldflags.go で生成する（-s -w と cmd.Version 等の -X）
#   - 公式リリースと同様に MINIO_RELEASE=RELEASE を渡し，ReleaseTag を RELEASE.<日時> にする
#   - gen-ldflags.go は日時を RFC3339（2025-10-15T17:29:55Z）で受け取るので，タグ名から変換する
#   - go build -tags kqueue -trimpath は Makefile と同じ
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eu; \
    ver="$(printf '%s' "${MINIO_VERSION}" | sed -E 's/^RELEASE\.([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2})Z$/\1T\2:\3:\4Z/')"; \
    case "$ver" in RELEASE.*) echo "MINIO_VERSION は RELEASE.YYYY-MM-DDThh-mm-ssZ 形式のタグを指定する: ${MINIO_VERSION}" >&2; exit 1 ;; esac; \
    ldflags="$(MINIO_RELEASE=RELEASE go run buildscripts/gen-ldflags.go "$ver")"; \
    echo "ldflags: $ldflags"; \
    GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH:-$(go env GOARCH)}" \
        go build -tags kqueue -trimpath -ldflags "$ldflags" -o /out/minio .; \
    /out/minio --version || true

FROM ${RUNTIME_IMAGE}

ARG MINIO_VERSION=RELEASE.2025-10-15T17-29-55Z

LABEL org.opencontainers.image.title="handbook-minio" \
      org.opencontainers.image.description="MinIO community edition built from github.com/minio/minio source" \
      org.opencontainers.image.source="https://github.com/minio/minio" \
      org.opencontainers.image.version="${MINIO_VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

# 非 root で実行する．/data を実行ユーザー所有で作っておくと，空の名前付きボリュームを
# マウントしたときにこの所有者がボリュームへ引き継がれる（Docker / Podman とも）
RUN addgroup -S -g 10001 minio \
    && adduser -S -D -H -u 10001 -G minio -h /data minio \
    && mkdir -p /data \
    && chown minio:minio /data

COPY --from=build /out/minio /usr/bin/minio
# AGPLv3 の条文と依存ライブラリのクレジットを同梱する
COPY --from=build /src/LICENSE /src/CREDITS /licenses/

USER minio:minio
WORKDIR /data
EXPOSE 9000 9001
VOLUME ["/data"]

ENTRYPOINT ["minio"]
CMD ["server", "/data", "--console-address", ":9001"]
