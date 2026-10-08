#!/usr/bin/env bash
# Build the whole warehouse in a running SQL Server container and run the data-quality checks.
#
#   CONTAINER=sqlserver MSSQL_SA_PASSWORD='<password>' ./ci/build_and_test.sh
#
# Steps: download the source CSVs -> create database and schemas -> Bronze tables + load
# -> Silver tables + load -> Gold views -> Silver and Gold quality checks.
set -euo pipefail

CONTAINER="${CONTAINER:-sqlserver}"
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_URL="https://raw.githubusercontent.com/DataWithBaraa/sql-data-warehouse-project/main/datasets"
SQLCMD=(docker exec "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -b)

echo "==> Waiting for SQL Server"
for _ in $(seq 1 60); do
  "${SQLCMD[@]}" -Q "SELECT 1" >/dev/null 2>&1 && break
  sleep 3
done

echo "==> Downloading the source data"
tmp="$(mktemp -d)"
for f in source_crm/cust_info source_crm/prd_info source_crm/sales_details \
         source_erp/CUST_AZ12 source_erp/LOC_A101 source_erp/PX_CAT_G1V2; do
  curl -sSfo "$tmp/$(basename "$f").csv" "$DATA_URL/$f.csv"
  docker cp "$tmp/$(basename "$f").csv" "$CONTAINER:/"
done

docker exec -u 0 "$CONTAINER" mkdir -p /dwh
docker cp "$ROOT/scripts" "$CONTAINER:/dwh/"
docker cp "$ROOT/tests" "$CONTAINER:/dwh/"

run() { echo "==> $1"; "${SQLCMD[@]}" -d "$2" -i "/dwh/$1"; }
run scripts/init_database.sql master
run scripts/bronze/ddl_bronze.sql DataWarehouse
run scripts/bronze/proc_load_bronze.sql DataWarehouse
echo "==> EXEC bronze.load_bronze"; "${SQLCMD[@]}" -d DataWarehouse -Q "EXEC bronze.load_bronze" >/dev/null
run scripts/silver/ddl_silver.sql DataWarehouse
run scripts/silver/proc_load_silver.sql DataWarehouse
echo "==> EXEC silver.load_silver"; "${SQLCMD[@]}" -d DataWarehouse -Q "EXEC silver.load_silver"
run scripts/gold/ddl_gold.sql DataWarehouse
run tests/quality_checks_silver.sql DataWarehouse
run tests/quality_checks_gold.sql DataWarehouse
echo "==> Warehouse built and all data-quality checks passed"
