# Data catalog — Gold layer

The Gold layer is a star schema for sales reporting: two dimensions and one fact table, exposed as views over the Silver layer (`scripts/gold/ddl_gold.sql`).

```
              ┌──────────────────┐
              │ gold.dim_customers│
              └────────┬─────────┘
                       │ customer_key
┌──────────────────┐   │
│ gold.dim_products │───┤ product_key
└──────────────────┘   │
              ┌────────┴─────────┐
              │  gold.fact_sales  │
              └──────────────────┘
```

Text attributes use `n/a` when no source system provides a value.

## gold.dim_customers

One row per customer. CRM is the master record; the ERP adds birth date and country, and gender when CRM has none.

| Column | Type | Description |
|---|---|---|
| `customer_key` | bigint | Surrogate key used by `fact_sales` |
| `customer_id` | int | CRM customer ID |
| `customer_number` | nvarchar(50) | CRM customer number, e.g. `AW00011000`; matches the ERP customer IDs after cleaning |
| `first_name` | nvarchar(50) | First name, trimmed |
| `last_name` | nvarchar(50) | Last name, trimmed |
| `country` | nvarchar(50) | Country of residence (ERP), e.g. `Germany`, `United States` |
| `marital_status` | nvarchar(50) | `Married`, `Single` or `n/a` |
| `gender` | nvarchar(50) | `Female`, `Male` or `n/a` — CRM value, falling back to the ERP |
| `birthdate` | date | Date of birth (ERP); future dates are removed |
| `create_date` | date | Date the customer was created in the CRM |

## gold.dim_products

One row per product, current version only. Earlier versions and their validity periods are kept in `silver.crm_prd_info`.

| Column | Type | Description |
|---|---|---|
| `product_key` | bigint | Surrogate key used by `fact_sales` |
| `product_id` | int | CRM product ID |
| `product_number` | nvarchar(50) | Product number, e.g. `FR-R92B-58`; matches the sales records |
| `product_name` | nvarchar(50) | Product name |
| `category_id` | nvarchar(50) | Category code, e.g. `CO_RF` |
| `category` | nvarchar(50) | Category, e.g. `Bikes`, `Components` |
| `subcategory` | nvarchar(50) | Subcategory, e.g. `Road Frames` |
| `maintenance` | nvarchar(50) | Whether the product needs maintenance: `Yes`, `No` or `n/a` |
| `cost` | int | Unit cost; `0` where the source has none |
| `product_line` | nvarchar(50) | `Mountain`, `Road`, `Touring`, `Other Sales` or `n/a` |
| `start_date` | date | Date the current product version became available |

## gold.fact_sales

One row per order line.

| Column | Type | Description |
|---|---|---|
| `order_number` | nvarchar(50) | Sales order number, e.g. `SO43697` |
| `product_key` | bigint | Links to `dim_products` |
| `customer_key` | bigint | Links to `dim_customers` |
| `order_date` | date | Order date; `NULL` where the source date was invalid |
| `shipping_date` | date | Shipping date |
| `due_date` | date | Payment due date |
| `sales_amount` | int | Line total = `quantity × price` |
| `quantity` | int | Units ordered |
| `price` | int | Unit price |

## Data quality

`tests/quality_checks_silver.sql` and `tests/quality_checks_gold.sql` verify, among other rules, that keys are unique, every sale links to a customer and a product, `sales_amount = quantity × price`, and that no rows or revenue are lost between Silver and Gold. CI rebuilds the warehouse and runs them on every push.
