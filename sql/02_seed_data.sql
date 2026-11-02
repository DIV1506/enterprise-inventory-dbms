-- ============================================================
-- 02_seed_data.sql : sample data (deterministic via setseed)
-- Stock levels are DERIVED from the transaction log, so the
-- ledger and the stock table always reconcile.
-- ============================================================
SET search_path = inventory;
SELECT setseed(0.42);

INSERT INTO categories(name) VALUES
 ('Electrical Components'),('Mechanical Parts'),('Safety Equipment'),
 ('Tools'),('Packaging'),('Office Supplies');

INSERT INTO suppliers(name,email,phone,city,rating) VALUES
 ('Apex Industrial Supply','sales@apex.example','+91-674-100001','Bhubaneswar',4.5),
 ('BlueLine Components','orders@blueline.example','+91-674-100002','Cuttack',4.1),
 ('Coastal Traders','info@coastal.example','+91-674-100003','Visakhapatnam',3.6),
 ('Delta Mechanicals','sales@delta.example','+91-674-100004','Kolkata',4.8),
 ('Eastern Safety Co','hello@easternsafety.example','+91-674-100005','Ranchi',3.9),
 ('Fortune Packaging','po@fortune.example','+91-674-100006','Raipur',3.2),
 ('Gamma Tools Ltd','sales@gamma.example','+91-674-100007','Bhubaneswar',4.3),
 ('Horizon Office Mart','care@horizon.example','+91-674-100008','Puri',2.9);

INSERT INTO warehouses(name,city,capacity) VALUES
 ('Central Warehouse','Bhubaneswar',60000),
 ('East Depot','Kolkata',40000),
 ('South Depot','Visakhapatnam',35000);

-- 48 products spread across the 6 categories
INSERT INTO products(sku,name,category_id,unit_price,reorder_level)
SELECT 'SKU-' || lpad(g::text,4,'0'),
       'Product ' || g,
       ((g - 1) % 6) + 1,
       round((50 + random()*4950)::numeric, 2),
       20 + (random()*60)::int
FROM generate_series(1,48) g;

-- every product has 2 suppliers (primary + alternate)
INSERT INTO product_suppliers(product_id,supplier_id,unit_cost,lead_time_days)
SELECT p.product_id, s.supplier_id,
       round((p.unit_price * (0.55 + random()*0.25))::numeric, 2),
       2 + (random()*12)::int
FROM products p
JOIN LATERAL (
    SELECT supplier_id FROM suppliers
    ORDER BY md5(p.product_id::text || supplier_id::text) LIMIT 2
) s ON TRUE;

-- ---------- Opening balance: ADJUST txn per product/warehouse ----------
INSERT INTO stock_transactions(product_id,warehouse_id,txn_type,quantity,txn_time,note)
SELECT p.product_id, w.warehouse_id, 'ADJUST',
       100 + (random()*200)::int,
       timestamp '2025-01-01 09:00', 'Opening balance'
FROM products p CROSS JOIN warehouses w;

-- ---------- Purchase orders: 240 POs across 2025 ----------
INSERT INTO purchase_orders(supplier_id,warehouse_id,order_date,expected_date,received_date,status)
SELECT supplier_id, warehouse_id, od,
       od + lead,
       CASE WHEN st = 'RECEIVED' THEN od + lead + delay END,
       st
FROM (
    SELECT 1 + floor(random()*8)::int          AS supplier_id,
           1 + floor(random()*3)::int          AS warehouse_id,
           date '2025-01-05' + (random()*330)::int AS od,
           3 + (random()*10)::int              AS lead,
           -- delayed deliveries: 0 days (on time) up to 8 days late; weighted toward on-time
           CASE WHEN random() < 0.6 THEN 0 ELSE (random()*8)::int END AS delay,
           CASE WHEN random() < 0.08 THEN 'CANCELLED'
                WHEN random() < 0.12 THEN 'PENDING'
                ELSE 'RECEIVED' END            AS st
    FROM generate_series(1,240)
) x;

-- 2-5 line items per PO, only products that supplier actually supplies
INSERT INTO po_items(po_id,product_id,quantity,unit_cost)
SELECT po.po_id, ps.product_id, 20 + (random()*180)::int, ps.unit_cost
FROM purchase_orders po
JOIN LATERAL (
    SELECT product_id, unit_cost FROM product_suppliers
    WHERE supplier_id = po.supplier_id
    ORDER BY random() LIMIT (2 + (random()*3)::int)
) ps ON TRUE;

-- Received POs post an IN transaction per item
INSERT INTO stock_transactions(product_id,warehouse_id,txn_type,quantity,po_id,txn_time,note)
SELECT pi.product_id, po.warehouse_id, 'IN', pi.quantity, po.po_id,
       po.received_date + time '10:00', 'PO receipt'
FROM purchase_orders po JOIN po_items pi USING (po_id)
WHERE po.status = 'RECEIVED';

-- ---------- Sales / issues: OUT transactions during 2025 ----------
-- Quantities are small enough that stock never goes negative.
INSERT INTO stock_transactions(product_id,warehouse_id,txn_type,quantity,txn_time,note)
SELECT p.product_id, w.warehouse_id, 'OUT',
       -(1 + (random()*14)::int),
       timestamp '2025-01-10' + (random()*340) * interval '1 day',
       'Issue to production'
FROM products p CROSS JOIN warehouses w
CROSS JOIN generate_series(1,14);

-- Make a handful of products deliberately run low (to exercise reorder queries)
INSERT INTO stock_transactions(product_id,warehouse_id,txn_type,quantity,txn_time,note)
SELECT s.product_id, s.warehouse_id, 'OUT',
       -(sum_q - (random()*8)::int), timestamp '2025-12-01 12:00', 'Bulk issue'
FROM (
    SELECT product_id, warehouse_id, sum(quantity) AS sum_q
    FROM stock_transactions
    GROUP BY product_id, warehouse_id
) s
WHERE s.product_id IN (3, 9, 17, 25, 33, 41) AND s.warehouse_id = 1;

-- ---------- Derive the stock table from the ledger ----------
INSERT INTO stock(product_id,warehouse_id,quantity,updated_at)
SELECT product_id, warehouse_id, sum(quantity), max(txn_time)
FROM stock_transactions
GROUP BY product_id, warehouse_id;

ANALYZE;
