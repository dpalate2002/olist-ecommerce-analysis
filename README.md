# Olist E-Commerce Sales & Customer Analysis

> **Status:** Phase 1 (Load) ✅ · Phase 2 (Clean & validate) ✅ · Phase 3 (SQL analysis) next

<!-- Replace this section in Phase 6 with your one-sentence main finding + dashboard link -->

## Problem

Olist is a Brazilian e-commerce marketplace. Acting as an analyst for Olist's leadership, this project uses ~100,000 orders (Sep 2016 – Oct 2018) to answer:

1. **Revenue:** How has revenue grown month over month, and which categories and states drive it?
2. **Customers:** What share of customers buy more than once, and how does retention look by cohort?
3. **Delivery:** How often are orders late, and how much does lateness lower review scores?
4. **Sellers:** Which sellers drive revenue, and which have the worst late-delivery or review records?
5. **Payments:** Which payment methods and installment plans are most common, and do they relate to order value?
6. **Recommendation:** What three changes would most improve revenue or customer satisfaction?

## Data

[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce): 9 CSV files, about 1.4M rows in total. The data isn't committed to this repo.

| Table | Rows | Grain |
|---|---:|---|
| orders | 99,441 | one order |
| order_items | 112,650 | one item within an order |
| order_payments | 103,886 | one payment record |
| order_reviews | 99,224 | one review |
| customers | 99,441 | one customer *per order* (use `customer_unique_id` for real people: 96,096) |
| products | 32,951 | one product |
| sellers | 3,095 | one seller |
| category_translation | 71 | Portuguese → English category |
| geolocation | 1,000,163 | zip prefix location (many duplicates) |

## How to reproduce

**Prerequisites:** PostgreSQL 14+, Python 3.10+.

```bash
# 1. Get the code
git clone https://github.com/dpalate2002/olist-ecommerce-analysis.git
cd olist-ecommerce-analysis

# 2. Python environment
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 3. Download the 9 CSVs into data/raw/
#    Option A: Kaggle (link above), then unzip into data/raw/
#    Option B: Olist's own GitHub copy of the same files:
#    git clone --depth 1 https://github.com/olist/work-at-olist-data.git /tmp/olist
#    cp /tmp/olist/datasets/*.csv data/raw/

# 4. Create the database and set the connection string
createdb -U postgres olist          # or create it in pgAdmin / DBeaver
cp .env.example .env               # then edit .env with your password

# 5. Create tables and load all 9 CSVs (~20 seconds)
python scripts/load_data.py
```

The loader prints a row-count check and exits with an error if any table's count doesn't match its CSV.

```bash
# 6. Run the data-quality checks (optional; read-only)
psql -U postgres -d olist -f sql/02_data_quality_checks.sql

# 7. Build the clean schema, run 7 validation tests, save charts
python scripts/clean_and_validate.py
# The notebook notebooks/01_load_and_clean.ipynb walks through the same steps
# with the evidence for every cleaning decision.
```

All analysis uses the `clean` schema. The raw tables are never modified.

## Repository structure

```
├── sql/
│   ├── 01_create_tables.sql      # typed schema: keys, foreign keys, indexes
│   ├── 02_data_quality_checks.sql # 17 checks on the raw data, with results
│   └── 02b_build_clean_tables.sql # builds the clean schema from every decision
├── scripts/
│   ├── load_data.py              # CSV → Postgres loader with row-count check
│   └── clean_and_validate.py     # builds clean schema, runs tests, saves charts
├── notebooks/
│   └── 01_load_and_clean.ipynb   # check → finding → decision, plus validation tests
├── dashboard/screenshots/        # images for this README (Phase 5)
├── memo/                         # one-page recommendation memo (Phase 6)
└── data/                         # git-ignored; raw/ and clean/
```

## Metric definitions

| Metric | Definition |
|---|---|
| Revenue | Sum of item `price` for delivered orders (freight excluded unless stated) |
| Order count | Distinct `order_id` with status `delivered` |
| Average order value (AOV) | Revenue ÷ order count |
| Unique customers | Distinct `customer_unique_id` |
| Repeat purchase rate | Customers with 2+ orders ÷ unique customers |
| Cohort retention | Of customers whose first order was in month M, % who ordered again in month M+1, M+2, … |
| Delivery time | Delivered timestamp − purchase timestamp, in days |
| Late delivery | Delivered after the estimated delivery date |
| Late delivery rate | Late delivered orders ÷ all delivered orders |
| Average review score | Mean `review_score` (1–5) |
| Freight share | Freight value ÷ (price + freight value) |

