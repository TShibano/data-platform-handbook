# データカタログツールの評価

OpenMetadata と DataHub を [../setup/](../setup/) の環境で動かし，セットアップの手間や機能差を比較した記録．

## 構成

```
evaluation/
├── README.md
├── docs/
│   ├── comparison.md                 # OpenMetadata と DataHub の比較結果（2026-09-05 の検証記録）
│   └── platform-study-checklist.md   # データ基盤を設計するために埋めておく項目（2026-09-09）
└── plans/                            # 環境構築時の実装計画（001〜003）
```

- 検証結果は [docs/comparison.md](docs/comparison.md) にまとめる．再現手順は書かず，[../setup/](../setup/) の `run.sh` を参照する
- `docs/comparison.md` の本文と `plans/` は，2026-11 に `setup/` へ再配置し `run.sh` へ書き換える前の構成（`openmetadata/scripts/up.sh` など）でパスを書いている．当時の記録として残し，書き換えていない．現在の対応は次のとおり

| 当時のパス | 現在 |
|---|---|
| `openmetadata/scripts/{up,down,status,logs,ingest}.sh` | `setup/openmetadata/run.sh {start,stop,status,logs,ingest}`（`down.sh --purge` は `purge`） |
| `datahub/scripts/*.sh` | `setup/datahub/run.sh` の各サブコマンド |
| `examples/postgres/scripts/{up,down}.sh` | `setup/sample-db/run.sh {start,stop}` |
| `examples/sample-data/` | `setup/sample-db/sample-data/` |
| `shared/scripts/{common,preflight}.sh` | `setup/lib/{common,preflight}.sh` |
| `shared/scripts/fetch-compose.sh` | 各 `run.sh fetch-compose` |
| `shared/scripts/versions.env`，`*/configs/*.env` | 各 `run.sh` の固定値と `.env.example` |
| `*/scripts/lib.sh` | 各 `run.sh` に統合 |
