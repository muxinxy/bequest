#!/usr/bin/env bash
# Run the full Go backend test suite against every supported database.
# Requires local test servers:
#   - SQLite (built-in)
#   - MySQL/MariaDB reachable via TEST_DB_HOST/PORT/USER/PASS/NAME (defaults below)
#   - PostgreSQL reachable via TEST_PG_HOST/PORT/USER/PASS/NAME (defaults below)
#
# Usage:  scripts/test-all-dbs.sh   (from the repo root or server/)
set -e
cd "$(dirname "$0")/../server"

echo "==> SQLite"
go test ./...

echo "==> MySQL/MariaDB"
TEST_DB_DRIVER=mysql \
TEST_DB_HOST="${TEST_DB_HOST:-127.0.0.1}" \
TEST_DB_PORT="${TEST_DB_PORT:-3307}" \
TEST_DB_USER="${TEST_DB_USER:-bequest}" \
TEST_DB_PASS="${TEST_DB_PASS:-bequest}" \
TEST_DB_NAME="${TEST_DB_NAME:-bequest_test}" \
go test ./...

echo "==> PostgreSQL"
TEST_DB_DRIVER=postgres \
TEST_PG_HOST="${TEST_PG_HOST:-127.0.0.1}" \
TEST_PG_PORT="${TEST_PG_PORT:-5433}" \
TEST_PG_USER="${TEST_PG_USER:-bequest}" \
TEST_PG_PASS="${TEST_PG_PASS:-bequest}" \
TEST_PG_NAME="${TEST_PG_NAME:-bequest_test}" \
go test ./...

echo "All databases passed."
