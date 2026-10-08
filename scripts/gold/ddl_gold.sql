/*
===============================================================================
Gold layer: star schema views  (Silver -> Gold)
===============================================================================
Business-ready model for reporting:

    gold.dim_customers   one row per customer, CRM enriched with ERP data
    gold.dim_products    one row per current product version, with category
    gold.fact_sales      one row per order line, keyed to both dimensions

The views read Silver directly, so they always reflect the latest load.
Surrogate keys are generated with ROW_NUMBER and are stable as long as the
underlying business keys do not change.

Usage:
    SELECT * FROM gold.fact_sales;
===============================================================================
*/

-- Customers -------------------------------------------------------------------
-- CRM is the master for customer data; the ERP fills in birth date, country and,
-- where CRM has no value, gender.
CREATE OR ALTER VIEW gold.dim_customers AS
SELECT
    ROW_NUMBER() OVER (ORDER BY ci.cst_id) AS customer_key,
    ci.cst_id                                AS customer_id,
    ci.cst_key                               AS customer_number,
    ci.cst_firstname                         AS first_name,
    ci.cst_lastname                          AS last_name,
    ISNULL(la.cntry, 'n/a')                  AS country,
    ci.cst_marital_status                    AS marital_status,
    CASE
        WHEN ci.cst_gndr <> 'n/a' THEN ci.cst_gndr
        ELSE ISNULL(ca.gen, 'n/a')
    END                                      AS gender,
    ca.bdate                                 AS birthdate,
    ci.cst_create_date                       AS create_date
FROM silver.crm_cust_info AS ci
LEFT JOIN silver.erp_cust_az12 AS ca ON ca.cid = ci.cst_key
LEFT JOIN silver.erp_loc_a101 AS la ON la.cid = ci.cst_key;
GO

-- Products --------------------------------------------------------------------
-- Only the current version of each product (no end date); history stays in Silver.
CREATE OR ALTER VIEW gold.dim_products AS
SELECT
    ROW_NUMBER() OVER (ORDER BY pn.prd_start_dt, pn.prd_key) AS product_key,
    pn.prd_id                                AS product_id,
    pn.prd_key                               AS product_number,
    pn.prd_nm                                AS product_name,
    pn.cat_id                                AS category_id,
    ISNULL(pc.cat, 'n/a')                    AS category,
    ISNULL(pc.subcat, 'n/a')                 AS subcategory,
    ISNULL(pc.maintenance, 'n/a')            AS maintenance,
    pn.prd_cost                              AS cost,
    pn.prd_line                              AS product_line,
    pn.prd_start_dt                          AS start_date
FROM silver.crm_prd_info AS pn
LEFT JOIN silver.erp_px_cat_g1v2 AS pc ON pc.id = pn.cat_id
WHERE pn.prd_end_dt IS NULL;
GO

-- Sales -----------------------------------------------------------------------
CREATE OR ALTER VIEW gold.fact_sales AS
SELECT
    sd.sls_ord_num   AS order_number,
    pr.product_key,
    cu.customer_key,
    sd.sls_order_dt  AS order_date,
    sd.sls_ship_dt   AS shipping_date,
    sd.sls_due_dt    AS due_date,
    sd.sls_sales     AS sales_amount,
    sd.sls_quantity  AS quantity,
    sd.sls_price     AS price
FROM silver.crm_sales_details AS sd
LEFT JOIN gold.dim_products AS pr ON pr.product_number = sd.sls_prd_key
LEFT JOIN gold.dim_customers AS cu ON cu.customer_id = sd.sls_cust_id;
GO
