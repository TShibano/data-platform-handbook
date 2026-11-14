"""サンプル S3（MinIO）にメダリオン構成の parquet を生成・アップロードする．

使い方（../run.sh から実行する）:
    python generate.py load   # バケットを空にしてから全ファイルを作り直す
    python generate.py list   # バケット内のオブジェクト一覧を表示する

接続先は環境変数で与える: S3_ENDPOINT / S3_ACCESS_KEY / S3_SECRET_KEY / S3_BUCKET / MANIFEST_PATH

レイアウト（Hive 形式，2026-11-01〜2026-11-15 の 15 日分）:
    s3://<bucket>/openmetadata.json                               OpenMetadata 用マニフェスト
    s3://<bucket>/bronze/orders/dt=YYYY-MM-DD/part-0000.parquet   受信したままの注文明細（全列文字列，重複・表記揺れあり）
    s3://<bucket>/silver/orders/dt=YYYY-MM-DD/part-0000.parquet   型付け・重複除去・正規化した注文明細
    s3://<bucket>/gold/daily_sales/dt=YYYY-MM-DD/part-0000.parquet 商品別の日次売上（キャンセルを除く）

random は使わない．注文 ID から決定的に値を計算するので，何度作り直しても同じ内容になる
（取り込み結果が変わったときに，ツールのせいかデータのせいかを切り分けられるようにするため）．
"""

from __future__ import annotations

import io
import os
import sys
from datetime import date, datetime, timedelta, timezone

import boto3
import polars as pl
from botocore.config import Config

START_DATE = date(2026, 11, 1)
DAYS = 15
JST = timezone(timedelta(hours=9))

# (商品名, 単価)．sample-db の order_items と同じく 5 種類を巡回させる
PRODUCTS = [
    ("Wireless Mouse", "24.99"),
    ("USB-C Cable", "9.99"),
    ("Notebook", "4.50"),
    ("Coffee Beans", "18.00"),
    ("Desk Lamp", "39.90"),
]
# bronze の status は送信元システムの表記揺れをそのまま残す（silver で正規化する）
RAW_STATUSES = ["PLACED", "placed", "Shipped", "shipped ", "DELIVERED", "Cancelled"]


def build_bronze(day_index: int, day: date, first_order_id: int) -> tuple[pl.DataFrame, int]:
    """1 日分の受信データを作る．戻り値は (DataFrame, 次の注文 ID)．"""
    n_orders = 6 + (day_index * 7) % 5  # 1 日 6〜10 注文
    rows: list[dict[str, str]] = []
    order_id = first_order_id
    for _ in range(n_orders):
        customer_id = (order_id * 7) % 20 + 1  # sample-db の顧客 ID（1〜20）に合わせる
        n_lines = order_id % 3 + 1  # 1 注文 1〜3 明細
        ordered_at = datetime(day.year, day.month, day.day, 8 + (order_id * 5) % 14, (order_id * 13) % 60, tzinfo=JST)
        status = RAW_STATUSES[order_id % len(RAW_STATUSES)]
        for line_no in range(1, n_lines + 1):
            product_name, unit_price = PRODUCTS[(order_id + line_no) % len(PRODUCTS)]
            row = {
                "order_id": str(order_id),
                "line_no": str(line_no),
                "customer_id": str(customer_id),
                "product_name": product_name,
                "quantity": str((order_id + line_no) % 4 + 1),
                "unit_price": unit_price,
                "status": status,
                "ordered_at": ordered_at.isoformat(),
            }
            rows.append(row)
            # 9 の倍数の注文は 1 行目を再送したことにして重複させる（silver で除去する）
            if order_id % 9 == 0 and line_no == 1:
                rows.append(dict(row))
        order_id += 1

    # 取り込み時刻は翌日 01:00 UTC 固定（日次バッチで受信した想定）
    ingested_at = datetime(day.year, day.month, day.day, 1, 0, tzinfo=timezone.utc) + timedelta(days=1)
    df = pl.DataFrame(rows, schema={k: pl.String for k in rows[0]}).with_columns(
        pl.lit(ingested_at).cast(pl.Datetime("us", "UTC")).alias("_ingested_at"),
        pl.lit("ec-orders-api").alias("_source"),
    )
    return df, order_id


