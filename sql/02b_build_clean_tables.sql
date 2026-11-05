-- =====================================================================
-- 02b_build_clean_tables.sql
-- Builds the "clean" schema that every later analysis uses.
-- Raw tables stay untouched, so every cleaning decision can be audited
-- and re-run. Each fix links back to a check in 02_data_quality_checks.sql.
--
-- Tables created (schema "clean"):
--   orders         one row per order in the analysis window, with delivery metrics
--   order_items    one row per item, with English category and seller state
--   order_payments one row per payment record (junk 'not_defined' rows removed)
--   order_reviews  ONE review per order (the latest)
--   order_summary  one row per order with items, payments and the review
--                  already rolled up: safe to use without row multiplication
--   products, sellers, geolocation (one row per zip)
--
-- Run:  psql -d olist -f sql/02b_build_clean_tables.sql
-- Re-runnable: drops and rebuilds the whole schema.
-- =====================================================================

DROP SCHEMA IF EXISTS clean CASCADE;
CREATE SCHEMA clean;


-- ---------------------------------------------------------------------
-- products: English category names
--   * NULL category -> 'unknown'                                (check 15)
--   * 2 categories missing from the translation table -> translated by hand
-- ---------------------------------------------------------------------
CREATE TABLE clean.products AS
SELECT
    p.product_id,
    COALESCE(
        t.product_category_name_english,
        CASE p.product_category_name
            WHEN 'pc_gamer' THEN 'pc_gamer'
            WHEN 'portateis_cozinha_e_preparadores_de_alimentos'
                 THEN 'portable_kitchen_and_food_preparers'
        END,
        'unknown'
    ) AS category,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm,
    p.product_photos_qty
FROM products p
LEFT JOIN category_translation t USING (product_category_name);

ALTER TABLE clean.products ADD PRIMARY KEY (product_id);


-- ---------------------------------------------------------------------
-- sellers: unchanged apart from the zip padding done at load
-- ---------------------------------------------------------------------
CREATE TABLE clean.sellers AS
SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state
FROM sellers;

ALTER TABLE clean.sellers ADD PRIMARY KEY (seller_id);


-- ---------------------------------------------------------------------
-- geolocation: one row per zip prefix                          (check 16)
--   * drop the 42 points outside Brazil's bounding box
--   * average the remaining coordinates
-- ---------------------------------------------------------------------
CREATE TABLE clean.geolocation AS
SELECT
    geolocation_zip_code_prefix AS zip_code_prefix,
    AVG(geolocation_lat)        AS lat,
    AVG(geolocation_lng)        AS lng,
    MODE() WITHIN GROUP (ORDER BY geolocation_state) AS state
FROM geolocation
WHERE geolocation_lat BETWEEN -34 AND 5.5
  AND geolocation_lng BETWEEN -74 AND -34
GROUP BY geolocation_zip_code_prefix;

ALTER TABLE clean.geolocation ADD PRIMARY KEY (zip_code_prefix);


-- ---------------------------------------------------------------------
-- orders: the analysis window + delivery metrics
--   * keep purchases from 2017-01-01 to 2018-08-31 only        (check 5)
--   * keep ALL statuses here; analyses filter with is_delivered
--   * is_delivered requires the status AND a delivered date    (check 3)
--   * carrier dates before purchase are impossible -> NULL     (check 6)
--   * is_late compares calendar days, not timestamps           (check 7)
--   * customer_unique_id is attached so customers are counted correctly
-- ---------------------------------------------------------------------
CREATE TABLE clean.orders AS
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    c.customer_state,
    c.customer_city,
    c.customer_zip_code_prefix,
    o.order_status,
    o.order_purchase_timestamp                         AS purchase_ts,
    DATE_TRUNC('month', o.order_purchase_timestamp)::date AS purchase_month,
    o.order_approved_at                                AS approved_ts,
    CASE WHEN o.order_delivered_carrier_date >= o.order_purchase_timestamp
         THEN o.order_delivered_carrier_date END       AS carrier_ts,
    o.order_delivered_customer_date                    AS delivered_ts,
    o.order_estimated_delivery_date::date              AS estimated_date,

    (o.order_status = 'delivered'
     AND o.order_delivered_customer_date IS NOT NULL)  AS is_delivered,

    -- Delivery metrics are only defined for delivered orders (NULL otherwise)
    CASE WHEN o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
         THEN ROUND(EXTRACT(EPOCH FROM o.order_delivered_customer_date
                                     - o.order_purchase_timestamp) / 86400.0, 2)
    END                                                AS delivery_days,

    CASE WHEN o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
         THEN o.order_delivered_customer_date::date > o.order_estimated_delivery_date::date
    END                                                AS is_late,

    -- Positive = days late, negative = days early, 0 = on the promised day
    CASE WHEN o.order_status = 'delivered' AND o.order_delivered_customer_date IS NOT NULL
         THEN o.order_delivered_customer_date::date - o.order_estimated_delivery_date::date
    END                                                AS days_vs_estimate
