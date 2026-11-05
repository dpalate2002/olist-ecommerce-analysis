"""
clean_and_validate.py: build the clean schema and prove it is correct,
without needing Jupyter. Script version of notebooks/01_load_and_clean.ipynb.

Usage (from the repo root, with your virtual environment active):
    python scripts/clean_and_validate.py

What it does:
  1. Runs sql/02b_build_clean_tables.sql (drops and rebuilds the "clean" schema).
  2. Prints the row count of every clean table.
  3. Runs 7 validation tests and exits with an error if any fail.
  4. Prints the headline metrics.
  5. Saves two charts to dashboard/screenshots/ for the README.
"""

import os
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # save charts to files; never try to open a window
import matplotlib.pyplot as plt
import pandas as pd
from sqlalchemy import create_engine, text

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_SQL = REPO_ROOT / "sql" / "02b_build_clean_tables.sql"
CHART_DIR = REPO_ROOT / "dashboard" / "screenshots"

# Chart colors: accent for included data, gray for excluded, orange always = "late"
ACCENT, MUTED, LATE = "#2a78d6", "#b5b4ae", "#eb6834"
plt.rcParams.update({
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": "#e6e5e1", "axes.axisbelow": True,
    "axes.titlesize": 13, "axes.titleweight": "bold", "axes.titlelocation": "left",
})

VALIDATION_SQL = """
SELECT
  -- 1. One row per order in the summary (no row multiplication)
  (SELECT COUNT(*) FROM clean.order_summary) = (SELECT COUNT(*) FROM clean.orders)
      AS summary_one_row_per_order,
  -- 2. Exactly one review per order
  (SELECT COUNT(*) = COUNT(DISTINCT order_id) FROM clean.order_reviews)
      AS one_review_per_order,
  -- 3. Revenue in the clean tables equals raw revenue for the same window, to the cent
  (SELECT SUM(price) FROM order_items i JOIN orders o USING (order_id)
    WHERE o.order_purchase_timestamp >= '2017-01-01'
      AND o.order_purchase_timestamp <  '2018-09-01')
    = (SELECT SUM(items_value) FROM clean.order_summary)
      AS revenue_reconciles,
  -- 4. Every order falls inside the analysis window
  (SELECT MIN(purchase_ts) >= '2017-01-01' AND MAX(purchase_ts) < '2018-09-01' FROM clean.orders)
      AS window_respected,
  -- 5. Delivery metrics exist only for delivered orders, and are never negative
  (SELECT COUNT(*) = 0 FROM clean.orders
    WHERE (is_delivered AND (delivery_days IS NULL OR delivery_days < 0))
       OR (NOT is_delivered AND is_late IS NOT NULL))
      AS delivery_metrics_consistent,
  -- 6. No item lost its category
  (SELECT COUNT(*) = 0 FROM clean.order_items WHERE category IS NULL)
      AS every_item_has_category,
  -- 7. One row per zip code
  (SELECT COUNT(*) = COUNT(DISTINCT zip_code_prefix) FROM clean.geolocation)
      AS one_row_per_zip
"""

HEADLINE_SQL = """
SELECT
    ROUND(SUM(items_value), 2)                               AS revenue_brl,
    COUNT(*)                                                 AS delivered_orders,
    ROUND(SUM(items_value) / COUNT(*), 2)                    AS aov_brl,
    COUNT(DISTINCT customer_unique_id)                       AS unique_customers,
    ROUND(100.0 * AVG(is_late::int), 2)                      AS late_rate_pct,
    ROUND(AVG(review_score), 2)                              AS avg_review,
    ROUND(AVG(review_score) FILTER (WHERE NOT is_late), 2)   AS avg_review_on_time,
    ROUND(AVG(review_score) FILTER (WHERE is_late), 2)       AS avg_review_late
FROM clean.order_summary
WHERE is_delivered
"""


def section(title: str):
    print(f"\n{'=' * 60}\n{title}\n{'=' * 60}")


