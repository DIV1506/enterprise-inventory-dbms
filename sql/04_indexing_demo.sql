-- ============================================================
-- 04_indexing_demo.sql : measure the effect of indexing
-- Run AFTER 01-03. Shows EXPLAIN ANALYZE with and without an index.
-- ============================================================
SET search_path = inventory;

-- Make the table big enough that the planner cares (~250k extra rows)
INSERT INTO stock_transactions(product_id,warehouse_id,txn_type,quantity,txn_time,note)
SELECT 1 + floor(random()*48)::int, 1 + floor(random()*3)::int, 'OUT', -1,
       timestamp '2024-01-01' + random() * interval '700 days', 'bulk load for index demo'
FROM generate_series(1,250000);
ANALYZE stock_transactions;

\echo '=== WITHOUT index: filter by product + date range ==='
DROP INDEX IF EXISTS idx_txn_product_time;
DROP INDEX IF EXISTS idx_txn_time;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT * FROM stock_transactions
WHERE product_id = 7 AND txn_time BETWEEN '2025-03-01' AND '2025-03-31';

\echo '=== WITH composite index (product_id, txn_time) ==='
CREATE INDEX idx_txn_product_time ON stock_transactions(product_id, txn_time DESC);
CREATE INDEX idx_txn_time         ON stock_transactions(txn_time);
ANALYZE stock_transactions;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF)
SELECT * FROM stock_transactions
WHERE product_id = 7 AND txn_time BETWEEN '2025-03-01' AND '2025-03-31';

-- Clean up the synthetic rows so other scripts still reconcile
DELETE FROM stock_transactions WHERE note = 'bulk load for index demo';
