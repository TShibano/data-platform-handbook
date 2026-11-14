# data-platform-handbook

データ基盤を構成する技術を，ローカルの Podman 環境で動かして比較・検証した記録．
カテゴリごとに，起動環境（`setup/`）と評価結果（`benchmark/` や `evaluation/`）を分けて置く．

| カテゴリ | 起動環境 | 評価 |
|---|---|---|
| S3互換オブジェクトストレージ（MinIO / AIStor / RustFS / Garage / SeaweedFS） | [object-storage/setup](object-storage/setup/) | [object-storage/benchmark](object-storage/benchmark/) |
| データカタログ（OpenMetadata / DataHub） | [data-catalog/setup](data-catalog/setup/) | [data-catalog/evaluation](data-catalog/evaluation/) |