## Clean data model

`sql/02b_build_clean_tables.sql` builds a `clean` schema. The key table is **`clean.order_summary`**: one row per order, with items, payments and the review already rolled up, so analyses can't double-count.

| Table | Grain | Rows |
|---|---|---:|
| clean.orders | order (Jan 2017 – Aug 2018), with `is_delivered`, `delivery_days`, `is_late` | 99,092 |
| clean.order_summary | order, with items, payments and review rolled up | 99,092 |
| clean.order_items | item, with English category and seller state | 112,279 |
| clean.order_payments | payment record | 103,518 |
| clean.order_reviews | order (latest review only) | 98,330 |
| clean.geolocation | zip prefix | 19,010 |

The notebook ends with 7 automated tests, all passing. For example, revenue in the clean tables reconciles with the raw data to the cent, and there is exactly one row per order and one review per order.

## Data-quality log

Every issue found, how many rows it affects, and what was done about it. Evidence for each is in `sql/02_data_quality_checks.sql` and `notebooks/01_load_and_clean.ipynb`.

| # | Issue | Rows affected | Fix | Where |
|---|---|---:|---|---|
| 1 | Customer and seller zip prefixes lost their leading zeros in the source CSVs ("1003" instead of "01003"), so joins to geolocation silently failed | 23,995 customers; 1,027 sellers | Zero-padded to 5 digits at load | `load_data.py` |
| 2 | Customer zips with no geolocation match, even after padding | 279 customers | Kept; shown as unknown on maps | n/a |
| 3 | Misspelled source columns (`product_*_lenght`) | 2 columns | Renamed to `*_length` | `load_data.py` |
| 4 | Byte-order mark in the category translation CSV | 1 file | Read with `utf-8-sig` | `load_data.py` |
| 5 | Partial months at the start (Sep–Dec 2016) and end (Sep–Oct 2018) | 349 orders | Analysis window = 2017-01-01 to 2018-08-31 | `clean.orders` |
| 6 | Order status and delivered date disagree | 14 orders | Delivered = status `delivered` AND a delivered date | `is_delivered` |
| 7 | Carrier pickup recorded before purchase (impossible) | 166 orders | Carrier date set to NULL | `carrier_ts` |
| 8 | Estimated delivery is date-only, so a timestamp comparison overstates lateness | 1,292 orders | Late compared by calendar day | `is_late` |
| 9 | Orders with several reviews; `review_id` reused across orders | 547 orders | Kept the latest review per order (`ROW_NUMBER`) | `clean.order_reviews` |
| 10 | Reviews written before the order arrived | 5,126 orders | Kept; noted as a limitation | n/a |
| 11 | Orders with no items (unavailable / canceled) | 775 orders | Kept with NULL values so cancellation rates stay correct | `clean.order_summary` |
| 12 | Payments ≠ items + freight (vouchers, interest) | 362 orders | Revenue taken from `order_items` only | metric definitions |
| 13 | `not_defined` payment type, all R$0 | 3 rows | Dropped | `clean.order_payments` |
| 14 | Products with no category | 610 products (1,603 items) | Labeled `unknown` | `clean.products` |
| 15 | Categories missing from the translation table | 2 categories (24 items) | Translated by hand | `clean.products` |
| 16 | Geolocation has ~53 rows per zip prefix; 42 points outside Brazil | 1,000,163 rows | One row per zip, averaged inside Brazil | `clean.geolocation` |

## Findings

First look from the clean data (delivered orders, Jan 2017 – Aug 2018). Full analysis is coming in Phases 3–6.

| Metric | Value |
|---|---:|
| Revenue (items, excl. freight) | R$13.18M |
| Delivered orders | 96,203 |
| Average order value | R$137.00 |
| Unique customers | 93,096 |
| Late delivery rate | 6.8% |
| Avg review: on time vs. late | 4.29 vs. 2.27 ★ |
