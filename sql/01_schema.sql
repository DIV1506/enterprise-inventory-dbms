-- ============================================================
-- Enterprise Inventory Database Management System
-- 01_schema.sql : normalized (3NF) schema, constraints, indexes
-- Target: PostgreSQL 14+
-- ============================================================

DROP SCHEMA IF EXISTS inventory CASCADE;
CREATE SCHEMA inventory;
SET search_path = inventory;

-- ---------- Reference / master tables ----------

CREATE TABLE categories (
    category_id   SERIAL PRIMARY KEY,
    name          VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE suppliers (
    supplier_id   SERIAL PRIMARY KEY,
    name          VARCHAR(120) NOT NULL UNIQUE,
    email         VARCHAR(120) UNIQUE,
    phone         VARCHAR(30),
    city          VARCHAR(80),
    rating        NUMERIC(2,1) CHECK (rating BETWEEN 0 AND 5),
    created_at    TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE warehouses (
    warehouse_id  SERIAL PRIMARY KEY,
    name          VARCHAR(80) NOT NULL UNIQUE,
    city          VARCHAR(80) NOT NULL,
    capacity      INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE products (
    product_id     SERIAL PRIMARY KEY,
    sku            VARCHAR(30) NOT NULL UNIQUE,
    name           VARCHAR(150) NOT NULL,
    category_id    INT NOT NULL REFERENCES categories(category_id),
    unit_price     NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    reorder_level  INT NOT NULL DEFAULT 10 CHECK (reorder_level >= 0),
    is_active      BOOLEAN NOT NULL DEFAULT TRUE
);

-- Which supplier can supply which product, and at what cost (M:N resolved)
CREATE TABLE product_suppliers (
    product_id     INT NOT NULL REFERENCES products(product_id),
    supplier_id    INT NOT NULL REFERENCES suppliers(supplier_id),
    unit_cost      NUMERIC(10,2) NOT NULL CHECK (unit_cost >= 0),
    lead_time_days INT NOT NULL CHECK (lead_time_days >= 0),
    PRIMARY KEY (product_id, supplier_id)
);

-- Current stock per product per warehouse
CREATE TABLE stock (
    product_id    INT NOT NULL REFERENCES products(product_id),
    warehouse_id  INT NOT NULL REFERENCES warehouses(warehouse_id),
    quantity      INT NOT NULL DEFAULT 0 CHECK (quantity >= 0),   -- never negative
    updated_at    TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, warehouse_id)
);

-- ---------- Purchasing ----------

CREATE TABLE purchase_orders (
    po_id          SERIAL PRIMARY KEY,
    supplier_id    INT NOT NULL REFERENCES suppliers(supplier_id),
    warehouse_id   INT NOT NULL REFERENCES warehouses(warehouse_id),
    order_date     DATE NOT NULL,
    expected_date  DATE NOT NULL,
    received_date  DATE,
    status         VARCHAR(15) NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING','RECEIVED','CANCELLED')),
    CHECK (expected_date >= order_date),
    CHECK (received_date IS NULL OR received_date >= order_date),
    CHECK ((status = 'RECEIVED') = (received_date IS NOT NULL))
);

CREATE TABLE po_items (
    po_id        INT NOT NULL REFERENCES purchase_orders(po_id) ON DELETE CASCADE,
    product_id   INT NOT NULL REFERENCES products(product_id),
    quantity     INT NOT NULL CHECK (quantity > 0),
    unit_cost    NUMERIC(10,2) NOT NULL CHECK (unit_cost >= 0),
    PRIMARY KEY (po_id, product_id)
);

-- ---------- Transaction history (audit trail of every stock movement) ----------

CREATE TABLE stock_transactions (
    txn_id        BIGSERIAL PRIMARY KEY,
    product_id    INT NOT NULL REFERENCES products(product_id),
    warehouse_id  INT NOT NULL REFERENCES warehouses(warehouse_id),
    txn_type      VARCHAR(10) NOT NULL CHECK (txn_type IN ('IN','OUT','ADJUST')),
    quantity      INT NOT NULL CHECK (quantity <> 0),
    po_id         INT REFERENCES purchase_orders(po_id),
    txn_time      TIMESTAMP NOT NULL DEFAULT now(),
    note          VARCHAR(200)
);

-- ---------- Indexes (foreign keys are not auto-indexed in PostgreSQL) ----------

CREATE INDEX idx_products_category    ON products(category_id);
CREATE INDEX idx_po_supplier          ON purchase_orders(supplier_id);
CREATE INDEX idx_po_order_date        ON purchase_orders(order_date);
CREATE INDEX idx_po_items_product     ON po_items(product_id);
CREATE INDEX idx_txn_product_time     ON stock_transactions(product_id, txn_time DESC);
CREATE INDEX idx_txn_time             ON stock_transactions(txn_time);
CREATE INDEX idx_stock_warehouse      ON stock(warehouse_id);
-- Partial index: only the few POs still open
CREATE INDEX idx_po_pending           ON purchase_orders(expected_date) WHERE status = 'PENDING';

-- ---------- Stored procedure: atomic stock issue ----------
-- Updates stock and writes the ledger row in ONE transaction; the row lock serializes
-- concurrent issues of the same item and CHECK(quantity >= 0) blocks overdrawing.
CREATE OR REPLACE PROCEDURE issue_stock(p_product INT, p_wh INT, p_qty INT, p_note TEXT DEFAULT 'Issue')
LANGUAGE plpgsql AS $$
BEGIN
    -- row lock so concurrent issues for the same item serialize
    PERFORM 1 FROM stock WHERE product_id = p_product AND warehouse_id = p_wh FOR UPDATE;

    UPDATE stock SET quantity = quantity - p_qty, updated_at = now()
    WHERE product_id = p_product AND warehouse_id = p_wh;   -- CHECK(quantity >= 0) guards overdraw

    INSERT INTO stock_transactions(product_id,warehouse_id,txn_type,quantity,note)
    VALUES (p_product, p_wh, 'OUT', -p_qty, p_note);
END $$;

