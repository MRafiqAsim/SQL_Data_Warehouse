/*
===============================================================================
Data-quality checks: Gold layer
===============================================================================
Checks the star schema: unique surrogate keys, every fact row linked to both
dimensions, and nothing lost between Silver and Gold. All counts must be zero;
the script raises an error if any check fails.

    sqlcmd -d DataWarehouse -b -i tests/quality_checks_gold.sql
===============================================================================
*/
SET NOCOUNT ON;
DECLARE @checks TABLE (check_name NVARCHAR(200), failures INT);

INSERT INTO @checks
SELECT 'dim_customers: surrogate key unique', COUNT(*) - COUNT(DISTINCT customer_key)
FROM gold.dim_customers;

INSERT INTO @checks
SELECT 'dim_customers: one row per customer', COUNT(*) - COUNT(DISTINCT customer_id)
FROM gold.dim_customers;

INSERT INTO @checks
SELECT 'dim_products: surrogate key unique', COUNT(*) - COUNT(DISTINCT product_key)
FROM gold.dim_products;

INSERT INTO @checks
SELECT 'dim_products: one current version per product', COUNT(*) - COUNT(DISTINCT product_number)
FROM gold.dim_products;

INSERT INTO @checks
SELECT 'fact_sales: every row linked to a customer', COUNT(*)
FROM gold.fact_sales WHERE customer_key IS NULL;

INSERT INTO @checks
SELECT 'fact_sales: every row linked to a product', COUNT(*)
FROM gold.fact_sales WHERE product_key IS NULL;

INSERT INTO @checks
SELECT 'fact_sales: no rows lost or duplicated from Silver',
       ABS((SELECT COUNT(*) FROM gold.fact_sales) - (SELECT COUNT(*) FROM silver.crm_sales_details));

INSERT INTO @checks
SELECT 'fact_sales: revenue reconciles with Silver',
       CASE WHEN (SELECT SUM(CAST(sales_amount AS BIGINT)) FROM gold.fact_sales)
              = (SELECT SUM(CAST(sls_sales AS BIGINT)) FROM silver.crm_sales_details)
            THEN 0 ELSE 1 END;

SELECT CASE WHEN failures = 0 THEN 'PASS' ELSE 'FAIL' END AS status, failures, check_name
FROM @checks;

IF EXISTS (SELECT 1 FROM @checks WHERE failures > 0)
    THROW 50002, 'Gold data-quality checks failed', 1;
