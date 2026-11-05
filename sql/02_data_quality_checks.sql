-- =====================================================================
-- 02_data_quality_checks.sql
-- Data-quality checks on the raw tables, BEFORE any cleaning.
-- Each check says what it looks for, and "Found:" records the result
-- from the full dataset so anyone can reproduce and compare.
--
-- SQL skills shown: COUNT / COUNT(DISTINCT), FILTER and CASE WHEN,
-- GROUP BY / HAVING, NOT EXISTS (anti-joins), CTEs, date arithmetic.
--
-- Run all:  psql -d olist -f sql/02_data_quality_checks.sql
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Row counts per table
--    Found: orders 99,441 | order_items 112,650 | payments 103,886 |
--           reviews 99,224 | customers 99,441 | products 32,951 |
--           sellers 3,095 | translation 71 | geolocation 1,000,163
-- ---------------------------------------------------------------------
SELECT 'orders'               AS table_name, COUNT(*) AS row_count FROM orders
UNION ALL SELECT 'order_items',          COUNT(*) FROM order_items
UNION ALL SELECT 'order_payments',       COUNT(*) FROM order_payments
UNION ALL SELECT 'order_reviews',        COUNT(*) FROM order_reviews
UNION ALL SELECT 'customers',            COUNT(*) FROM customers
UNION ALL SELECT 'products',             COUNT(*) FROM products
UNION ALL SELECT 'sellers',              COUNT(*) FROM sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM category_translation
UNION ALL SELECT 'geolocation',          COUNT(*) FROM geolocation;


-- ---------------------------------------------------------------------
-- 2. Missing values in the orders table
--    COUNT(*) - COUNT(col) = number of NULLs in col.
--    Found: approved_at 160 | carrier_date 1,783 | delivered_customer 2,965
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                       AS total_orders,
    COUNT(*) - COUNT(order_approved_at)            AS null_approved_at,
    COUNT(*) - COUNT(order_delivered_carrier_date) AS null_carrier_date,
    COUNT(*) - COUNT(order_delivered_customer_date) AS null_delivered_customer,
    COUNT(*) - COUNT(order_estimated_delivery_date) AS null_estimated
FROM orders;


-- ---------------------------------------------------------------------
-- 3. Do the delivery dates agree with order_status?
--    Found: 8 'delivered' orders have no delivered date;
--           6 non-delivered orders do have one.
--    Decision: an order counts as delivered only if BOTH are true.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE order_status = 'delivered'
                     AND order_delivered_customer_date IS NULL)     AS delivered_without_date,
    COUNT(*) FILTER (WHERE order_status <> 'delivered'
                     AND order_delivered_customer_date IS NOT NULL) AS date_without_delivered_status
FROM orders;


-- ---------------------------------------------------------------------
-- 4. Order status distribution
--    Found: delivered 96,478 (97.0%), shipped 1,107, canceled 625,
--           unavailable 609, invoiced 314, processing 301, created 5, approved 2
-- ---------------------------------------------------------------------
SELECT
    order_status,
    COUNT(*)                                            AS orders,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS pct_of_orders
FROM orders
GROUP BY order_status
ORDER BY orders DESC;


-- ---------------------------------------------------------------------
-- 5. Orders per purchase month: find partial months to trim
--    Found: 2016-09 = 4, 2016-10 = 324, 2016-11 = 0, 2016-12 = 1,
--           2018-09 = 16, 2018-10 = 4. Every month from 2017-01 to 2018-08
--           has 800+ orders.
--    Decision: analysis window = 2017-01-01 to 2018-08-31 (20 full months).
-- ---------------------------------------------------------------------
SELECT
    DATE_TRUNC('month', order_purchase_timestamp)::date AS purchase_month,
    COUNT(*)                                            AS orders
