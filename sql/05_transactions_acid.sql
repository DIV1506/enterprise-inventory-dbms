-- ============================================================
-- 05_transactions_acid.sql : ACID demonstrations (single session)
-- For the two-session concurrency demo see scripts/concurrency_demo.sh
-- ============================================================
SET search_path = inventory;

-- (issue_stock() is defined in 01_schema.sql)

-- ---------- ATOMICITY: all-or-nothing ----------
\echo '=== A: Atomicity - transfer stock between warehouses, fail midway, everything rolls back ==='
SELECT warehouse_id, quantity FROM stock WHERE product_id = 1 ORDER BY 1;
\echo '(the next statement is EXPECTED to fail - that is the point of the demo)'
\set ON_ERROR_STOP off
BEGIN;
  UPDATE stock SET quantity = quantity - 50 WHERE product_id = 1 AND warehouse_id = 1;
  UPDATE stock SET quantity = quantity + 50 WHERE product_id = 1 AND warehouse_id = 2;
  UPDATE stock SET quantity = -1 WHERE product_id = 1 AND warehouse_id = 3;  -- violates CHECK(quantity>=0) -> transaction aborts
ROLLBACK;
\set ON_ERROR_STOP on
\echo '--- after rollback, balances unchanged:'
SELECT warehouse_id, quantity FROM stock WHERE product_id = 1 ORDER BY 1;

-- ---------- CONSISTENCY: constraints reject bad data ----------
\echo '=== C: Consistency - constraint violations are rejected ==='
DO $$
BEGIN
    BEGIN
        UPDATE stock SET quantity = -5 WHERE product_id = 1 AND warehouse_id = 1;
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'Rejected negative stock: %', SQLERRM;
    END;
    BEGIN
        INSERT INTO products(sku,name,category_id,unit_price) VALUES ('SKU-0001','dup',1,10);
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE 'Rejected duplicate SKU: %', SQLERRM;
    END;
    BEGIN
        INSERT INTO po_items(po_id,product_id,quantity,unit_cost) VALUES (999999,1,5,10);
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'Rejected orphan PO item: %', SQLERRM;
    END;
END $$;

-- ---------- SAVEPOINT: partial rollback ----------
\echo '=== Savepoint: keep the first change, undo only the second ==='
BEGIN;
  CALL issue_stock(2, 1, 5, 'first issue (kept)');
  SAVEPOINT sp1;
  CALL issue_stock(2, 1, 7, 'second issue (undone)');
  ROLLBACK TO SAVEPOINT sp1;
COMMIT;
SELECT txn_type, quantity, note FROM stock_transactions
WHERE product_id = 2 AND warehouse_id = 1 AND note LIKE '%issue (%' ORDER BY txn_id;

-- ---------- DURABILITY note ----------
-- Once COMMIT returns, the change is flushed to the write-ahead log (WAL),
-- so it survives a crash. synchronous_commit = on (default) guarantees this.
SHOW synchronous_commit;

-- ---------- Final check: ledger still reconciles ----------
\echo '=== Reconciliation after demos (expect 0 rows) ==='
SELECT s.product_id, s.warehouse_id, s.quantity, t.q AS ledger
FROM stock s JOIN (SELECT product_id,warehouse_id,SUM(quantity) q
                   FROM stock_transactions GROUP BY 1,2) t USING (product_id,warehouse_id)
WHERE s.quantity <> t.q;
