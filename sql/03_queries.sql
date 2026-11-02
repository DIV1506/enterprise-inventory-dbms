-- ============================================================
-- 03_queries.sql : analytical queries
-- ============================================================
SET search_path = inventory;

\echo '=== Q1. Reorder report: items below reorder level per warehouse, with best supplier ==='
SELECT w.name AS warehouse, p.sku, c.name AS category,
       s.quantity AS on_hand, p.reorder_level,
       p.reorder_level * 2 - s.quantity AS suggested_order_qty,
       best.supplier AS cheapest_supplier, best.unit_cost, best.lead_time_days
FROM stock s
JOIN products p   ON p.product_id   = s.product_id
JOIN categories c ON c.category_id  = p.category_id
JOIN warehouses w ON w.warehouse_id = s.warehouse_id
JOIN LATERAL (
    SELECT sup.name AS supplier, ps.unit_cost, ps.lead_time_days
    FROM product_suppliers ps JOIN suppliers sup USING (supplier_id)
    WHERE ps.product_id = p.product_id
    ORDER BY ps.unit_cost LIMIT 1
) best ON TRUE
WHERE s.quantity < p.reorder_level
ORDER BY (p.reorder_level - s.quantity) DESC;

\echo '=== Q2. Supplier performance: on-time delivery rate & average delay ==='
SELECT s.name AS supplier,
       COUNT(*)                                             AS received_orders,
       ROUND(100.0 * AVG((po.received_date <= po.expected_date)::int), 1) AS on_time_pct,
       ROUND(AVG(GREATEST(po.received_date - po.expected_date, 0)), 2)    AS avg_days_late,
       ROUND(SUM(pi.quantity * pi.unit_cost), 2)            AS total_spend
FROM purchase_orders po
JOIN suppliers s  ON s.supplier_id = po.supplier_id
JOIN po_items pi  ON pi.po_id      = po.po_id
WHERE po.status = 'RECEIVED'
GROUP BY s.supplier_id, s.name
ORDER BY on_time_pct DESC, total_spend DESC;

\echo '=== Q3. Monthly stock movement (IN vs OUT) ==='
SELECT to_char(date_trunc('month', txn_time), 'YYYY-MM') AS month,
       SUM(quantity) FILTER (WHERE txn_type = 'IN')      AS units_in,
       -SUM(quantity) FILTER (WHERE txn_type = 'OUT')    AS units_out,
       SUM(quantity)                                     AS net_change
FROM stock_transactions
WHERE txn_type <> 'ADJUST'
GROUP BY 1
ORDER BY 1;

\echo '=== Q4. Inventory value by category (stock x unit price) ==='
SELECT c.name AS category,
       SUM(s.quantity)                         AS units,
       ROUND(SUM(s.quantity * p.unit_price),2) AS inventory_value
FROM stock s
JOIN products p   ON p.product_id  = s.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY c.name
ORDER BY inventory_value DESC;

\echo '=== Q5. Full transaction history of one product (running balance via window fn) ==='
SELECT txn_time::date AS date, txn_type, quantity,
       SUM(quantity) OVER (ORDER BY txn_time, txn_id) AS running_balance
FROM stock_transactions
WHERE product_id = 3 AND warehouse_id = 1
ORDER BY txn_time, txn_id
LIMIT 12;

\echo '=== Q6. Inventory turnover: units issued vs current stock (top 5 fastest movers) ==='
WITH t AS (
    SELECT p.sku, p.name,
           COALESCE(-SUM(st.quantity) FILTER (WHERE st.txn_type='OUT'),0) AS units_out,
           (SELECT SUM(quantity) FROM stock x WHERE x.product_id = p.product_id) AS on_hand
    FROM products p LEFT JOIN stock_transactions st USING (product_id)
    GROUP BY p.product_id, p.sku, p.name
)
SELECT sku, name, units_out, on_hand,
       ROUND(units_out::numeric / NULLIF(on_hand,0), 3) AS turnover_ratio,
       RANK() OVER (ORDER BY units_out::numeric / NULLIF(on_hand,0) DESC) AS turnover_rank
FROM t
ORDER BY turnover_rank
LIMIT 5;

\echo '=== Q7. Cheapest supplier per product (subquery / DISTINCT ON) ==='
SELECT DISTINCT ON (p.product_id)
       p.sku, s.name AS cheapest_supplier, ps.unit_cost, ps.lead_time_days
FROM products p
JOIN product_suppliers ps ON ps.product_id  = p.product_id
JOIN suppliers s          ON s.supplier_id  = ps.supplier_id
ORDER BY p.product_id, ps.unit_cost, ps.lead_time_days
LIMIT 10;

\echo '=== Q8. Ledger reconciliation: stock table vs sum of transactions (expect 0 rows) ==='
SELECT s.product_id, s.warehouse_id, s.quantity AS stock_qty, t.ledger_qty
FROM stock s
JOIN (SELECT product_id, warehouse_id, SUM(quantity) AS ledger_qty
      FROM stock_transactions GROUP BY 1,2) t
  USING (product_id, warehouse_id)
WHERE s.quantity <> t.ledger_qty;
