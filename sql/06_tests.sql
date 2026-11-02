-- ============================================================
-- 06_tests.sql : data-integrity & constraint tests
-- Every check RAISEs an EXCEPTION on failure, so with ON_ERROR_STOP the
-- script exits non-zero (this is what CI relies on).
-- ============================================================
\set ON_ERROR_STOP on
SET search_path = inventory;
SET client_min_messages = NOTICE;

\echo '=== Data-integrity tests ==='
DO $$
DECLARE n BIGINT;
BEGIN
    -- 1. The stock table must equal the sum of the transaction ledger, in both directions
    SELECT count(*) INTO n
    FROM stock s
    FULL JOIN (SELECT product_id, warehouse_id, SUM(quantity) AS q
               FROM stock_transactions GROUP BY 1,2) t USING (product_id, warehouse_id)
    WHERE COALESCE(s.quantity,0) <> COALESCE(t.q,0);
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL [1]: % stock rows disagree with the ledger', n; END IF;
    RAISE NOTICE 'PASS [1]: stock table reconciles with the transaction ledger';

    -- 2. No negative stock anywhere
    SELECT count(*) INTO n FROM stock WHERE quantity < 0;
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL [2]: % negative stock rows', n; END IF;
    RAISE NOTICE 'PASS [2]: no negative stock';

    -- 3. Every item on a RECEIVED purchase order has a matching IN transaction
    SELECT count(*) INTO n
    FROM purchase_orders po JOIN po_items pi USING (po_id)
    WHERE po.status = 'RECEIVED'
      AND NOT EXISTS (SELECT 1 FROM stock_transactions t
                      WHERE t.po_id = po.po_id AND t.product_id = pi.product_id
                        AND t.txn_type = 'IN' AND t.quantity = pi.quantity);
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL [3]: % received PO items missing an IN transaction', n; END IF;
    RAISE NOTICE 'PASS [3]: every received PO item has a matching IN transaction';

    -- 4. Cancelled / pending POs never touched stock
    SELECT count(*) INTO n
    FROM stock_transactions t JOIN purchase_orders po USING (po_id)
    WHERE po.status <> 'RECEIVED';
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL [4]: % transactions reference non-received POs', n; END IF;
    RAISE NOTICE 'PASS [4]: only RECEIVED purchase orders post stock';

    -- 5. Suppliers are only ordered products they actually supply
    SELECT count(*) INTO n
    FROM purchase_orders po JOIN po_items pi USING (po_id)
    WHERE NOT EXISTS (SELECT 1 FROM product_suppliers ps
                      WHERE ps.supplier_id = po.supplier_id AND ps.product_id = pi.product_id);
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL [5]: % PO items from a supplier that does not supply the product', n; END IF;
    RAISE NOTICE 'PASS [5]: PO items match the supplier catalogue';

    -- 6. No warehouse is over capacity
    SELECT count(*) INTO n
    FROM warehouses w JOIN (SELECT warehouse_id, SUM(quantity) q FROM stock GROUP BY 1) s USING (warehouse_id)
    WHERE s.q > w.capacity;
    IF n <> 0 THEN RAISE EXCEPTION 'FAIL [6]: % warehouses over capacity', n; END IF;
    RAISE NOTICE 'PASS [6]: no warehouse exceeds its capacity';
END $$;

\echo '=== Constraint tests (each bad statement MUST be rejected) ==='
DO $$
DECLARE before_cnt BIGINT;
BEGIN
    BEGIN
        UPDATE stock SET quantity = -1 WHERE product_id = 1 AND warehouse_id = 1;
        RAISE EXCEPTION 'FAIL [7]: negative stock accepted';
    EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [7]: CHECK rejects negative stock'; END;

    BEGIN
        INSERT INTO products(sku,name,category_id,unit_price) VALUES ('SKU-0001','dup',1,10);
        RAISE EXCEPTION 'FAIL [8]: duplicate SKU accepted';
    EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'PASS [8]: UNIQUE rejects duplicate SKU'; END;

    BEGIN
        INSERT INTO po_items(po_id,product_id,quantity,unit_cost) VALUES (999999,1,5,10);
        RAISE EXCEPTION 'FAIL [9]: orphan PO item accepted';
    EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'PASS [9]: FOREIGN KEY rejects orphan PO item'; END;

    BEGIN
        INSERT INTO purchase_orders(supplier_id,warehouse_id,order_date,expected_date,status)
        VALUES (1,1,'2025-05-10','2025-05-01','PENDING');
        RAISE EXCEPTION 'FAIL [10]: expected_date before order_date accepted';
    EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [10]: CHECK rejects expected_date < order_date'; END;

    BEGIN
        INSERT INTO purchase_orders(supplier_id,warehouse_id,order_date,expected_date,status)
        VALUES (1,1,'2025-05-01','2025-05-05','RECEIVED');   -- RECEIVED but no received_date
        RAISE EXCEPTION 'FAIL [11]: RECEIVED PO without received_date accepted';
    EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [11]: CHECK ties status RECEIVED to received_date'; END;

    BEGIN
        INSERT INTO suppliers(name,rating) VALUES ('Bad Rating Co', 9);
        RAISE EXCEPTION 'FAIL [12]: rating 9 accepted';
    EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [12]: CHECK limits supplier rating to 0-5'; END;

    -- 13. issue_stock() is atomic: an overdraw must fail AND leave no ledger row behind
    SELECT count(*) INTO before_cnt FROM stock_transactions;
    BEGIN
        CALL issue_stock(1, 1, 100000000, 'overdraw test');
        RAISE EXCEPTION 'FAIL [13]: overdraw accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
    IF (SELECT count(*) FROM stock_transactions) <> before_cnt THEN
        RAISE EXCEPTION 'FAIL [13]: failed issue_stock() left a ledger row behind';
    END IF;
    RAISE NOTICE 'PASS [13]: issue_stock() is atomic (overdraw rejected, no partial write)';
END $$;

\echo '=== ALL TESTS PASSED ==='