def main():
    url = os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("DATABASE_URL is not set. Copy .env.example to .env and fill it in.")
    engine = create_engine(url)

    def q(sql: str) -> pd.DataFrame:
        with engine.connect() as conn:
            return pd.read_sql(text(sql), conn)

    # 1. Build
    section("1. Building clean schema")
    with engine.begin() as conn:
        conn.exec_driver_sql(BUILD_SQL.read_text(encoding="utf-8"))
    print(f"Ran {BUILD_SQL.relative_to(REPO_ROOT)}")

    # 2. Row counts
    section("2. Clean table row counts")
    tables = ["orders", "order_summary", "order_items", "order_payments",
              "order_reviews", "products", "sellers", "geolocation"]
    for t in tables:
        n = q(f"SELECT COUNT(*) AS n FROM clean.{t}")["n"].iloc[0]
        print(f"  clean.{t:<16}{n:>10,}")

    # 3. Validation
    section("3. Validation tests")
    checks = q(VALIDATION_SQL).iloc[0]
    for name, passed in checks.items():
        print(f"  {'PASS' if passed else 'FAIL'}  {name}")
    if not checks.all():
        sys.exit("\nSome validation tests FAILED. See above.")
    print(f"\nAll {len(checks)} tests passed.")

    # 4. Headline metrics
    section("4. Headline metrics (delivered orders, Jan 2017 - Aug 2018)")
    for name, value in q(HEADLINE_SQL).iloc[0].items():
        value = float(value)
        shown = f"{value:,.0f}" if value.is_integer() else f"{value:,.2f}"
        print(f"  {name:<22}{shown:>16}")

    # 5. Charts
    section("5. Charts")
    CHART_DIR.mkdir(parents=True, exist_ok=True)

    monthly = q("""
        SELECT DATE_TRUNC('month', order_purchase_timestamp)::date AS month, COUNT(*) AS orders
        FROM orders GROUP BY 1 ORDER BY 1""")
    monthly["month"] = pd.to_datetime(monthly["month"])
    in_window = monthly["month"].between("2017-01-01", "2018-08-01")
    fig, ax = plt.subplots(figsize=(10, 4))
    ax.bar(monthly["month"], monthly["orders"], width=20,
           color=in_window.map({True: ACCENT, False: MUTED}))
    ax.grid(axis="x", visible=False)
    ax.set_title("Only Jan 2017 to Aug 2018 has full months of orders")
    ax.set_ylabel("Orders per month")
    fig.tight_layout()
    path1 = CHART_DIR / "01_analysis_window.png"
    fig.savefig(path1, dpi=150)
    plt.close(fig)
    print(f"  saved {path1.relative_to(REPO_ROOT)}")

    scores = q("""
        SELECT CASE WHEN is_late THEN 'Late' ELSE 'On time' END AS delivery,
               AVG(review_score) AS avg_review
        FROM clean.order_summary
        WHERE is_delivered AND review_score IS NOT NULL
        GROUP BY 1 ORDER BY 1 DESC""")
    gap = scores.set_index("delivery")["avg_review"]
    fig, ax = plt.subplots(figsize=(6, 3))
    bars = ax.barh(scores["delivery"], scores["avg_review"], height=0.5,
                   color=scores["delivery"].map({"On time": ACCENT, "Late": LATE}))
    ax.bar_label(bars, fmt="%.2f", padding=4)
    ax.set_xlim(0, 5)
    ax.set_xlabel("Average review score (1-5)")
    ax.grid(axis="y", visible=False)
    ax.set_title(f"Late orders score {gap['On time'] - gap['Late']:.1f} stars lower")
    fig.tight_layout()
    path2 = CHART_DIR / "02_review_late_vs_on_time.png"
    fig.savefig(path2, dpi=150)
    plt.close(fig)
    print(f"  saved {path2.relative_to(REPO_ROOT)}")

    print("\nDone. Phase 2 clean schema is built and validated.")


if __name__ == "__main__":
    main()