FROM orders
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 6. Impossible or out-of-order timestamps
--    Found: delivered before purchase 0 | approved before purchase 0 |
--           carrier pickup before purchase 166 |
--           delivered to customer before carrier pickup 23
--    Decision: set the impossible carrier dates to NULL in the clean table;
--    customer delivery dates are kept (the customer-facing date is what matters).
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE order_delivered_customer_date < order_purchase_timestamp)    AS delivered_before_purchase,
    COUNT(*) FILTER (WHERE order_approved_at            < order_purchase_timestamp)    AS approved_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_purchase_timestamp)    AS carrier_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_customer_date < order_delivered_carrier_date) AS customer_before_carrier
FROM orders;


-- ---------------------------------------------------------------------
-- 7. Late-delivery definition: timestamp vs. calendar day
--    The estimated date is always midnight (a date with no time), so a
--    timestamp comparison calls an order "late" even when it arrived ON the
--    promised day.
--    Found: late by timestamp 7,826 vs. late by calendar day 6,534
--    Decision: late = delivered DATE is after the estimated DATE.
-- ---------------------------------------------------------------------
SELECT
    COUNT(DISTINCT order_estimated_delivery_date::time)                                    AS distinct_estimate_times,
    COUNT(*) FILTER (WHERE order_delivered_customer_date > order_estimated_delivery_date)       AS late_by_timestamp,
    COUNT(*) FILTER (WHERE order_delivered_customer_date::date > order_estimated_delivery_date::date) AS late_by_calendar_day
FROM orders
WHERE order_status = 'delivered';


-- ---------------------------------------------------------------------
-- 8. Orders with no items, no payment, or no review (anti-joins)
--    Found: no items 775 (603 'unavailable', 164 'canceled') |
--           no payment 1 | no review 768
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM orders o
      WHERE NOT EXISTS (SELECT 1 FROM order_items i    WHERE i.order_id = o.order_id)) AS orders_without_items,
    (SELECT COUNT(*) FROM orders o
      WHERE NOT EXISTS (SELECT 1 FROM order_payments p WHERE p.order_id = o.order_id)) AS orders_without_payment,
    (SELECT COUNT(*) FROM orders o
      WHERE NOT EXISTS (SELECT 1 FROM order_reviews r  WHERE r.order_id = o.order_id)) AS orders_without_review;

SELECT o.order_status, COUNT(*) AS orders_without_items
FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM order_items i WHERE i.order_id = o.order_id)
GROUP BY o.order_status
ORDER BY 2 DESC;


-- ---------------------------------------------------------------------
-- 9. Duplicate reviews
--    review_id is NOT unique: one review can be attached to several orders,
--    and some orders received several reviews.
--    Found: 99,224 rows | 98,410 distinct review_id | 98,673 distinct orders |
--           547 orders with 2+ reviews | (review_id, order_id) is unique
--    Decision: keep the LATEST review per order.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                            AS review_rows,
    COUNT(DISTINCT review_id)           AS distinct_review_ids,
    COUNT(DISTINCT order_id)            AS distinct_orders,
    COUNT(DISTINCT (review_id, order_id)) AS distinct_review_order_pairs
FROM order_reviews;

SELECT COUNT(*) AS orders_with_multiple_reviews
FROM (
    SELECT order_id
    FROM order_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
) multi;


-- ---------------------------------------------------------------------
-- 10. Reviews written before the order arrived
--     Olist sends the survey around the estimated date, so customers whose
--     order is late often review before it arrives.
--     Found: 5,126 delivered orders. Kept: it's real customer sentiment,
--     but noted as a limitation.
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS reviews_before_delivery
FROM order_reviews r
JOIN orders o USING (order_id)
WHERE o.order_status = 'delivered'
  AND r.review_creation_date < DATE_TRUNC('day', o.order_delivered_customer_date);


-- ---------------------------------------------------------------------
-- 11. Missing review text
--     Found: 58,274 of 99,224 reviews (58.7%) have no comment message;
--            87,658 (88.3%) have no title. Expected: comments are optional.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                  AS reviews,
    COUNT(*) - COUNT(review_comment_message)  AS no_message,
    COUNT(*) - COUNT(review_comment_title)    AS no_title
FROM order_reviews;


