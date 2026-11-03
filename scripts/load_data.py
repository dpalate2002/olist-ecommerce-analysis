"""
load_data.py: load the 9 Olist CSVs into PostgreSQL and check the row counts.

Usage (from the repo root, with your virtual environment active):
    python scripts/load_data.py                  # recreate tables, then load
    python scripts/load_data.py --skip-create    # load into existing tables
    python scripts/load_data.py --data-dir path/to/csvs

Connection string comes from the DATABASE_URL environment variable
(put it in a .env file; see .env.example).

How it works:
  1. Runs sql/01_create_tables.sql so the schema, not pandas, decides the
     column types.
  2. Reads each CSV with pandas as TEXT (dtype=str). This keeps leading zeros
     in zip codes and exact decimals in prices. Postgres converts the text to
     the proper types (TIMESTAMP, NUMERIC, ...) and raises an error if any
     value doesn't fit.
  3. Streams each table into Postgres with COPY, which is far faster than
     row-by-row INSERTs (about 1M geolocation rows load in seconds).
  4. Compares the rows read from each CSV with COUNT(*) in the database
     and exits with an error if any count doesn't match.
"""

import argparse
import io
import os
import sys
import time
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # python-dotenv is optional
    pass

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATA_DIR = REPO_ROOT / "data" / "raw"
SCHEMA_FILE = REPO_ROOT / "sql" / "01_create_tables.sql"

# CSV file -> database table, in load order.
# Parent tables come before child tables so foreign keys are satisfied.
TABLES = [
    ("olist_customers_dataset.csv", "customers"),
    ("olist_sellers_dataset.csv", "sellers"),
    ("olist_products_dataset.csv", "products"),
    ("product_category_name_translation.csv", "category_translation"),
    ("olist_geolocation_dataset.csv", "geolocation"),
    ("olist_orders_dataset.csv", "orders"),
    ("olist_order_items_dataset.csv", "order_items"),
    ("olist_order_payments_dataset.csv", "order_payments"),
    ("olist_order_reviews_dataset.csv", "order_reviews"),
]

# Fix typos in the source column names so the database is clean.
COLUMN_RENAMES = {
    "product_name_lenght": "product_name_length",
    "product_description_lenght": "product_description_length",
}


def get_engine():
    url = os.environ.get("DATABASE_URL")
    if not url:
        sys.exit(
            "DATABASE_URL is not set. Copy .env.example to .env and fill in "
            "your Postgres password."
        )
    return create_engine(url)


def create_schema(engine):
    sql = SCHEMA_FILE.read_text(encoding="utf-8")
    with engine.begin() as conn:
        conn.exec_driver_sql(sql)
    print(f"Schema created from {SCHEMA_FILE.relative_to(REPO_ROOT)}")


def read_csv(path: Path) -> pd.DataFrame:
    # utf-8-sig strips the invisible byte-order mark at the start of
    # product_category_name_translation.csv; it is harmless for the other files.
    df = pd.read_csv(path, dtype=str, encoding="utf-8-sig")
    df = df.rename(columns=COLUMN_RENAMES)
    # Turn blank strings into real missing values so they load as NULL.
    df = df.replace(r"^\s*$", pd.NA, regex=True)
    # Data-quality fix: customer and seller zip prefixes lost their leading
    # zeros in the source files ("1003" instead of "01003"), while geolocation
    # kept them. Pad every zip column to 5 digits so the tables join correctly.
    for col in df.columns:
        if col.endswith("zip_code_prefix"):
            df[col] = df[col].str.zfill(5)
    return df


def copy_dataframe(engine, df: pd.DataFrame, table: str):
    """Stream a DataFrame into an existing table using Postgres COPY."""
    buffer = io.StringIO()
    df.to_csv(buffer, index=False, header=False)  # missing values -> empty -> NULL
    buffer.seek(0)

    columns = ", ".join(df.columns)
    copy_sql = f"COPY {table} ({columns}) FROM STDIN WITH (FORMAT csv)"

    raw = engine.raw_connection()  # COPY needs the underlying psycopg2 connection
    try:
        with raw.cursor() as cur:
            cur.copy_expert(copy_sql, buffer)
        raw.commit()
    except Exception:
        raw.rollback()
        raise
    finally:
        raw.close()


def main():
    parser = argparse.ArgumentParser(description="Load Olist CSVs into Postgres.")
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    parser.add_argument(
        "--skip-create",
        action="store_true",
        help="Don't drop and recreate tables (they must already exist and be empty).",
    )
    args = parser.parse_args()

    missing = [f for f, _ in TABLES if not (args.data_dir / f).exists()]
    if missing:
        sys.exit(f"Missing CSVs in {args.data_dir}:\n  " + "\n  ".join(missing))

    engine = get_engine()
    if not args.skip_create:
        create_schema(engine)

    results = []
    for filename, table in TABLES:
        start = time.perf_counter()
        df = read_csv(args.data_dir / filename)
        copy_dataframe(engine, df, table)
        with engine.connect() as conn:
            db_rows = conn.execute(text(f"SELECT COUNT(*) FROM {table}")).scalar_one()
        elapsed = time.perf_counter() - start
        results.append((table, len(df), db_rows, elapsed))
        print(f"  loaded {table:<22} {db_rows:>9,} rows  ({elapsed:.1f}s)")

    # Row-count check: rows read from each CSV vs rows in the database
    print("\nRow-count check")
    print(f"{'table':<22}{'csv_rows':>11}{'db_rows':>11}  status")
    all_ok = True
    for table, csv_rows, db_rows, _ in results:
        ok = csv_rows == db_rows
        all_ok &= ok
        print(f"{table:<22}{csv_rows:>11,}{db_rows:>11,}  {'OK' if ok else 'MISMATCH'}")

    if not all_ok:
        sys.exit("\nRow counts don't match. Check the errors above.")
    print("\nAll 9 tables loaded and every row count matches.")


if __name__ == "__main__":
    main()
