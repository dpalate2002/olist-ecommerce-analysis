# Olist E-Commerce Sales & Customer Analysis

> **Status:** Phase 1 (Load) complete Â· Phase 2 (Clean & validate) in progress

<!-- Replace this section in Phase 6 with your one-sentence main finding + dashboard link -->

## Problem

Olist is a Brazilian e-commerce marketplace. Acting as an analyst for Olist's leadership, this project uses ~100,000 orders (Sep 2016 â€“ Oct 2018) to answer:

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
| category_translation | 71 | Portuguese â†’ English category |
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

## Repository structure

```
â”œâ”€â”€ sql/
â”‚   â””â”€â”€ 01_create_tables.sql      # typed schema: keys, foreign keys, indexes
â”œâ”€â”€ scripts/
â”‚   â””â”€â”€ load_data.py              # CSV â†’ Postgres loader with row-count check
â”œâ”€â”€ notebooks/                    # cleaning, validation, statistics (Phase 2, 4)
â”œâ”€â”€ dashboard/screenshots/        # images for this README (Phase 5)
â”œâ”€â”€ memo/                         # one-page recommendation memo (Phase 6)
â””â”€â”€ data/                         # git-ignored; raw/ and clean/
```

## Metric definitions

| Metric | Definition |
|---|---|
| Revenue | Sum of item `price` for delivered orders (freight excluded unless stated) |
| Order count | Distinct `order_id` with status `delivered` |
| Average order value (AOV) | Revenue Ã· order count |
| Unique customers | Distinct `customer_unique_id` |
| Repeat purchase rate | Customers with 2+ orders Ã· unique customers |
| Cohort retention | Of customers whose first order was in month M, % who ordered again in month M+1, M+2, â€¦ |
| Delivery time | Delivered timestamp âˆ’ purchase timestamp, in days |
| Late delivery | Delivered after the estimated delivery date |
| Late delivery rate | Late delivered orders Ã· all delivered orders |
| Average review score | Mean `review_score` (1â€“5) |
| Freight share | Freight value Ã· (price + freight value) |

## Data-quality log

Every issue found, how many rows it affects, and what was done about it.

| # | Issue | Rows affected | Fix | Where |
|---|---|---:|---|---|
| 1 | Customer and seller zip prefixes lost their leading zeros in the source CSVs ("1003" instead of "01003"); geolocation kept them, so joins silently failed | 23,995 customers, 1,027 sellers | Zero-padded all zip columns to 5 digits at load | `load_data.py` |
| 2 | Customer zip prefixes with no match in geolocation, even after padding | 279 customers | Kept; these show as "unknown" on maps | n/a |
| 3 | Source column names misspelled (`product_name_lenght`, `product_description_lenght`) | n/a (column names) | Renamed to `_length` at load | `load_data.py` |
| 4 | Byte-order mark at start of `product_category_name_translation.csv` | n/a (file encoding) | Read with `utf-8-sig` encoding | `load_data.py` |
| 5 | Two product categories have no English translation (`pc_gamer`, `portateis_cozinha_e_preparadores_de_alimentos`) | *TODO: count* | *TODO* | |
| â€¦ | *Phase 2: missing delivery dates, duplicate reviews, impossible dates, partial monthsâ€¦* | | | |

## Findings

*Coming in Phases 3â€“6.*