-- ---------------------------------------------------------------------
-- 12. Impossible prices and freight
--     Found: price <= 0: 0 | freight < 0: 0 | freight = 0: 383 (free shipping;
--            kept) | price range 0.85 to 6,735.00
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE price <= 0)        AS price_zero_or_negative,
    COUNT(*) FILTER (WHERE freight_value < 0) AS freight_negative,
    COUNT(*) FILTER (WHERE freight_value = 0) AS freight_zero,
    MIN(price)                                AS min_price,
    MAX(price)                                AS max_price
FROM order_items;


-- ---------------------------------------------------------------------
-- 13. Payment records
--     Found: 'not_defined' type 3 rows (all value 0) -> excluded;
--            6 zero-value vouchers; 2 credit-card rows with 0 installments.
-- ---------------------------------------------------------------------
SELECT
    payment_type,
    COUNT(*)                                       AS payment_rows,
    COUNT(*) FILTER (WHERE payment_value = 0)      AS zero_value_rows,
    COUNT(*) FILTER (WHERE payment_installments = 0) AS zero_installment_rows
FROM order_payments
GROUP BY payment_type
ORDER BY payment_rows DESC;


-- ---------------------------------------------------------------------
-- 14. Do payments add up to items + freight? (aggregate FIRST, then join)
--     Joining items and payments directly would multiply rows, so each is
--     summed to one row per order in its own CTE.
--     Found: 362 of 96,477 delivered orders differ by more than 1 cent
--            (309 by more than R$1): mostly vouchers and installment interest.
--     Decision: revenue comes from order_items, never from payments.
-- ---------------------------------------------------------------------
WITH item_totals AS (
    SELECT order_id, SUM(price + freight_value) AS items_total
    FROM order_items
    GROUP BY order_id
),
payment_totals AS (
    SELECT order_id, SUM(payment_value) AS payment_total
    FROM order_payments
    GROUP BY order_id
)
SELECT
    COUNT(*)                                                    AS orders_compared,
    COUNT(*) FILTER (WHERE ABS(i.items_total - p.payment_total) > 0.01) AS mismatch_over_1_cent,
    COUNT(*) FILTER (WHERE ABS(i.items_total - p.payment_total) > 1)    AS mismatch_over_1_real
FROM item_totals i
JOIN payment_totals p USING (order_id)
JOIN orders o         USING (order_id)
WHERE o.order_status = 'delivered';


-- ---------------------------------------------------------------------
-- 15. Product categories: missing and untranslated
--     Found: 610 products (1,603 items) have no category -> 'unknown'.
--            2 categories have no English name (24 items): pc_gamer and
--            portateis_cozinha_e_preparadores_de_alimentos -> translated by hand.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*) FILTER (WHERE product_category_name IS NULL) AS products_without_category
FROM products;

SELECT p.product_category_name, COUNT(*) AS items
FROM order_items i
JOIN products p USING (product_id)
LEFT JOIN category_translation t USING (product_category_name)
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name IS NULL
GROUP BY p.product_category_name;


-- ---------------------------------------------------------------------
-- 16. Geolocation duplicates and bad coordinates
--     Found: 1,000,163 rows for only 19,015 zip prefixes;
--            280,009 exact duplicate rows; 42 points outside Brazil.
--     Decision: one row per zip = average lat/lng of points inside Brazil.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                     AS geo_rows,
    COUNT(DISTINCT geolocation_zip_code_prefix)  AS distinct_zips,
    COUNT(*) - COUNT(DISTINCT (geolocation_zip_code_prefix,
                               geolocation_lat, geolocation_lng)) AS exact_duplicates,
    COUNT(*) FILTER (WHERE geolocation_lat NOT BETWEEN -34 AND 5.5
                        OR geolocation_lng NOT BETWEEN -74 AND -34) AS outside_brazil
FROM geolocation;


-- ---------------------------------------------------------------------
-- 17. Real customers vs. customer_id
--     Found: 99,441 customer_id values but only 96,096 real people
--            (customer_unique_id). Always count customer_unique_id.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                           AS customer_ids,
    COUNT(DISTINCT customer_unique_id) AS unique_customers
FROM customers;
