# Enterprise Inventory DBMS - developer shortcuts
# Connection settings use the standard libpq variables; override on the command line, e.g.
#   make all PGHOST=/tmp PGPORT=5433
export PGHOST     ?= localhost
export PGPORT     ?= 5432
export PGUSER     ?= postgres
export PGPASSWORD ?= postgres
export PGDATABASE ?= inventory_db

PSQL = psql -X -v ON_ERROR_STOP=1

.PHONY: help up down wait createdb setup test queries demo-index demo-acid demo-concurrency all ci psql clean

help:            ## Show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-18s %s\n", $$1, $$2}'

up:              ## Start PostgreSQL in Docker
	docker compose up -d
	@$(MAKE) --no-print-directory wait

down:            ## Stop PostgreSQL (data is kept in a Docker volume)
	docker compose down

clean:           ## Stop PostgreSQL and delete its data volume
	docker compose down -v

wait:            ## Wait until PostgreSQL accepts connections
	@for i in $$(seq 1 30); do pg_isready -q && exit 0; sleep 1; done; echo "PostgreSQL not reachable"; exit 1

createdb:        ## (Re)create the empty database
	@psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $(PGDATABASE)" -c "CREATE DATABASE $(PGDATABASE)"

setup: createdb  ## Create database, schema, constraints, indexes and sample data
	$(PSQL) -q -f sql/01_schema.sql
	$(PSQL) -q -f sql/02_seed_data.sql > /dev/null
	@echo "Database '$(PGDATABASE)' ready."

test:            ## Run data-integrity and constraint tests
	$(PSQL) -f sql/06_tests.sql

queries:         ## Run the analytical queries
	$(PSQL) -f sql/03_queries.sql

demo-index:      ## EXPLAIN ANALYZE with / without an index
	$(PSQL) -f sql/04_indexing_demo.sql

demo-acid:       ## Atomicity, consistency, savepoints, durability
	$(PSQL) -f sql/05_transactions_acid.sql

demo-concurrency: ## Two live sessions: locking, isolation levels, deadlock
	./scripts/concurrency_demo.sh

all: setup test queries demo-index demo-acid demo-concurrency  ## Everything end to end (tests run before AND after the demos)
	@$(MAKE) --no-print-directory test

ci: all          ## Same as 'all' (used by GitHub Actions)

psql:            ## Open an interactive psql shell on the database
	psql -d $(PGDATABASE)
