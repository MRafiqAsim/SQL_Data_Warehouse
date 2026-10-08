# SQL Data Warehouse

A sales data warehouse on **Microsoft SQL Server**, built with the **medallion architecture**: raw CSV exports from a CRM and an ERP system are loaded into a Bronze layer, cleaned and standardised in a Silver layer, and modelled into a star schema in a Gold layer for reporting.

## Architecture

```
CRM (CSV) ─┐                                                   ┌─► reporting / BI
           ├─► BRONZE ──────────► SILVER ───────────► GOLD ────┤
ERP (CSV) ─┘    raw, as-is          cleaned,            star     └─► ad-hoc SQL analysis
                (BULK INSERT)       standardised        schema
```

| Layer | Purpose | Load | Status |
|---|---|---|---|
| **Bronze** | Raw copies of the source files, unchanged, for traceability | Truncate and `BULK INSERT` from CSV (`bronze.load_bronze`) | ✅ Done |
| **Silver** | Cleaned, standardised and de-duplicated tables with consistent types | Stored procedure (`silver.load_silver`) | 🚧 Tables defined, load in progress |
| **Gold** | Business-ready star schema: customer and product dimensions, sales fact | Views over Silver | 🗓️ Planned |

### Source data

Two source systems, six tables:

| System | Table | Content |
|---|---|---|
| CRM | `crm_cust_info` | Customers |
| CRM | `crm_prd_info` | Products and their history |
| CRM | `crm_sales_details` | Sales orders |
| ERP | `erp_cust_az12` | Customer birth date and gender |
| ERP | `erp_loc_a101` | Customer country |
| ERP | `erp_px_cat_g1v2` | Product categories and maintenance flag |

Tables are named `<source>_<entity>` in every layer, so lineage from Bronze to Gold stays obvious.

## Run it

You need SQL Server 2019+ — locally, or in Docker:

```bash
docker run -d --name sqlserver -p 1433:1433 \
  -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='<YourStrong!Passw0rd>' \
  mcr.microsoft.com/mssql/server:2022-latest
```

Download the six source CSVs (from the course's public dataset, MIT-licensed) and copy them into the container root, where the Bronze load expects them:

```bash
BASE=https://raw.githubusercontent.com/DataWithBaraa/sql-data-warehouse-project/main/datasets
for f in source_crm/cust_info source_crm/prd_info source_crm/sales_details \
         source_erp/CUST_AZ12 source_erp/LOC_A101 source_erp/PX_CAT_G1V2; do
  curl -sSfo "$(basename $f).csv" "$BASE/$f.csv"
  docker cp "$(basename $f).csv" sqlserver:/
done
```

Then run the scripts in order (SQL Server Management Studio, Azure Data Studio or `sqlcmd`):

| Step | Script | What it does |
|---|---|---|
| 1 | [`scripts/init_database.sql`](scripts/init_database.sql) | Creates the `DataWarehouse` database with `bronze`, `silver` and `gold` schemas (drops it first if it exists) |
| 2 | [`scripts/bronze/ddl_bronze.sql`](scripts/bronze/ddl_bronze.sql) | Creates the Bronze tables |
| 3 | [`scripts/bronze/proc_load_bronze.sql`](scripts/bronze/proc_load_bronze.sql) | Creates `bronze.load_bronze`; run it with `EXEC bronze.load_bronze;` |
| 4 | [`scripts/silver/ddl_silver.sql`](scripts/silver/ddl_silver.sql) | Creates the Silver tables (with a `dwh_create_date` audit column) |

The Bronze load truncates and reloads every table, logs the duration of each load and of the whole batch, and reports errors through `TRY…CATCH`.

> ⚠️ `init_database.sql` drops and recreates the `DataWarehouse` database. Run it only where losing that database is fine.

## Project structure

```
scripts/
├── init_database.sql      # database and schemas
├── bronze/                # raw tables and the CSV load procedure
└── silver/                # cleaned tables
```

## Roadmap

- [ ] Silver load procedure: de-duplication, trimming, code normalisation (gender, marital status, country), date fixes and derived columns
- [ ] Gold star schema: `dim_customers`, `dim_products`, `fact_sales` as views
- [ ] Data-quality checks per layer (keys, nulls, ranges, referential integrity)
- [ ] Data catalog for the Gold layer
- [ ] CI that builds the warehouse in a SQL Server container and runs the checks

## Acknowledgements

Built while learning from [Data With Baraa](https://www.youtube.com/@datawithbaraa)'s SQL Data Warehouse course, whose public materials provided the dataset and the starting point for the database setup and table definitions.

## License

[MIT](LICENSE)