FROM orders o
JOIN customers c USING (customer_id)
WHERE o.order_purchase_timestamp >= DATE '2017-01-01'
  AND o.order_purchase_timestamp <  DATE '2018-09-01';

ALTER TABLE clean.orders ADD PRIMARY KEY (order_id);
CREATE INDEX ON clean.orders (customer_unique_id);
CREATE INDEX ON clean.orders (purchase_month);


-- ---------------------------------------------------------------------
-- order_items: only for orders in the window, enriched for analysis
-- ---------------------------------------------------------------------
CREATE TABLE clean.order_items AS
SELECT
    i.order_id,
    i.order_item_id,
    i.product_id,
    p.category,
    i.seller_id,
    s.seller_state,
    i.shipping_limit_date,
    i.price,
    i.freight_value
FROM order_items i
JOIN clean.orders   o USING (order_id)
JOIN clean.products p USING (product_id)
JOIN clean.sellers  s USING (seller_id);

ALTER TABLE clean.order_items ADD PRIMARY KEY (order_id, order_item_id);
CREATE INDEX ON clean.order_items (seller_id);
CREATE INDEX ON clean.order_items (category);


-- ---------------------------------------------------------------------
-- order_payments: drop the 3 'not_defined' rows (all R$0)     (check 13)
-- ---------------------------------------------------------------------
CREATE TABLE clean.order_payments AS
SELECT pay.*
FROM order_payments pay
JOIN clean.orders o USING (order_id)
WHERE pay.payment_type <> 'not_defined';

ALTER TABLE clean.order_payments ADD PRIMARY KEY (order_id, payment_sequential);


-- ---------------------------------------------------------------------
-- order_reviews: keep the LATEST review per order               (check 9)
--   ROW_NUMBER() ranks each order's reviews newest-first; keep rank 1.
-- ---------------------------------------------------------------------
CREATE TABLE clean.order_reviews AS
WITH ranked AS (
    SELECT
        r.*,
        ROW_NUMBER() OVER (
            PARTITION BY r.order_id
            ORDER BY r.review_answer_timestamp DESC,
                     r.review_creation_date   DESC,
                     r.review_id
        ) AS rn
    FROM order_reviews r
    JOIN clean.orders o USING (order_id)
)
SELECT
    order_id,
    review_id,
    review_score,
    (review_comment_message IS NOT NULL) AS has_comment,
    review_comment_title,
    review_comment_message,
    review_creation_date,
    review_answer_timestamp
FROM ranked
WHERE rn = 1;

ALTER TABLE clean.order_reviews ADD PRIMARY KEY (order_id);


-- ---------------------------------------------------------------------
-- order_summary: ONE row per order with everything rolled up
--   Items and payments are each aggregated to the order level in their
--   own CTE BEFORE joining. Joining the raw tables together would
--   multiply rows (3 items x 2 payments = 6 rows) and inflate revenue.
-- ---------------------------------------------------------------------
CREATE TABLE clean.order_summary AS
WITH items AS (
    SELECT
        order_id,
        COUNT(*)                  AS n_items,
        COUNT(DISTINCT seller_id) AS n_sellers,
        SUM(price)                AS items_value,
        SUM(freight_value)        AS freight_value
    FROM clean.order_items
    GROUP BY order_id
),
main_item AS (
    -- The category and seller of the order's most expensive item
    SELECT DISTINCT ON (order_id)
        order_id, category AS main_category, seller_id AS main_seller_id
    FROM clean.order_items
    ORDER BY order_id, price DESC, order_item_id
),
payments AS (
    SELECT
        order_id,
        COUNT(*)                  AS n_payment_records,
        SUM(payment_value)        AS payment_value,
        MAX(payment_installments) AS max_installments
    FROM clean.order_payments
    GROUP BY order_id
),
main_payment AS (
    -- The payment method that covered the largest share of the order
    SELECT DISTINCT ON (order_id)
        order_id, payment_type AS main_payment_type
    FROM clean.order_payments
    ORDER BY order_id, payment_value DESC, payment_sequential
)
SELECT
    o.order_id,
    o.customer_unique_id,
    o.customer_state,
    o.order_status,
    o.is_delivered,
    o.purchase_ts,
    o.purchase_month,
    o.delivery_days,
    o.is_late,
    o.days_vs_estimate,
    i.n_items,
    i.n_sellers,
    mi.main_category,
    mi.main_seller_id,
    i.items_value,
    i.freight_value,
    i.items_value + i.freight_value AS gross_order_value,
    p.n_payment_records,
    mp.main_payment_type,
    p.max_installments,
    p.payment_value,
    r.review_score,
    r.has_comment
FROM clean.orders o
LEFT JOIN items         i  USING (order_id)
LEFT JOIN main_item     mi USING (order_id)
LEFT JOIN payments      p  USING (order_id)
LEFT JOIN main_payment  mp USING (order_id)
LEFT JOIN clean.order_reviews r USING (order_id);

ALTER TABLE clean.order_summary ADD PRIMARY KEY (order_id);
CREATE INDEX ON clean.order_summary (purchase_month);
CREATE INDEX ON clean.order_summary (customer_unique_id);
