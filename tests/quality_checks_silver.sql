/*
===============================================================================
Data-quality checks: Silver layer
===============================================================================
Every check counts the rows that violate a rule; all counts must be zero.
The script prints a PASS/FAIL report and raises an error if any check fails,
so it can gate a CI pipeline:

    sqlcmd -d DataWarehouse -b -i tests/quality_checks_silver.sql
===============================================================================
*/
SET NOCOUNT ON;
DECLARE @checks TABLE (check_name NVARCHAR(200), failures INT);

-- CRM customers ---------------------------------------------------------------
INSERT INTO @checks
SELECT 'crm_cust_info: customer id present and unique', COUNT(*)
FROM (SELECT cst_id FROM silver.crm_cust_info GROUP BY cst_id
      HAVING cst_id IS NULL OR COUNT(*) > 1) AS x;

INSERT INTO @checks
SELECT 'crm_cust_info: names trimmed', COUNT(*)
FROM silver.crm_cust_info
WHERE cst_firstname <> TRIM(cst_firstname) OR cst_lastname <> TRIM(cst_lastname);

INSERT INTO @checks
SELECT 'crm_cust_info: gender and marital status standardised', COUNT(*)
FROM silver.crm_cust_info
WHERE cst_gndr NOT IN ('Female', 'Male', 'n/a')
   OR cst_marital_status NOT IN ('Married', 'Single', 'n/a');

-- CRM products ----------------------------------------------------------------
INSERT INTO @checks
SELECT 'crm_prd_info: product id unique', COUNT(*) - COUNT(DISTINCT prd_id)
FROM silver.crm_prd_info;

INSERT INTO @checks
SELECT 'crm_prd_info: cost present and not negative', COUNT(*)
FROM silver.crm_prd_info WHERE prd_cost IS NULL OR prd_cost < 0;

INSERT INTO @checks
SELECT 'crm_prd_info: product line standardised', COUNT(*)
FROM silver.crm_prd_info
WHERE prd_line NOT IN ('Mountain', 'Road', 'Other Sales', 'Touring', 'n/a');

INSERT INTO @checks
SELECT 'crm_prd_info: versions end before they start', COUNT(*)
FROM silver.crm_prd_info WHERE prd_end_dt < prd_start_dt;

INSERT INTO @checks
SELECT 'crm_prd_info: exactly one current version per product', COUNT(*)
FROM (SELECT prd_key FROM silver.crm_prd_info GROUP BY prd_key
      HAVING SUM(CASE WHEN prd_end_dt IS NULL THEN 1 ELSE 0 END) <> 1) AS x;

-- CRM sales -------------------------------------------------------------------
INSERT INTO @checks
SELECT 'crm_sales_details: order date not after ship / due date', COUNT(*)
FROM silver.crm_sales_details
WHERE sls_order_dt > sls_ship_dt OR sls_order_dt > sls_due_dt;

INSERT INTO @checks
SELECT 'crm_sales_details: sales = quantity x price, all positive', COUNT(*)
FROM silver.crm_sales_details
WHERE sls_sales IS NULL OR sls_quantity IS NULL OR sls_price IS NULL
   OR sls_sales <= 0 OR sls_quantity <= 0 OR sls_price <= 0
   OR sls_sales <> sls_quantity * sls_price;

INSERT INTO @checks
SELECT 'crm_sales_details: every sale has a known product', COUNT(*)
FROM silver.crm_sales_details s
WHERE NOT EXISTS (SELECT 1 FROM silver.crm_prd_info p WHERE p.prd_key = s.sls_prd_key);

INSERT INTO @checks
SELECT 'crm_sales_details: every sale has a known customer', COUNT(*)
FROM silver.crm_sales_details s
WHERE NOT EXISTS (SELECT 1 FROM silver.crm_cust_info c WHERE c.cst_id = s.sls_cust_id);

-- ERP -------------------------------------------------------------------------
INSERT INTO @checks
SELECT 'erp_cust_az12: ids match CRM customer keys', COUNT(*)
FROM silver.erp_cust_az12 WHERE cid LIKE 'NAS%' OR cid LIKE '%-%';

INSERT INTO @checks
SELECT 'erp_cust_az12: no birth dates in the future', COUNT(*)
FROM silver.erp_cust_az12 WHERE bdate > CAST(SYSDATETIME() AS DATE);

INSERT INTO @checks
SELECT 'erp_cust_az12: gender standardised', COUNT(*)
FROM silver.erp_cust_az12 WHERE gen NOT IN ('Female', 'Male', 'n/a');

INSERT INTO @checks
SELECT 'erp_loc_a101: ids without dashes', COUNT(*)
FROM silver.erp_loc_a101 WHERE cid LIKE '%-%';

INSERT INTO @checks
SELECT 'erp_loc_a101: countries standardised', COUNT(*)
FROM silver.erp_loc_a101
WHERE cntry IN ('DE', 'US', 'USA', '') OR cntry LIKE '%' + CHAR(13) + '%' OR cntry <> TRIM(cntry);

INSERT INTO @checks
SELECT 'erp_px_cat_g1v2: no carriage returns or padding', COUNT(*)
FROM silver.erp_px_cat_g1v2
WHERE maintenance LIKE '%' + CHAR(13) + '%' OR maintenance NOT IN ('Yes', 'No')
   OR cat <> TRIM(cat) OR subcat <> TRIM(subcat);

-- Report ----------------------------------------------------------------------
SELECT CASE WHEN failures = 0 THEN 'PASS' ELSE 'FAIL' END AS status, failures, check_name
FROM @checks;

IF EXISTS (SELECT 1 FROM @checks WHERE failures > 0)
    THROW 50001, 'Silver data-quality checks failed', 1;
