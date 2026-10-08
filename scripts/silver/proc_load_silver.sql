/*
===============================================================================
Stored procedure: silver.load_silver  (Bronze -> Silver)
===============================================================================
Cleans and standardises every Bronze table into its Silver counterpart.
Each table is truncated and fully reloaded; durations are logged per table
and for the whole batch.

Fixes applied (found by profiling the Bronze data):
  CRM customers   null IDs dropped; duplicate IDs resolved to the latest record;
                  names trimmed; gender / marital status codes expanded
  CRM products    category ID split out of the product key; missing cost -> 0;
                  product line codes expanded; end dates rebuilt from the next
                  version's start date (source end dates precede start dates)
  CRM sales       integer dates (YYYYMMDD) converted; zero, short and out-of-range
                  values (e.g. 0, 5489, 32154) -> NULL;
                  sales recomputed as quantity x price where missing/inconsistent;
                  missing or negative prices derived from sales / quantity
  ERP customers   'NAS' prefix removed from IDs; future birth dates -> NULL;
                  nine gender spellings normalised
  ERP locations   dashes removed from IDs; country codes expanded; blanks -> 'n/a'
  ERP categories  trailing carriage returns removed

The ERP files use Windows line endings, so the last column of each Bronze ERP
table ends with CHAR(13); it is stripped before any comparison.

Usage:
    EXEC silver.load_silver;
===============================================================================
*/
CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step_start DATETIME2, @batch_start DATETIME2 = SYSDATETIME();

    BEGIN TRY
        PRINT '=== Loading Silver layer ===';

        ------------------------------------------------------------------ CRM customers
        SET @step_start = SYSDATETIME();
        TRUNCATE TABLE silver.crm_cust_info;
        INSERT INTO silver.crm_cust_info (
            cst_id, cst_key, cst_firstname, cst_lastname,
            cst_marital_status, cst_gndr, cst_create_date
        )
        SELECT
            cst_id,
            TRIM(cst_key),
            TRIM(cst_firstname),
            TRIM(cst_lastname),
            CASE UPPER(TRIM(cst_marital_status))
                WHEN 'M' THEN 'Married'
                WHEN 'S' THEN 'Single'
                ELSE 'n/a'
            END,
            CASE UPPER(TRIM(cst_gndr))
                WHEN 'F' THEN 'Female'
                WHEN 'M' THEN 'Male'
                ELSE 'n/a'
            END,
            cst_create_date
        FROM (
            SELECT *,
                   ROW_NUMBER() OVER (PARTITION BY cst_id ORDER BY cst_create_date DESC) AS rn
            FROM bronze.crm_cust_info
            WHERE cst_id IS NOT NULL
        ) AS latest
        WHERE rn = 1;
        PRINT CONCAT('silver.crm_cust_info     ', @@ROWCOUNT, ' rows  ',
                     DATEDIFF(millisecond, @step_start, SYSDATETIME()), ' ms');

        ------------------------------------------------------------------ CRM products
        SET @step_start = SYSDATETIME();
        TRUNCATE TABLE silver.crm_prd_info;
        INSERT INTO silver.crm_prd_info (
            prd_id, cat_id, prd_key, prd_nm, prd_cost, prd_line, prd_start_dt, prd_end_dt
        )
        SELECT
            prd_id,
            REPLACE(LEFT(prd_key, 5), '-', '_'),        -- category part, e.g. CO-RF -> CO_RF
            SUBSTRING(prd_key, 7, LEN(prd_key)),         -- product part, matches sales keys
            TRIM(prd_nm),
            ISNULL(prd_cost, 0),
            CASE UPPER(TRIM(prd_line))
                WHEN 'M' THEN 'Mountain'
                WHEN 'R' THEN 'Road'
                WHEN 'S' THEN 'Other Sales'
                WHEN 'T' THEN 'Touring'
                ELSE 'n/a'
            END,
            CAST(prd_start_dt AS DATE),
            -- A version ends the day before the next version of the same product starts
            CAST(DATEADD(day, -1,
                LEAD(prd_start_dt) OVER (PARTITION BY prd_key ORDER BY prd_start_dt)
            ) AS DATE)
        FROM bronze.crm_prd_info;
        PRINT CONCAT('silver.crm_prd_info      ', @@ROWCOUNT, ' rows  ',
                     DATEDIFF(millisecond, @step_start, SYSDATETIME()), ' ms');

        ------------------------------------------------------------------ CRM sales
        SET @step_start = SYSDATETIME();
        TRUNCATE TABLE silver.crm_sales_details;
        INSERT INTO silver.crm_sales_details (
            sls_ord_num, sls_prd_key, sls_cust_id,
            sls_order_dt, sls_ship_dt, sls_due_dt,
            sls_sales, sls_quantity, sls_price
        )
        SELECT
            sls_ord_num,
            sls_prd_key,
            sls_cust_id,
            -- Only 8-digit YYYYMMDD values are dates: style 112 would read 5489 as the year 5489
            CASE WHEN sls_order_dt BETWEEN 19000101 AND 20991231
                 THEN TRY_CONVERT(DATE, CAST(sls_order_dt AS CHAR(8)), 112) END,
            CASE WHEN sls_ship_dt BETWEEN 19000101 AND 20991231
                 THEN TRY_CONVERT(DATE, CAST(sls_ship_dt AS CHAR(8)), 112) END,
            CASE WHEN sls_due_dt BETWEEN 19000101 AND 20991231
                 THEN TRY_CONVERT(DATE, CAST(sls_due_dt AS CHAR(8)), 112) END,
            fixed_sales,
            sls_quantity,
            CASE
                WHEN sls_price IS NULL OR sls_price <= 0 THEN fixed_sales / NULLIF(sls_quantity, 0)
                ELSE sls_price
            END
        FROM (
            SELECT *,
                   CASE
                       WHEN sls_sales IS NULL OR sls_sales <= 0
                            OR sls_sales <> sls_quantity * ABS(sls_price)
                       THEN sls_quantity * ABS(sls_price)
                       ELSE sls_sales
                   END AS fixed_sales
            FROM bronze.crm_sales_details
        ) AS s;
        PRINT CONCAT('silver.crm_sales_details ', @@ROWCOUNT, ' rows  ',
                     DATEDIFF(millisecond, @step_start, SYSDATETIME()), ' ms');

        ------------------------------------------------------------------ ERP customers
        SET @step_start = SYSDATETIME();
        TRUNCATE TABLE silver.erp_cust_az12;
        INSERT INTO silver.erp_cust_az12 (cid, bdate, gen)
        SELECT
            CASE WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LEN(cid)) ELSE cid END,
            CASE WHEN bdate > CAST(SYSDATETIME() AS DATE) THEN NULL ELSE bdate END,
            CASE UPPER(TRIM(REPLACE(gen, CHAR(13), '')))
                WHEN 'F' THEN 'Female'
                WHEN 'FEMALE' THEN 'Female'
                WHEN 'M' THEN 'Male'
                WHEN 'MALE' THEN 'Male'
                ELSE 'n/a'
            END
        FROM bronze.erp_cust_az12;
        PRINT CONCAT('silver.erp_cust_az12     ', @@ROWCOUNT, ' rows  ',
                     DATEDIFF(millisecond, @step_start, SYSDATETIME()), ' ms');

        ------------------------------------------------------------------ ERP locations
        SET @step_start = SYSDATETIME();
        TRUNCATE TABLE silver.erp_loc_a101;
        INSERT INTO silver.erp_loc_a101 (cid, cntry)
        SELECT
            REPLACE(cid, '-', ''),
            CASE
                WHEN clean.cntry = '' THEN 'n/a'
                WHEN clean.cntry = 'DE' THEN 'Germany'
                WHEN clean.cntry IN ('US', 'USA') THEN 'United States'
                ELSE clean.cntry
            END
        FROM bronze.erp_loc_a101
        CROSS APPLY (SELECT ISNULL(TRIM(REPLACE(cntry, CHAR(13), '')), '') AS cntry) AS clean;
        PRINT CONCAT('silver.erp_loc_a101      ', @@ROWCOUNT, ' rows  ',
                     DATEDIFF(millisecond, @step_start, SYSDATETIME()), ' ms');

        ------------------------------------------------------------------ ERP categories
        SET @step_start = SYSDATETIME();
        TRUNCATE TABLE silver.erp_px_cat_g1v2;
        INSERT INTO silver.erp_px_cat_g1v2 (id, cat, subcat, maintenance)
        SELECT
            TRIM(id),
            TRIM(cat),
            TRIM(subcat),
            TRIM(REPLACE(maintenance, CHAR(13), ''))
        FROM bronze.erp_px_cat_g1v2;
        PRINT CONCAT('silver.erp_px_cat_g1v2   ', @@ROWCOUNT, ' rows  ',
                     DATEDIFF(millisecond, @step_start, SYSDATETIME()), ' ms');

        PRINT CONCAT('=== Silver layer loaded in ',
                     DATEDIFF(millisecond, @batch_start, SYSDATETIME()), ' ms ===');
    END TRY
    BEGIN CATCH
        PRINT CONCAT('Error loading the Silver layer: ', ERROR_MESSAGE(),
                     ' (error ', ERROR_NUMBER(), ', line ', ERROR_LINE(), ')');
        THROW;
    END CATCH
END
GO
