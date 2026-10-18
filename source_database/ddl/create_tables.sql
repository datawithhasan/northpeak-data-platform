-- NorthPeak Retail Group - Source Database DDL
-- Phase 2: Source System Engineering
-- Simulates NP Core (PostgreSQL 14)
-- Sprint 1: 28 July - 10 August 2026

-- ================================================================
-- SCHEMA SETUP
-- ================================================================
CREATE SCHEMA IF NOT EXISTS np_core;
SET search_path TO np_core;

-- ================================================================
-- STORES
-- ================================================================
CREATE TABLE IF NOT EXISTS stores (
    store_id        SERIAL PRIMARY KEY,
    store_code      VARCHAR(10)  NOT NULL UNIQUE,
    store_name      VARCHAR(100) NOT NULL,
    region          VARCHAR(50)  NOT NULL,
    store_type      VARCHAR(20)  NOT NULL CHECK (store_type IN ('superstore','local','express','online_dc')),
    address_line1   VARCHAR(200),
    city            VARCHAR(100),
    postcode        VARCHAR(10),
    country         VARCHAR(50)  DEFAULT 'UK',
    opened_date     DATE,
    acquired_from   VARCHAR(50),  -- NULL for original NorthPeak, 'FreshMart' for acquired
    is_active       BOOLEAN      DEFAULT TRUE,
    created_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

-- Index: most queries filter by region or store_type
CREATE INDEX idx_stores_region ON stores(region);
CREATE INDEX idx_stores_type   ON stores(store_type);

-- ================================================================
-- CUSTOMERS
-- (Intentional issues: pre-2018 records have legacy_customer_ref,
--  post-FreshMart records may have NULL email - documented known issue)
-- ================================================================
CREATE TABLE IF NOT EXISTS customers (
    customer_id         SERIAL PRIMARY KEY,
    legacy_customer_ref VARCHAR(20),   -- only populated for pre-2018 customers
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    email               VARCHAR(200),  -- NULL for some FreshMart migrated records
    phone               VARCHAR(20),
    date_of_birth       DATE,
    postcode            VARCHAR(10),
    loyalty_member_id   VARCHAR(50),   -- links to RewardsCo system
    acquisition_channel VARCHAR(50),   -- 'store','online','freshmart_migration'
    gdpr_consent        BOOLEAN        DEFAULT FALSE,
    gdpr_consent_date   TIMESTAMP,
    is_active           BOOLEAN        DEFAULT TRUE,
    created_at          TIMESTAMP      DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_customers_loyalty  ON customers(loyalty_member_id);
CREATE INDEX idx_customers_postcode ON customers(postcode);
CREATE INDEX idx_customers_email    ON customers(email);

-- ================================================================
-- PRODUCTS
-- ================================================================
CREATE TABLE IF NOT EXISTS products (
    product_id      SERIAL PRIMARY KEY,
    sku             VARCHAR(50)  NOT NULL UNIQUE,
    product_name    VARCHAR(200) NOT NULL,
    brand           VARCHAR(100),
    category_l1     VARCHAR(100),  -- e.g. 'Food', 'Drink', 'Household'
    category_l2     VARCHAR(100),  -- e.g. 'Fresh Produce', 'Dairy'
    category_l3     VARCHAR(100),  -- e.g. 'Vegetables', 'Milk'
    unit_of_measure VARCHAR(20),   -- 'each','kg','litre','pack'
    pack_size       NUMERIC(8,3),
    is_own_brand    BOOLEAN        DEFAULT FALSE,
    supplier_id     INTEGER,       -- FK added after supplier table
    rrp             NUMERIC(10,2), -- recommended retail price
    cost_price      NUMERIC(10,2),
    vat_rate        NUMERIC(5,2)   DEFAULT 0.20,
    is_active       BOOLEAN        DEFAULT TRUE,
    created_at      TIMESTAMP      DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP      DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_products_sku        ON products(sku);
CREATE INDEX idx_products_category   ON products(category_l1, category_l2);
CREATE INDEX idx_products_supplier   ON products(supplier_id);

-- ================================================================
-- SUPPLIERS
-- ================================================================
CREATE TABLE IF NOT EXISTS suppliers (
    supplier_id     SERIAL PRIMARY KEY,
    supplier_code   VARCHAR(20)  NOT NULL UNIQUE,
    supplier_name   VARCHAR(200) NOT NULL,
    country         VARCHAR(50),
    contact_email   VARCHAR(200),
    payment_terms   INTEGER      DEFAULT 30,  -- days
    is_own_brand    BOOLEAN      DEFAULT FALSE,
    is_active       BOOLEAN      DEFAULT TRUE,
    created_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

-- Add FK from products to suppliers
ALTER TABLE products
    ADD CONSTRAINT fk_products_supplier
    FOREIGN KEY (supplier_id) REFERENCES suppliers(supplier_id);

-- ================================================================
-- ORDERS
-- ================================================================
CREATE TABLE IF NOT EXISTS orders (
    order_id        SERIAL PRIMARY KEY,
    order_ref       VARCHAR(30)  NOT NULL UNIQUE,   -- NP-YYYY-XXXXXXX format
    customer_id     INTEGER,     -- FK, NULL allowed (4.1% of pre-2018 transactions)
    store_id        INTEGER      NOT NULL REFERENCES stores(store_id),
    order_channel   VARCHAR(20)  NOT NULL CHECK (order_channel IN ('in_store','online','click_collect')),
    order_status    VARCHAR(20)  DEFAULT 'completed',
    order_date      TIMESTAMP    NOT NULL,
    completed_at    TIMESTAMP,
    total_amount    NUMERIC(10,2) NOT NULL,
    discount_amount NUMERIC(10,2) DEFAULT 0,
    vat_amount      NUMERIC(10,2),
    payment_method  VARCHAR(30),  -- 'card','cash','contactless','online'
    payment_reference VARCHAR(100), -- masked on Silver write - may contain card data
    loyalty_points_earned INTEGER DEFAULT 0,
    is_returned     BOOLEAN      DEFAULT FALSE,
    created_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_orders_customer  ON orders(customer_id);
CREATE INDEX idx_orders_store     ON orders(store_id);
CREATE INDEX idx_orders_date      ON orders(order_date);
CREATE INDEX idx_orders_channel   ON orders(order_channel);
CREATE INDEX idx_orders_status    ON orders(order_status);

-- FK added separately - customer_id nullable (known data quality issue)
ALTER TABLE orders
    ADD CONSTRAINT fk_orders_customer
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id);

-- ================================================================
-- ORDER ITEMS
-- ================================================================
CREATE TABLE IF NOT EXISTS order_items (
    order_item_id   SERIAL PRIMARY KEY,
    order_id        INTEGER      NOT NULL REFERENCES orders(order_id),
    product_id      INTEGER      NOT NULL REFERENCES products(product_id),
    quantity        NUMERIC(8,3) NOT NULL,
    unit_price      NUMERIC(10,2) NOT NULL,
    line_total      NUMERIC(10,2) NOT NULL,
    discount_pct    NUMERIC(5,2)  DEFAULT 0,
    created_at      TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_order_items_order   ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);

-- ================================================================
-- INVENTORY
-- (Negative quantities are valid - represent DC adjustments, flag with is_adjustment)
-- ================================================================
CREATE TABLE IF NOT EXISTS inventory (
    inventory_id    SERIAL PRIMARY KEY,
    store_id        INTEGER      NOT NULL REFERENCES stores(store_id),
    product_id      INTEGER      NOT NULL REFERENCES products(product_id),
    quantity_on_hand NUMERIC(10,3),   -- can be negative (DC adjustment)
    quantity_reserved NUMERIC(10,3)   DEFAULT 0,
    quantity_on_order NUMERIC(10,3)   DEFAULT 0,
    reorder_level   NUMERIC(10,3),
    last_counted_at TIMESTAMP,
    is_adjustment   BOOLEAN      DEFAULT FALSE,  -- TRUE = negative is valid
    updated_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(store_id, product_id)
);

CREATE INDEX idx_inventory_store   ON inventory(store_id);
CREATE INDEX idx_inventory_product ON inventory(product_id);

-- ================================================================
-- STOCK MOVEMENTS (audit trail for inventory changes)
-- ================================================================
CREATE TABLE IF NOT EXISTS stock_movements (
    movement_id     SERIAL PRIMARY KEY,
    store_id        INTEGER      NOT NULL REFERENCES stores(store_id),
    product_id      INTEGER      NOT NULL REFERENCES products(product_id),
    movement_type   VARCHAR(30)  NOT NULL,  -- 'receipt','sale','return','adjustment','transfer','write_off'
    quantity        NUMERIC(10,3) NOT NULL,
    reference_id    VARCHAR(50),            -- order_ref or supplier delivery ref
    movement_date   TIMESTAMP    NOT NULL,
    created_at      TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_movements_store   ON stock_movements(store_id);
CREATE INDEX idx_movements_product ON stock_movements(product_id);
CREATE INDEX idx_movements_date    ON stock_movements(movement_date);
CREATE INDEX idx_movements_type    ON stock_movements(movement_type);

-- ================================================================
-- REWARDSCO LOYALTY TRANSACTIONS
-- ================================================================
CREATE TABLE IF NOT EXISTS rewardsco_loyalty_transactions (
    transaction_id     SERIAL        PRIMARY KEY,
    member_id          VARCHAR(50)   NOT NULL,   -- matches customers.loyalty_member_id; no FK (different system)
    transaction_type   VARCHAR(20)   NOT NULL CHECK (transaction_type IN ('earn','redeem')),
    points             INTEGER       NOT NULL,   -- sign convention: confirm earn/redeem direction before aggregating
    basket_value_gbp   NUMERIC(10,2),             -- NULL expected for 'redeem' rows
    store_id           INTEGER,                   -- NULL for online transactions; no FK (different system)
    channel            VARCHAR(20)   NOT NULL CHECK (channel IN ('in_store','online','click_collect')),
    sku                VARCHAR(50),                -- NULL expected for 'redeem' rows
    transaction_at     TIMESTAMP     NOT NULL,
    created_at         TIMESTAMP     DEFAULT CURRENT_TIMESTAMP
);

-- Index: the single most common query — "this member's points history,
-- in order" — covers both member-lookup alone AND member+date range,
-- since the leading column (member_id) also serves a plain member-only
-- filter. (No separate single-column member_id index — would be
-- redundant next to this composite, same reasoning as idx_inventory_store.)
CREATE INDEX idx_loyalty_member_date ON rewardsco_loyalty_transactions(member_id, transaction_at);

-- Index: date-range queries across ALL members (monthly loyalty volume reporting)
CREATE INDEX idx_loyalty_date ON rewardsco_loyalty_transactions(transaction_at);

-- Index: filter earn vs redeem transactions
CREATE INDEX idx_loyalty_type ON rewardsco_loyalty_transactions(transaction_type);

-- Index: "loyalty transactions at this store" — store-level loyalty reporting
CREATE INDEX idx_loyalty_store ON rewardsco_loyalty_transactions(store_id);

-- Index: filter in_store / online / click_collect
CREATE INDEX idx_loyalty_channel ON rewardsco_loyalty_transactions(channel);

-- Index: "loyalty transactions tied to this product" — product-level loyalty analysis
CREATE INDEX idx_loyalty_sku ON rewardsco_loyalty_transactions(sku);


-- ================================================================
-- KNOWN DATA QUALITY ISSUES (documented for Silver layer)
-- ================================================================
COMMENT ON COLUMN orders.customer_id IS
    'Nullable - 4.1% of pre-2018 transactions have no customer_id. Silver: flag as UNKNOWN_CUSTOMER, do not drop.';

COMMENT ON COLUMN customers.email IS
    'NULL for some FreshMart migration records. Silver: do not impute, flag as missing.';

COMMENT ON COLUMN inventory.quantity_on_hand IS
    'Can be negative for DC adjustment records. Silver: preserve, set is_adjustment=TRUE.';

COMMENT ON COLUMN orders.payment_reference IS
    'May contain card data for pre-2021 records. Silver: SHA-256 mask before writing.';
    
COMMENT ON COLUMN rewardsco_loyalty_transactions.points IS
    'Sign convention unconfirmed - verify earn rows are positive and redeem rows are negative before SUM(points) is used as a running balance.';

COMMENT ON COLUMN rewardsco_loyalty_transactions.basket_value_gbp IS
    'NULL for redeem transactions - expected business state, not missing data. Confirmed: 0 redeem rows have a non-null basket_value_gbp.';

COMMENT ON COLUMN rewardsco_loyalty_transactions.sku IS
    'NULL for redeem transactions - expected, same reasoning as basket_value_gbp.';

COMMENT ON COLUMN rewardsco_loyalty_transactions.store_id IS
    'NULL for online transactions (no physical store involved) - needs confirming this is the only reason it''s ever blank.';
