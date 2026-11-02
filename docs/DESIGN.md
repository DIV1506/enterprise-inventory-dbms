# Design decisions

## 1. Normalization (3NF)
- Every non-key column depends on the key, the whole key and nothing but the key.
- Supplier details live in `suppliers` only; product category in `categories` only.
- **Many-to-many:** a product can have several suppliers and a supplier many products. This is resolved with `product_suppliers (product_id, supplier_id)`, a composite primary key that also carries the facts about the *relationship* (`unit_cost`, `lead_time_days`).
- **Stock is keyed by (product, warehouse)**, so one product can sit in several warehouses without repeating product data.

## 2. Stock table *and* a transaction ledger
| | `stock` | `stock_transactions` |
|---|---|---|
| Purpose | Fast "how many do we have now?" | Audit trail of every movement |
| Write pattern | Updated in place | Append-only |
| Truth | Derived | Source of truth |

Keeping both is a deliberate, controlled denormalization: reads of current stock don't have to sum the entire ledger. The risk is drift between the two, so:
- `issue_stock()` updates both inside one transaction, and
- test `[1]` in `06_tests.sql` verifies they agree (in both directions) after every run.

## 3. Constraints as the last line of defence
Application bugs happen; the database should refuse bad data anyway.
- `CHECK (quantity >= 0)` on `stock`: overselling is impossible, even under concurrency.
- `CHECK ((status = 'RECEIVED') = (received_date IS NOT NULL))`: a PO can't be "received" without a date, or have a date without being received.
- `CHECK (expected_date >= order_date)`, `rating BETWEEN 0 AND 5`, `unit_price >= 0`, and so on.
- `UNIQUE (sku)`: no duplicate products.

## 4. Indexing strategy
PostgreSQL does **not** index foreign-key columns automatically, so FK columns used in joins get an index (`idx_products_category`, `idx_po_supplier`, `idx_po_items_product`, ...).
- **Composite `(product_id, txn_time DESC)`**: serves "history of one product in a date range" with a single index scan. The equality column goes first, the range column second.
- **Partial index** `WHERE status = 'PENDING'`: only a small fraction of POs are open, so the index stays tiny.
- Index choices are justified with `EXPLAIN ANALYZE` (`sql/04_indexing_demo.sql`).
- Trade-off: every index slows writes slightly and uses disk; indexes were added only for queries that need them.

## 5. Concurrency
- `issue_stock()` takes a row lock (`SELECT ... FOR UPDATE`) so two concurrent issues of the same item are serialized, not interleaved. Without it, both could read 100, both subtract, and one update would be lost.
- Default isolation is `READ COMMITTED`; `REPEATABLE READ` gives a stable snapshot for reports.
- **Deadlocks** happen when sessions take locks in different orders. PostgreSQL detects and aborts one. The fix is application-side: always lock rows in the same order (demo 4).

## 6. Seed data
Deterministic (`setseed`) and **consistent by construction**: `stock` is computed from the ledger, POs only contain products the supplier actually supplies, and only RECEIVED POs create IN transactions. The test suite found one real flaw while this repo was being built (a warehouse over capacity caused by uneven random distribution), which was fixed in the seed.

## 7. What I'd add next
- Table partitioning of `stock_transactions` by month once it grows large.
- Row-level security / roles (read-only analyst vs warehouse operator).
- A materialized view for the inventory-value dashboard, refreshed on a schedule.
- A thin API (FastAPI / Node) on top.
