# Presenting this project in an interview

## 30-second pitch
"I designed a PostgreSQL database for an enterprise inventory system: products, suppliers, multiple warehouses, purchase orders and a stock-movement ledger. It's normalized to 3NF with constraints that stop bad data, like negative stock, at the database level. I wrote analytical queries for reorder alerts and supplier performance, used `EXPLAIN ANALYZE` to prove an index cut a query from about 12 ms to 0.25 ms, and demonstrated ACID behaviour with two real concurrent sessions, including a deadlock and how to prevent it. It has automated tests and CI."

Be upfront that the data is synthetic and it's a learning/portfolio project. That is honest and perfectly fine for this level.

## Demo flow (3-5 minutes)
1. `make setup` : show the schema in `sql/01_schema.sql` (point at constraints and indexes).
2. `make test` : 13 green checks. *"If I break a rule, this fails and CI goes red."*
3. `make queries` : walk through the reorder report (Q1) and supplier on-time % (Q2).
4. `make demo-index` : show the plan flip from Seq Scan to Index Scan.
5. `make demo-concurrency` : the deadlock and the fix are the most memorable part.

## Questions you should expect (with the points to hit)

**Why did you keep both a `stock` table and a transactions table?**
Reads of current stock are fast; the ledger is the audit trail and source of truth. It's controlled denormalization, so I test that they reconcile and update both in one transaction.

**What is 3NF? Where do you see it here?**
Every non-key attribute depends on the key, the whole key, and nothing but the key. Example: supplier name is stored once in `suppliers`; `unit_cost` lives in `product_suppliers` because it depends on the (product, supplier) pair.

**Why did you add that index? How do you know it helped?**
Composite `(product_id, txn_time)`: equality column first, range second. `EXPLAIN ANALYZE` showed Parallel Seq Scan ≈12 ms vs Bitmap Index Scan ≈0.25 ms on 250k rows. Trade-off: indexes cost write speed and space.

**What is a partial index?**
An index over only the rows matching a `WHERE`. `idx_po_pending` covers only open POs, so it is small and fast.

**Explain ACID with an example from your project.**
- Atomicity: a multi-step stock transfer where one step violates a CHECK rolls everything back.
- Consistency: constraints reject negative stock, duplicate SKUs, orphan PO items.
- Isolation: `READ COMMITTED` vs `REPEATABLE READ` demo.
- Durability: committed changes are written to the WAL (`synchronous_commit = on`).

**What's a lost update and how did you prevent it?**
Two sessions read 100, each subtract, last write wins, so one issue disappears. `SELECT ... FOR UPDATE` makes the second session wait and read the fresh value, giving 50.

**What causes a deadlock and how do you avoid it?**
Sessions acquire locks in opposite order and wait on each other. PostgreSQL detects it and aborts one. Avoid by locking rows in a consistent order (demo 4) and keeping transactions short.

**`READ COMMITTED` vs `REPEATABLE READ`?**
Each statement sees the latest committed data vs the whole transaction sees one snapshot. The demo shows 100 → 40 vs 100 → 100.

**Why `LATERAL` in the reorder query?**
For each low-stock row I need the cheapest supplier for *that* product, a per-row subquery with `ORDER BY ... LIMIT 1`, which `LATERAL` makes possible.

**How would this scale?**
Partition `stock_transactions` by month, archive old partitions, add a materialized view for dashboards, read replicas for reporting. (Listed in `docs/DESIGN.md`.)

## Things to be ready to admit
- Data is synthetic; timings show the *effect* of indexing, not production numbers.
- No application layer. It's the database design/SQL part of a system.
- Be ready to run any query live: you should be able to explain every file here. If you can't explain a line, read it before the interview.
