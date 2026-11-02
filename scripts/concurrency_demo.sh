#!/usr/bin/env bash
# ============================================================
# Two real database sessions competing for the same rows.
# Uses the standard PG* env vars (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE).
#   make demo-concurrency        or        ./scripts/concurrency_demo.sh
# ============================================================
set -u
PSQL="${PSQL:-psql}"
Q="$PSQL -q -At"

echo "##### Demo 1: LOST UPDATE prevented by row locking (SELECT ... FOR UPDATE) #####"
$Q -c "UPDATE inventory.stock SET quantity = 100 WHERE product_id=10 AND warehouse_id=1" >/dev/null
echo "start qty = 100.  Session A issues 30 (holds the lock 3s); Session B issues 20 one second later."

$Q >/dev/null <<'SQL' &
SET search_path=inventory;
BEGIN;
SELECT quantity FROM stock WHERE product_id=10 AND warehouse_id=1 FOR UPDATE;
SELECT pg_sleep(3);
UPDATE stock SET quantity = quantity - 30 WHERE product_id=10 AND warehouse_id=1;
COMMIT;
SQL
sleep 1
START=$(date +%s)
$Q >/dev/null <<'SQL'
SET search_path=inventory;
BEGIN;
SELECT quantity FROM stock WHERE product_id=10 AND warehouse_id=1 FOR UPDATE;   -- blocks until A commits
UPDATE stock SET quantity = quantity - 20 WHERE product_id=10 AND warehouse_id=1;
COMMIT;
SQL
END=$(date +%s)
wait
echo "Session B waited ~$((END-START))s for Session A's lock."
echo "final qty = $($Q -c "SELECT quantity FROM inventory.stock WHERE product_id=10 AND warehouse_id=1")   (expected 50 -> no lost update)"

echo
echo "##### Demo 2: ISOLATION LEVELS - non-repeatable read #####"
run_isolation () {
  LEVEL="$1"
  $Q -c "UPDATE inventory.stock SET quantity = 100 WHERE product_id=11 AND warehouse_id=1" >/dev/null
  (
    $Q <<SQL
SET search_path=inventory;
BEGIN ISOLATION LEVEL $LEVEL;
SELECT '  $LEVEL  first read : '||quantity FROM stock WHERE product_id=11 AND warehouse_id=1;
SELECT pg_sleep(2) \gset
SELECT '  $LEVEL  second read: '||quantity FROM stock WHERE product_id=11 AND warehouse_id=1;
COMMIT;
SQL
  ) &
  sleep 1
  $Q -c "UPDATE inventory.stock SET quantity = 40 WHERE product_id=11 AND warehouse_id=1" >/dev/null   # another session commits mid-transaction
  wait
}
run_isolation "READ COMMITTED"
run_isolation "REPEATABLE READ"
echo "(READ COMMITTED sees the other session's committed change; REPEATABLE READ keeps its snapshot.)"

echo
echo "##### Demo 3: DEADLOCK - two sessions lock the same two rows in OPPOSITE order #####"
$Q -c "UPDATE inventory.stock SET quantity=100 WHERE product_id IN (12,13) AND warehouse_id=1" >/dev/null
$PSQL -q 2>&1 >/dev/null <<'SQL' | sed 's/^/  [session 1] /' &
SET search_path=inventory;
BEGIN;
UPDATE stock SET quantity=quantity-1 WHERE product_id=12 AND warehouse_id=1;
SELECT pg_sleep(2) \gset
UPDATE stock SET quantity=quantity-1 WHERE product_id=13 AND warehouse_id=1;
COMMIT;
SQL
sleep 0.5
$PSQL -q 2>&1 >/dev/null <<'SQL' | sed 's/^/  [session 2] /'
SET search_path=inventory;
BEGIN;
UPDATE stock SET quantity=quantity-1 WHERE product_id=13 AND warehouse_id=1;
SELECT pg_sleep(2) \gset
UPDATE stock SET quantity=quantity-1 WHERE product_id=12 AND warehouse_id=1;
COMMIT;
SQL
wait
echo "-> PostgreSQL's deadlock detector aborted ONE session (error above); the other committed."

echo
echo "##### Demo 4: THE FIX - always lock rows in the same order => no deadlock #####"
$Q -c "UPDATE inventory.stock SET quantity=100 WHERE product_id IN (12,13) AND warehouse_id=1" >/dev/null
for i in 1 2; do
  (
    $PSQL -q 2>&1 >/dev/null <<'SQL' | sed "s/^/  [session $i] /"
SET search_path=inventory;
BEGIN;
UPDATE stock SET quantity=quantity-1 WHERE product_id=12 AND warehouse_id=1;   -- always 12 first
SELECT pg_sleep(1) \gset
UPDATE stock SET quantity=quantity-1 WHERE product_id=13 AND warehouse_id=1;   -- then 13
COMMIT;
SQL
  ) &
  sleep 0.3
done
wait
echo "-> both sessions committed, no errors. Final quantities (expected 98 and 98): $($Q -c "SELECT string_agg(quantity::text, ', ' ORDER BY product_id) FROM inventory.stock WHERE product_id IN (12,13) AND warehouse_id=1")"

# Put the demo rows back in line with the ledger so tests still pass afterwards
$Q -c "UPDATE inventory.stock s SET quantity = t.q
       FROM (SELECT product_id, warehouse_id, SUM(quantity) q FROM inventory.stock_transactions GROUP BY 1,2) t
       WHERE s.product_id=t.product_id AND s.warehouse_id=t.warehouse_id
         AND s.product_id IN (10,11,12,13)" >/dev/null
echo; echo "(demo rows restored from the ledger)"
