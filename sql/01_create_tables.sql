-- =====================================================================
-- 01_create_tables.sql
-- Raw schema for the Olist Brazilian E-Commerce dataset (9 CSVs).
--
-- Design choices (be ready to explain these in an interview):
--   * IDs are 32-char hex hashes  -> VARCHAR(32), not integers.
--   * Zip code prefixes keep leading zeros ("01037") -> VARCHAR(5), not INT.
--   * Money -> NUMERIC(10,2): exact decimal math, no float rounding errors.
--   * Timestamps -> TIMESTAMP (the data has no time zone; it is Brazil local time).
--   * Primary keys only where the data is truly unique. order_reviews and
--     geolocation have duplicates, so they get no PK here; duplicates are
--     handled in the cleaning phase, not hidden at load time.
--   * Foreign keys document how tables join and make Postgres reject
--     orphan rows (e.g. an order item whose order does not exist).
--
-- Re-runnable: drops everything first. Run with:
--   psql -d olist -f sql/01_create_tables.sql
-- =====================================================================

DROP TABLE IF EXISTS order_reviews        CASCADE;
DROP TABLE IF EXISTS order_payments       CASCADE;
DROP TABLE IF EXISTS order_items          CASCADE;
DROP TABLE IF EXISTS orders               CASCADE;
DROP TABLE IF EXISTS geolocation          CASCADE;
DROP TABLE IF EXISTS category_translation CASCADE;
DROP TABLE IF EXISTS products             CASCADE;
DROP TABLE IF EXISTS sellers              CASCADE;
DROP TABLE IF EXISTS customers            CASCADE;

-- ---------------------------------------------------------------------
-- Dimension tables (loaded first, because fact tables reference them)
-- ---------------------------------------------------------------------

-- One row per customer_id. NOTE: Olist issues a NEW customer_id for every
-- order. customer_unique_id is the real person -> use it to count customers.
CREATE TABLE customers (
    customer_id              VARCHAR(32) PRIMARY KEY,
    customer_unique_id       VARCHAR(32) NOT NULL,
    customer_zip_code_prefix VARCHAR(5)  NOT NULL,
    customer_city            TEXT        NOT NULL,
    customer_state           CHAR(2)     NOT NULL
);

CREATE TABLE sellers (
    seller_id              VARCHAR(32) PRIMARY KEY,
    seller_zip_code_prefix VARCHAR(5)  NOT NULL,
    seller_city            TEXT        NOT NULL,
    seller_state           CHAR(2)     NOT NULL
);

-- Source columns are misspelled ("lenght"); the loader renames them to "length".
-- Category and size fields can be NULL in the source data.
CREATE TABLE products (
    product_id                 VARCHAR(32) PRIMARY KEY,
    product_category_name      TEXT,
    product_name_length        INTEGER,
    product_description_length INTEGER,
    product_photos_qty         INTEGER,
    product_weight_g           INTEGER,
    product_length_cm          INTEGER,
    product_height_cm          INTEGER,
    product_width_cm           INTEGER
);

-- No FK from products to this table: a few categories in products have
-- no English translation (you will find them in the quality checks).
CREATE TABLE category_translation (
    product_category_name         TEXT PRIMARY KEY,
    product_category_name_english TEXT NOT NULL
);

-- Many rows per zip prefix (~1M rows). No PK on purpose.
CREATE TABLE geolocation (
    geolocation_zip_code_prefix VARCHAR(5)       NOT NULL,
    geolocation_lat             DOUBLE PRECISION NOT NULL,
    geolocation_lng             DOUBLE PRECISION NOT NULL,
    geolocation_city            TEXT             NOT NULL,
    geolocation_state           CHAR(2)          NOT NULL
);

-- ---------------------------------------------------------------------
-- Fact tables
-- ---------------------------------------------------------------------

-- The center of the model: one row per order.
-- Delivery timestamps are NULL for orders not yet delivered or canceled.
CREATE TABLE orders (
    order_id                      VARCHAR(32) PRIMARY KEY,
    customer_id                   VARCHAR(32) NOT NULL REFERENCES customers (customer_id),
    order_status                  TEXT        NOT NULL,
    order_purchase_timestamp      TIMESTAMP   NOT NULL,
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP   NOT NULL
);

-- One row per item within an order (order_item_id = 1, 2, 3 ...).
CREATE TABLE order_items (
    order_id            VARCHAR(32)   NOT NULL REFERENCES orders (order_id),
    order_item_id       SMALLINT      NOT NULL,
    product_id          VARCHAR(32)   NOT NULL REFERENCES products (product_id),
    seller_id           VARCHAR(32)   NOT NULL REFERENCES sellers (seller_id),
    shipping_limit_date TIMESTAMP     NOT NULL,
    price               NUMERIC(10,2) NOT NULL,
    freight_value       NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

-- One row per payment record. An order can be paid in several parts
-- (e.g. a voucher + a credit card), numbered by payment_sequential.
CREATE TABLE order_payments (
    order_id             VARCHAR(32)   NOT NULL REFERENCES orders (order_id),
    payment_sequential   SMALLINT      NOT NULL,
    payment_type         TEXT          NOT NULL,
    payment_installments SMALLINT      NOT NULL,
    payment_value        NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

-- review_id repeats and some orders have several reviews, so no PK here.
-- Deduplication ("keep the latest review per order") happens in cleaning.
CREATE TABLE order_reviews (
    review_id               VARCHAR(32) NOT NULL,
    order_id                VARCHAR(32) NOT NULL REFERENCES orders (order_id),
    review_score            SMALLINT    NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TIMESTAMP   NOT NULL,
    review_answer_timestamp TIMESTAMP   NOT NULL
);

-- Indexes on the join columns that are not already primary keys.
-- They make the analysis queries in later phases much faster.
CREATE INDEX idx_orders_customer      ON orders (customer_id);
CREATE INDEX idx_orders_purchase_ts   ON orders (order_purchase_timestamp);
CREATE INDEX idx_customers_unique     ON customers (customer_unique_id);
CREATE INDEX idx_items_product        ON order_items (product_id);
CREATE INDEX idx_items_seller         ON order_items (seller_id);
CREATE INDEX idx_reviews_order        ON order_reviews (order_id);
CREATE INDEX idx_geolocation_zip      ON geolocation (geolocation_zip_code_prefix);