def to_silver(bronze: pl.DataFrame) -> pl.DataFrame:
    """型付け・重複除去・status の正規化を行う．"""
    return (
        bronze.unique(subset=["order_id", "line_no"], keep="first", maintain_order=True)
        .select(
            pl.col("order_id").cast(pl.Int64),
            pl.col("line_no").cast(pl.Int32),
            pl.col("customer_id").cast(pl.Int64),
            pl.col("product_name"),
            pl.col("quantity").cast(pl.Int32),
            pl.col("unit_price").cast(pl.Float64),
            (pl.col("quantity").cast(pl.Int32) * pl.col("unit_price").cast(pl.Float64)).round(2).alias("amount"),
            pl.col("status").str.strip_chars().str.to_lowercase().alias("status"),
            pl.col("ordered_at").str.to_datetime(time_zone="UTC").alias("ordered_at"),
        )
        .sort(["order_id", "line_no"])
    )


def to_gold(silver: pl.DataFrame) -> pl.DataFrame:
    """商品別の日次売上．キャンセルされた注文は除く．"""
    return (
        silver.filter(pl.col("status") != "cancelled")
        .group_by("product_name")
        .agg(
            pl.col("order_id").n_unique().cast(pl.Int64).alias("order_count"),
            pl.col("quantity").sum().cast(pl.Int64).alias("total_quantity"),
            pl.col("amount").sum().round(2).alias("total_amount"),
        )
        .sort("product_name")
    )


def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT"],
        aws_access_key_id=os.environ["S3_ACCESS_KEY"],
        aws_secret_access_key=os.environ["S3_SECRET_KEY"],
        region_name="us-east-1",
        # MinIO は仮想ホスト形式（<bucket>.<host>）を既定で受けないため path 形式にする
        config=Config(s3={"addressing_style": "path"}),
    )


def list_keys(client, bucket: str) -> list[tuple[str, int]]:
    keys: list[tuple[str, int]] = []
    for page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        keys.extend((o["Key"], o["Size"]) for o in page.get("Contents", []))
    return keys


def put_parquet(client, bucket: str, key: str, df: pl.DataFrame) -> None:
    buf = io.BytesIO()
    df.write_parquet(buf)
    client.put_object(Bucket=bucket, Key=key, Body=buf.getvalue())


def cmd_load(client, bucket: str) -> None:
    existing = {b["Name"] for b in client.list_buckets().get("Buckets", [])}
    if bucket not in existing:
        client.create_bucket(Bucket=bucket)
        print(f"バケット {bucket} を作成した")

    # 前回の内容を消してから作り直す（ファイル構成を変えたときに古いキーが残らないように）
    old = [k for k, _ in list_keys(client, bucket)]
    for i in range(0, len(old), 1000):
        client.delete_objects(Bucket=bucket, Delete={"Objects": [{"Key": k} for k in old[i : i + 1000]]})
    if old:
        print(f"既存のオブジェクト {len(old)} 件を削除した")

    counts = {"bronze": 0, "silver": 0, "gold": 0}
    order_id = 1001
    for i in range(DAYS):
        day = START_DATE + timedelta(days=i)
        bronze, order_id = build_bronze(i, day, order_id)
        silver = to_silver(bronze)
        gold = to_gold(silver)
        for layer, table, df in [("bronze", "orders", bronze), ("silver", "orders", silver), ("gold", "daily_sales", gold)]:
            put_parquet(client, bucket, f"{layer}/{table}/dt={day.isoformat()}/part-0000.parquet", df)
            counts[layer] += df.height

    with open(os.environ["MANIFEST_PATH"], "rb") as f:
        client.put_object(Bucket=bucket, Key="openmetadata.json", Body=f.read(), ContentType="application/json")

    print(f"アップロード完了: {DAYS} 日分 × 3 テーブル + openmetadata.json")
    print(f"  行数: bronze/orders {counts['bronze']}，silver/orders {counts['silver']}，gold/daily_sales {counts['gold']}")


def cmd_list(client, bucket: str) -> None:
    keys = list_keys(client, bucket)
    for key, size in keys:
        print(f"{size:>8}  s3://{bucket}/{key}")
    print(f"合計 {len(keys)} オブジェクト")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("load", "list"):
        print("使い方: generate.py {load|list}", file=sys.stderr)
        return 1
    client = s3_client()
    bucket = os.environ["S3_BUCKET"]
    if sys.argv[1] == "load":
        cmd_load(client, bucket)
    else:
        cmd_list(client, bucket)
    return 0


if __name__ == "__main__":
    sys.exit(main())
