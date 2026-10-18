# Phase 2: Source System Engineering and Schema Design Explanation

## Business Context

**"What business problem does this schema support and what are the five source systems?"**

NorthPeak Retail Group runs on five separate source systems that were never designed to work together. Each one holds a piece of the business: sales, customers, loyalty, stock and logistics. Because they are disconnected, nobody can answer simple cross-functional questions such as "how much did loyalty members spend at each store?" or "which products are selling fast while distribution centre stock is running low?"

The systems disagree with each other in ways that make joining them unsafe:

- **Different identifiers:** RewardsCo identifies members with a plain integer (`member_id`, 1–530). The customer records use a formatted code (`NR0000001`). The two have to be mapped before they can be joined.
- **Inconsistent formats:** SupplyLink stores `movement_date` in two formats (ISO up to June 2025, then DD/MM/YYYY).
- **Unreliable values:** In the POS data, `line_total` ignores the discount on 71% of order lines. In RewardsCo, `points` has no sign, so a plain sum overstates balances by about 2x.

This schema supports a medallion pipeline (Bronze, Silver, Gold). Bronze keeps each source exactly as it arrived, Silver fixes and standardises it, and Gold serves one trusted set of numbers for reporting. The nine tables below are the shared model that makes that possible, with a clear grain and primary key for each.

The five source systems are:

1. **Legacy Point of Sale (POS)** — captures transaction-level sales. It owns `orders` (one row per order) and `order_items` (one row per product line).
2. **FreshMart Migration Batch** — brought in customer records from a 2023 acquisition. It owns `customers` (one row per customer). It also holds the personal data that Silver must drop.
3. **SupplyLink Distribution** — manages logistics and stock movement between distribution centers and stores. It owns `supplylink_dc_movements` (one row per receipt, write-off or transfer).
4. **RewardsCo Loyalty System** — tracks customer membership and transaction-linked reward points. It owns `rewardsco_loyalty_transactions` (one row per points earned or redeemed).
5. **Inventory Management System** — responsible for store-level stock levels and master reference data. It owns `inventory` (one row per product per store), `products`, `stores` and `suppliers`.

## Source System Mapping & Grain Analysis

NorthPeak's seed data is pulled from five upstream source systems. Before building Bronze, each file needs to be traced back to its owning system **and** its grain established — the grain decides whether a table can be queried directly for totals (header-level) or must be aggregated first (line/event-level), which shapes how each one lands in Bronze/Silver.

### System → File Mapping

| # | Source System | CSV File(s) | What it owns |
|---|---|---|---|
| 1 | Legacy Point of Sale (POS) | `orders.csv`, `order_items.csv` | Core retail transactions |
| 2 | FreshMart Migration Batch | `customers.csv` | Customer data from the acquisition |
| 3 | SupplyLink Distribution | `supplylink_dc_movements.csv` | Logistics / inventory movement between DCs |
| 4 | RewardsCo Loyalty System | `rewardsco_loyalty_transactions.csv` | Customer membership & loyalty transaction history |
| 5 | Inventory Management / ERP | `inventory.csv`, `products.csv`, `stores.csv`, `suppliers.csv` | Store-level stock, product master, store master, supplier master |

### Grain of Each Dataset

| File | Grain (what one row represents) | Natural key | Why this matters for medallion design |
|---|---|---|---|
| `orders.csv` | **One order** — a single checkout/transaction header | `order_id` | Header-level; order totals here are pre-aggregated by POS, not derivable from this file alone — Silver must treat this as the "one row per transaction" fact, joined 1-to-many to `order_items` |
| `order_items.csv` | **One line item** — a single product within one order | `order_id` + line/item identifier | Line-level; multiple rows roll up to one `orders.csv` row. This is where per-product quantity/discount/price lives — any product-level analysis (margin, discount validation) must start here, not from `orders.csv` |
| `customers.csv` | **One customer** — a master record per person | `customer_id` | Master/dimension grain, one row per entity, not an event — slowly changing, PII-bearing, feeds Silver's masked `customer_id`-keyed dimension |
| `supplylink_dc_movements.csv` | **One stock movement event** — a single receipt, write-off, or transfer logged at a DC | `movement_id` | Event/fact grain, not a periodic snapshot — each row is one thing that happened, so stock-on-hand has to be *derived* by summing movements, it isn't stored directly |
| `rewardsco_loyalty_transactions.csv` | **One loyalty transaction event** — a single points-earning or points-redeeming action tied to a customer | `transaction_id` (FK `customer_id`) | Event/fact grain — points balance is a running total that must be computed from these events, not read off any single row |
| `inventory.csv` | **Intended as one store-level stock position** (store + SKU) | *Should be* `store_id` + `sku`, but `inventory_id` alone is **not a safe/unique join key** at that grain (confirmed finding) — treat `inventory_id` as a surrogate row ID only, and derive the real grain from `store_id`+`sku` before using it as a join key in Silver |
| `products.csv` | **One product** — a master record per SKU | `product_id` / `sku` | Master/dimension grain — joins outward to `order_items`, `inventory`, `supplylink_dc_movements` |
| `stores.csv` | **One store** — a master record per retail location | `store_id` | Master/dimension grain — joins outward to `orders`, `inventory` |
| `suppliers.csv` | **One supplier** — a master record per vendor | `supplier_id` / `supplier_code` | Master/dimension grain — joins outward to `supplylink_dc_movements` via the embedded `SUP###` prefix in `supplier_ref` |

**Key takeaway:** `orders.csv` and `order_items.csv` look like they could be merged, but they're two different grains from the same system — collapsing them in Bronze would silently destroy the line-item detail Silver needs for anything product-level. The same caution applies to `inventory.csv`: its row-level ID looks like a safe key but isn't, so the medallion design has to establish the *real* grain (`store_id`+`sku`) rather than trusting the file's own ID column.

## Data Quality Issues Found
---
### customers.csv

1. **Missing data hidden behind a "0% null" check** — 
   - `legacy_customer_ref`: 420 of 500 rows (84.0%) are empty/missing.
   - `loyalty_member_id`: 121 of 500 rows (24.2%) are empty/missing.
   - `gdpr_consent_date`: 42 of 500 rows (8.4%) are empty/missing.
   - `email`: 30 of 500 rows (6.0%) are empty/missing.

2. **Duplicate values on fields that should be unique per customer**:
   - `email`: 1 value shared by more than one customer record.
   - `legacy_customer_ref`: 1 value shared by more than one customer record.
   - `loyalty_member_id`: 1 value shared by more than one customer record.

3. **`phone` is numeric-looking text, at risk of silent corruption from leading-zero loss** — all phone numbers follow UK mobile format with a leading `0` (e.g. `07736855845`). If this column is read without explicitly forcing a text/VARCHAR type, the leading `0` is silently stripped during type inference, corrupting every value in the column. Confirmed as a real risk encountered during this audit, which is why `phone` had to be explicitly forced to VARCHAR in later checks.

4. **GDPR consent audit-trail gap** — 34 of 500 customers (6.8%) have `gdpr_consent = False`. Of those 34:
   - 5 (14.7% of the non-consenting group) have a missing `gdpr_consent_date` — no record of when their consent status was set.
   - 2 (customer_id 409 and 439) also have a missing email address.

5. **PII Handling**

Following the PII audit, the following columns will be **dropped entirely** (not
masked) when transforming Bronze → Silver:

- `first_name`, `last_name`, `email`, `phone`, `date_of_birth`, `postcode`

**Join/grouping key:** `customer_id` is retained and used as the surrogate key across
all Silver/Gold tables (orders, loyalty transactions, DC movements already reference
it this way) — no PII-based hashing is needed for this purpose.

**Derived replacements added in Silver:**
- `age_band` — bucketed from `date_of_birth`
- `region` — derived from `postcode`

Raw PII remains available only in Bronze (restricted access), for compliance needs
such as GDPR Subject Access Requests.
---
### inventory.csv

1. **Negative `quantity_on_hand` values — confirmed intentional, not a bug** —
   30 of 385 rows (7.8%) have `quantity_on_hand < 0`. Verified against business logic:
   all 30 negative rows have `is_adjustment = True` (0 negative rows without the flag),
   so this is consistent with stock-correction behavior, not corrupted data.

2. **`quantity_on_hand` is a non-whole number for most rows** — 338 of 385 rows (87.8%)
   have a decimal `quantity_on_hand` (e.g. `171.6`). Unusual for a physical unit count —
   worth confirming with the source team whether this column is measured by weight/volume
   rather than discrete units, or whether it's a data generation artifact.
---
### order_items.csv

1. **⚠️ Critical: `line_total` does not reliably apply `discount_pct`** —
   Checked against the stated business formula (`line_total = quantity × unit_price ×
   (1 - discount_pct)`) using the original (un-rounded) `quantity`:
   - **3,793 of 5,310 rows (71.4%)** match `quantity × unit_price` **with the discount
     ignored entirely**.
   - **1,364 of 5,310 rows (25.7%)** match **neither** formula (genuine calculation
     discrepancies, not just a rounding difference).
   - Only **153 of 5,310 rows (2.9%)** correctly apply the discount.
   - **Impact:** `discount_pct` exists as a column but is not reflected in `line_total`
     for the vast majority of rows. Any revenue figure built directly on raw
     `line_total` is effectively overstated by the discount amount, silently. Silver
     layer should recompute `line_total` from `quantity`, `unit_price`, and
     `discount_pct` rather than trusting the source value as-is.

2. **`quantity` is a non-whole number for a quarter of rows** — 1,391 of 5,310 rows
   (26.2%) have a fractional `quantity` (e.g. `2.9`, `3.7`). Same pattern seen in
   `inventory.csv`/`inventory.xlsx` — worth confirming with the source team whether
   this is a unit-of-measure issue or a data generation artifact, since order line
   quantities are normally whole units.

3. **Uneven monthly volume — September and December 2025 notably lower** — row counts
   by month range from 285–532, averaging ~443/month, but September (300 rows) and
   December (285 rows) sit well below that average and below every other month
   (lowest of the rest is January at 459). Worth checking whether these two months are
   genuinely lower-volume or represent incomplete data loads.
---
### orders.csv

1. **`customer_id` missing for some orders** — 17 of 1,228 rows (1.4%) have a null
   `customer_id`. These look like guest/anonymous checkouts rather than data entry
   errors, but worth confirming — if so, they can't be linked to a customer dimension
   downstream and should be handled explicitly (e.g. a "guest" bucket) rather than
   silently dropped on join.

2. **`order_ref` is not unique, despite `order_id` being a clean primary key** —
   `order_id` has 0 duplicates, but `order_ref` (the human-readable reference, e.g.
   `NP-2025-0000183`) has **26 duplicated values** — 24 appear twice and 2 appear three
   times, accounting for ~28 excess rows (~2.3% of the file). If `order_ref` is meant
   to be a unique customer-facing reference, this is a data quality issue worth
   flagging to the source team — don't treat `order_ref` as a safe lookup/join key.

3. **One order's `completed_at` is earlier than its own `created_at`** — 1 of 1,228
   rows (0.08%) shows an order marked completed before the system record for it was
   even created. Minor in volume, but logically impossible — worth a spot-check rather
   than ignoring, since it indicates a timestamp generation or system-clock issue
   somewhere upstream. (Note: `completed_at` vs `order_date` — the "ordered before
   completed" check — passes cleanly with 0 violations; this is specifically the
   `created_at` comparison.)

4. **Uneven monthly volume — September and December 2025 notably lower** — order
   counts by month range from 60–123, averaging ~102/month. September (66) and
   December (60) sit well below every other month (lowest of the rest is April/June/July
   at ~108–111) — same seasonal-dip pattern seen in `order_items.csv`. Worth checking
   whether these reflect genuine seasonality or incomplete data loads for those months.
---
### products.csv — Brand, own-brand flag, and pack size integrity

1. **⚠️ `brand` and `product_name` are inconsistent for 91.3% of rows** —
   137 of 150 rows have a `product_name` that doesn't mention the brand listed in
   `brand` at all (e.g. `product_id=2`: name is "Warburtons Milk 1kg" but
   `brand = Walkers`). This isn't a formatting quirk — it's spread almost uniformly
   across the file, meaning `product_name` cannot be trusted as a source of brand
   truth.
   **Fix:** Treat `brand` (a clean, 12-value controlled column) as the single source
   of truth for anything brand-related. Never derive brand from `product_name` text.
   Build the Silver `dim_brand` table from the `brand` column only (12 rows, as above).
   Keep `product_name` as a display/search-only field with no structural meaning.

   ### Products grouped by brand (for Silver schema design)

   ### Cadbury (17 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 4 | NP-SKU-00004 | Kelloggs Yoghurt 500g | Food | False |
| 22 | NP-SKU-00022 | Nestle Toilet Roll | Household | False |
| 24 | NP-SKU-00024 | Nestle Supplements 250g | Health | False |
| 47 | NP-SKU-00047 | Heinz Bleach each | Household | True |
| 53 | NP-SKU-00053 | Unilever Fruit 1L | Food | False |
| 56 | NP-SKU-00056 | Unilever Yoghurt | Food | False |
| 67 | NP-SKU-00067 | Coca-Cola Tea each | Drink | False |
| 87 | NP-SKU-00087 | PepsiCo Frozen Fish 1kg | Food | True |
| 95 | NP-SKU-00095 | Nestle Juice 1L | Drink | False |
| 96 | NP-SKU-00096 | Kelloggs Wine | Drink | False |
| 98 | NP-SKU-00098 | Cadbury Detergent each | Household | False |
| 100 | NP-SKU-00100 | McVities Toilet Roll 250g | Household | True |
| 102 | NP-SKU-00102 | Unilever Supplements 6pk | Health | False |
| 106 | NP-SKU-00106 | Walkers Milk 500g | Food | False |
| 119 | NP-SKU-00119 | Procter & Gamble Tea 4pk | Drink | False |
| 132 | NP-SKU-00132 | Coca-Cola Milk | Food | True |
| 136 | NP-SKU-00136 | Warburtons Chicken | Food | True |

### Coca-Cola (14 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 3 | NP-SKU-00003 | Walkers Cheese 1kg | Food | False |
| 13 | NP-SKU-00013 | Walkers Ice Cream 500g | Food | False |
| 28 | NP-SKU-00028 | Kelloggs Milk 250g | Food | False |
| 38 | NP-SKU-00038 | Coca-Cola Ready Meals each | Food | True |
| 74 | NP-SKU-00074 | Kelloggs Toilet Roll 4pk | Household | False |
| 89 | NP-SKU-00089 | Kelloggs Pastries 6pk | Food | False |
| 90 | NP-SKU-00090 | NorthPeak Own Ready Meals 500g | Food | False |
| 97 | NP-SKU-00097 | Heinz Beer | Drink | False |
| 112 | NP-SKU-00112 | Cadbury Fresh Fish each | Food | False |
| 117 | NP-SKU-00117 | Warburtons Ice Cream 6pk | Food | False |
| 118 | NP-SKU-00118 | Coca-Cola Coffee | Drink | False |
| 120 | NP-SKU-00120 | Cadbury Cola 4pk | Drink | False |
| 124 | NP-SKU-00124 | NorthPeak Own Detergent 6pk | Household | True |
| 137 | NP-SKU-00137 | McVities Pork 1L | Food | False |

### Heinz (9 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 23 | NP-SKU-00023 | Coca-Cola Kitchen Roll each | Household | False |
| 36 | NP-SKU-00036 | Walkers Bread 250g | Food | False |
| 46 | NP-SKU-00046 | Heinz Detergent | Household | False |
| 58 | NP-SKU-00058 | Warburtons Chicken 6pk | Food | True |
| 59 | NP-SKU-00059 | Coca-Cola Pork 4pk | Food | False |
| 65 | NP-SKU-00065 | Coca-Cola Ice Cream 1kg | Food | False |
| 75 | NP-SKU-00075 | NorthPeak Own Kitchen Roll 6pk | Household | True |
| 78 | NP-SKU-00078 | Nestle Vegetables 500g | Food | False |
| 131 | NP-SKU-00131 | Warburtons Fruit 1kg | Food | True |

### Kelloggs (18 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 11 | NP-SKU-00011 | Coca-Cola Pastries 4pk | Food | True |
| 19 | NP-SKU-00019 | Heinz Beer each | Drink | False |
| 21 | NP-SKU-00021 | Procter & Gamble Bleach 1L | Household | True |
| 54 | NP-SKU-00054 | Unilever Milk 4pk | Food | False |
| 68 | NP-SKU-00068 | Heinz Cola 6pk | Drink | False |
| 71 | NP-SKU-00071 | Heinz Beer 500g | Drink | False |
| 72 | NP-SKU-00072 | Nestle Detergent 6pk | Household | False |
| 79 | NP-SKU-00079 | Kelloggs Fruit | Food | False |
| 85 | NP-SKU-00085 | PepsiCo Pork 500g | Food | False |
| 93 | NP-SKU-00093 | PepsiCo Tea 4pk | Drink | False |
| 110 | NP-SKU-00110 | McVities Chicken 500g | Food | True |
| 113 | NP-SKU-00113 | McVities Frozen Fish 250g | Food | False |
| 126 | NP-SKU-00126 | Cadbury Toilet Roll 250g | Household | False |
| 129 | NP-SKU-00129 | Nestle Shampoo 1kg | Health | False |
| 130 | NP-SKU-00130 | Unilever Vegetables 250g | Food | True |
| 135 | NP-SKU-00135 | Nestle Beef | Food | False |
| 139 | NP-SKU-00139 | Procter & Gamble Frozen Fish 6pk | Food | False |
| 149 | NP-SKU-00149 | Walkers Beer | Drink | False |

### McVities (10 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 6 | NP-SKU-00006 | Walkers Chicken 6pk | Food | False |
| 14 | NP-SKU-00014 | Nestle Coffee 250g | Drink | False |
| 25 | NP-SKU-00025 | Coca-Cola Shampoo 1L | Health | True |
| 45 | NP-SKU-00045 | Unilever Beer 1L | Drink | True |
| 55 | NP-SKU-00055 | Walkers Cheese 4pk | Food | True |
| 60 | NP-SKU-00060 | Coca-Cola Fresh Fish 500g | Food | False |
| 64 | NP-SKU-00064 | Kelloggs Ready Meals | Food | False |
| 86 | NP-SKU-00086 | Procter & Gamble Fresh Fish 4pk | Food | False |
| 99 | NP-SKU-00099 | Cadbury Bleach 250g | Household | False |
| 123 | NP-SKU-00123 | McVities Beer 500g | Drink | False |

### Nestle (14 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 26 | NP-SKU-00026 | Nestle Vegetables each | Food | False |
| 27 | NP-SKU-00027 | Cadbury Fruit 1kg | Food | True |
| 41 | NP-SKU-00041 | Cadbury Tea 1L | Drink | False |
| 49 | NP-SKU-00049 | NorthPeak Own Kitchen Roll 1kg | Household | False |
| 51 | NP-SKU-00051 | PepsiCo Shampoo 1kg | Health | False |
| 70 | NP-SKU-00070 | Cadbury Wine each | Drink | True |
| 84 | NP-SKU-00084 | Coca-Cola Chicken 500g | Food | False |
| 88 | NP-SKU-00088 | Coca-Cola Bread | Food | True |
| 104 | NP-SKU-00104 | McVities Vegetables each | Food | True |
| 111 | NP-SKU-00111 | PepsiCo Pork 4pk | Food | False |
| 114 | NP-SKU-00114 | Unilever Bread 500g | Food | True |
| 122 | NP-SKU-00122 | McVities Wine 4pk | Drink | False |
| 133 | NP-SKU-00133 | Warburtons Cheese | Food | False |
| 142 | NP-SKU-00142 | NorthPeak Own Ready Meals 6pk | Food | False |

### NorthPeak Own (12 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 5 | NP-SKU-00005 | Nestle Beef 6pk | Food | False |
| 12 | NP-SKU-00012 | Walkers Ready Meals | Food | False |
| 15 | NP-SKU-00015 | Heinz Tea 4pk | Drink | True |
| 30 | NP-SKU-00030 | Heinz Yoghurt 250g | Food | False |
| 33 | NP-SKU-00033 | Heinz Pork 500g | Food | False |
| 81 | NP-SKU-00081 | Kelloggs Cheese | Food | False |
| 94 | NP-SKU-00094 | Cadbury Cola 500g | Drink | True |
| 103 | NP-SKU-00103 | NorthPeak Own Shampoo 250g | Health | False |
| 107 | NP-SKU-00107 | Kelloggs Cheese 500g | Food | False |
| 108 | NP-SKU-00108 | Kelloggs Yoghurt each | Food | False |
| 128 | NP-SKU-00128 | Procter & Gamble Supplements 500g | Health | True |
| 145 | NP-SKU-00145 | PepsiCo Tea 1kg | Drink | True |

### PepsiCo (10 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 17 | NP-SKU-00017 | Cadbury Juice 250g | Drink | True |
| 31 | NP-SKU-00031 | Heinz Beef 6pk | Food | True |
| 62 | NP-SKU-00062 | Heinz Bread 6pk | Food | False |
| 101 | NP-SKU-00101 | Kelloggs Kitchen Roll 4pk | Household | False |
| 116 | NP-SKU-00116 | Procter & Gamble Ready Meals 6pk | Food | False |
| 125 | NP-SKU-00125 | NorthPeak Own Bleach 250g | Household | False |
| 127 | NP-SKU-00127 | Walkers Kitchen Roll 4pk | Household | False |
| 143 | NP-SKU-00143 | Nestle Ice Cream 6pk | Food | True |
| 146 | NP-SKU-00146 | NorthPeak Own Cola 4pk | Drink | False |
| 150 | NP-SKU-00150 | Heinz Detergent 4pk | Household | False |

### Procter & Gamble (7 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 7 | NP-SKU-00007 | NorthPeak Own Pork 1kg | Food | False |
| 35 | NP-SKU-00035 | Unilever Frozen Fish 4pk | Food | True |
| 57 | NP-SKU-00057 | Cadbury Beef 1kg | Food | False |
| 82 | NP-SKU-00082 | McVities Yoghurt 4pk | Food | False |
| 115 | NP-SKU-00115 | Nestle Pastries 250g | Food | False |
| 121 | NP-SKU-00121 | Cadbury Juice 4pk | Drink | True |
| 140 | NP-SKU-00140 | PepsiCo Bread 6pk | Food | False |

### Unilever (10 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 1 | NP-SKU-00001 | Kelloggs Fruit 6pk | Food | True |
| 8 | NP-SKU-00008 | McVities Fresh Fish 1kg | Food | False |
| 10 | NP-SKU-00010 | Walkers Bread 6pk | Food | False |
| 16 | NP-SKU-00016 | Kelloggs Cola 6pk | Drink | True |
| 29 | NP-SKU-00029 | Coca-Cola Cheese 250g | Food | False |
| 34 | NP-SKU-00034 | Walkers Fresh Fish 4pk | Food | True |
| 40 | NP-SKU-00040 | NorthPeak Own Coffee 1L | Drink | False |
| 66 | NP-SKU-00066 | Cadbury Coffee 250g | Drink | False |
| 73 | NP-SKU-00073 | NorthPeak Own Bleach 4pk | Household | False |
| 77 | NP-SKU-00077 | Heinz Shampoo 4pk | Health | False |

### Walkers (8 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 2 | NP-SKU-00002 | Warburtons Milk 1kg | Food | False |
| 20 | NP-SKU-00020 | Coca-Cola Detergent 1kg | Household | False |
| 39 | NP-SKU-00039 | Walkers Ice Cream | Food | False |
| 52 | NP-SKU-00052 | Unilever Vegetables 500g | Food | False |
| 61 | NP-SKU-00061 | NorthPeak Own Frozen Fish 4pk | Food | False |
| 141 | NP-SKU-00141 | Unilever Pastries | Food | True |
| 147 | NP-SKU-00147 | Unilever Juice 1L | Drink | True |
| 148 | NP-SKU-00148 | PepsiCo Wine 4pk | Drink | False |

### Warburtons (21 products)

| product_id | sku | product_name | category_l1 | is_own_brand |
|---|---|---|---|---|
| 9 | NP-SKU-00009 | Warburtons Frozen Fish 4pk | Food | False |
| 18 | NP-SKU-00018 | NorthPeak Own Wine 4pk | Drink | True |
| 32 | NP-SKU-00032 | Procter & Gamble Chicken 4pk | Food | False |
| 37 | NP-SKU-00037 | Warburtons Pastries 1L | Food | False |
| 42 | NP-SKU-00042 | Walkers Cola 6pk | Drink | False |
| 43 | NP-SKU-00043 | Procter & Gamble Juice 1L | Drink | False |
| 44 | NP-SKU-00044 | McVities Wine 500g | Drink | False |
| 48 | NP-SKU-00048 | Kelloggs Toilet Roll 1kg | Household | False |
| 50 | NP-SKU-00050 | Kelloggs Supplements 4pk | Health | False |
| 63 | NP-SKU-00063 | Heinz Pastries 500g | Food | True |
| 69 | NP-SKU-00069 | Warburtons Juice 500g | Drink | False |
| 76 | NP-SKU-00076 | Cadbury Supplements 1kg | Health | False |
| 80 | NP-SKU-00080 | Kelloggs Milk 1kg | Food | False |
| 83 | NP-SKU-00083 | Cadbury Beef 250g | Food | False |
| 91 | NP-SKU-00091 | Warburtons Ice Cream 1kg | Food | False |
| 92 | NP-SKU-00092 | Nestle Coffee 500g | Drink | False |
| 105 | NP-SKU-00105 | Heinz Fruit each | Food | False |
| 109 | NP-SKU-00109 | Nestle Beef 1L | Food | False |
| 134 | NP-SKU-00134 | Cadbury Yoghurt 1L | Food | False |
| 138 | NP-SKU-00138 | PepsiCo Fresh Fish 500g | Food | False |
| 144 | NP-SKU-00144 | Heinz Coffee | Drink | False |

2. **⚠️ `is_own_brand` contradicts the `brand` column itself** —
   - **8 rows** have `brand = 'NorthPeak Own'` but `is_own_brand = False` — the
     product is literally the retailer's own brand, yet flagged as not own-brand.
   - **34 rows** have `is_own_brand = True` but `brand` is a third-party name (e.g.
     `Unilever`, `Kelloggs`) — flagged as own-brand despite being attributed to a
     named supplier brand.
   - Only **4 of the 12** `NorthPeak Own`-branded rows are correctly flagged `True`.
   - **Net effect:** `is_own_brand` as given is unreliable — it agrees with `brand`
     on only 4/150 rows (2.7%) where that comparison is even meaningful.
   **Fix:** Don't trust the raw `is_own_brand` flag. In Silver, derive a corrected
   field: `is_own_brand = (brand == 'NorthPeak Own')`. Keep the original flag as
   `is_own_brand_raw` for audit/lineage, but every downstream query (margin analysis,
   own-brand sales mix, etc.) should use the derived field, not the raw one.

3. **⚠️ `pack_size` doesn't match the size stated in `product_name`, even when
   `unit_of_measure` lines up** —
   Example: `product_id=2`, "Warburtons Milk 1kg", `unit_of_measure = kg`,
   `pack_size = 0.45` — the name claims 1kg, the unit matches kg, but the actual
   pack_size value is 0.45, not 1.0.
   - Checked systematically: of the 7 rows where `product_name` states an exact
     weight/volume (e.g. "1kg", "1L") **and** `unit_of_measure` matches that same
     unit, **100% (7/7)** have a `pack_size` that doesn't equal the stated number.
   - More broadly, only 21 of 150 rows (14%) even have a `unit_of_measure` that
     aligns with what's mentioned in `product_name` at all — for the other 86%, the
     name mentions one unit (e.g. "4pk") while `unit_of_measure` says something else
     entirely (e.g. "litre").
   **Fix:** `pack_size` + `unit_of_measure` are the structured, typed source of truth
   for physical size — use them as-is for any pricing-per-unit or logistics
   calculation. Never parse a size out of `product_name` text to use as real data;
   the name field has already been shown (issue 1) to be unreliable. No "correction"
   is possible here either — there's no ground truth to reconcile against, only two
   disagreeing values.

### The pattern across all three issues

Each issue is the same shape: a **structured, typed column** (`brand`, `is_own_brand`,
`pack_size`/`unit_of_measure`) disagrees with the **free-text `product_name`** field.
As the file owner, the governing rule is the same every time: **trust the structured
column, treat `product_name` as decorative text only, and never try to "fix" one side
by inferring from the other** — with no real external catalog to check against, any
such correction would just be guessing.

### Silver layer recommendation — `dim_products`

- Keep `product_id` and `sku` as-is (both clean, unique — safe join/PK keys).
- Build `dim_brand` from the `brand` column only (12 rows) — this is the trusted
  brand dimension.
- Add `is_own_brand` as a **derived** column (`brand == 'NorthPeak Own'`), keep the
  original as `is_own_brand_raw`.
- Keep `pack_size` and `unit_of_measure` as the trusted physical attributes.
- Keep `product_name` as a display-only attribute — never used to derive brand,
  size, or own-brand status.
- Add three boolean data-quality flags (`brand_name_mismatch`, `own_brand_mismatch`,
  `pack_size_name_mismatch`) so downstream analysts can see these known limitations
  without re-deriving them every time.

---
### rewardsco_loyalty_transactions.csv

1. **⚠️ Critical: `points` has no sign — a naive `SUM(points)` overstates member
   balances by 2x** — `points` is stored as a magnitude-only number; `redeem` rows
   store a *positive* value even though they should subtract from a member's balance.
   - Naive `SUM(points)` across the table: **3,062,372**
   - Correct signed balance (`earn` adds, `redeem` subtracts): **1,524,034**
   - **Overstatement if signs aren't applied: 1,538,338 points (~2x too high)**.
   - **Impact:** any balance calculation in Silver/Gold must apply
     `CASE WHEN transaction_type = 'redeem' THEN -points ELSE points END` — never sum
     the raw column directly.

2. **⚠️ `store_id` is missing for ~20% of `in_store` transactions, where it should
   never be null** — `store_id` is null overall for 2,733 of 13,439 rows (20.3%), but
   broken down by channel, the null rate is roughly even across all three channels:
   `online` 21.0%, `click_collect` 20.0%, **`in_store` 20.0% (898 rows)**. An
   `in_store` purchase physically happened at a store — a null `store_id` there is a
   genuine data gap, not an expected pattern (unlike `online`, where no store is
   legitimate). Worth flagging to the source team; Silver should not silently treat
   these as resolved.

3. **`basket_value_gbp` and `sku` are null for 33.0% of rows — confirmed expected,
   not a bug** — both are null for exactly the 4,432 `redeem` rows (you don't buy a
   basket when redeeming points) and populated for all 9,007 `earn` rows, with zero
   exceptions either way. Documented here so the null rate isn't mistaken for missing
   data in a later review.

4. **No fixed points-earn-rate formula** — checked points-per-pound-spent on `earn`
   rows: ranges from 0.06 to 89.35 (mean 5.18, std 8.14) with no tight clustering.
   Points are likely promo-driven/randomly generated rather than a fixed "£1 = N
   points" rule — exploratory finding, not a defect, but don't assume a formula
   exists when building any points-forecasting logic.

5. **Minor: `created_at` is 1 second *before* `transaction_at` for 20 rows (0.15%)**
   — in a real pipeline `created_at` (when the row was written) should be at or after
   `transaction_at` (when the event happened), not earlier. All 20 instances show
   exactly a -1 second gap. Low impact given the tiny row count and gap size, but
   logically backwards — worth a quick check with the source team.

6. **`member_id` referential integrity not verified — no members table available** —
   this audit checked `store_id` against `stores.csv` (0 orphans, clean), but no
   `members.csv` / `loyalty_members.csv` was available to validate `member_id`
   against. Flagging this as an open gap, not a pass — re-run this check once that
   file exists.

7. **Feed freshness — latest transaction is 2026-06-30** — row volume is fairly even
   across all 18 months in the file (686–836 rows/month), so there's no gap *within*
   the data. But the most recent transaction is dated 2026-06-30, roughly 3 months
   before today (2026-10-03) — worth confirming whether the feed has stopped, rather
   than assuming the business simply had a quiet quarter.

---
### stores.csv

1. **`acquired_from` is null for 90% of rows — confirmed expected, not a bug** — 27
   of 30 stores have no `acquired_from` value, and the 3 that do all say
   `"FreshMart"`. This reads as "most stores were opened by NorthPeak directly; only
   3 were acquired from a previous owner (FreshMart)" — a legitimate business
   distinction, not missing data. Documented here so the 90% null rate isn't
   re-flagged as an issue later.

---
### suppliers.csv

**No issues found**

---
### supplylink_dc_movements.csv

**1. ⚠️ `movement_date` mixes two date formats, with a clean cutover at `movement_id` 5588/5589.**
Rows 1–5,588 are ISO (`YYYY-MM-DD`), covering 2025-01-01 → 2025-06-30. Rows 5,589–11,171 are `DD/MM/YYYY` — confirmed by day-values >12 in 3,425 of those 5,583 rows (day can't be a month), and consistent for the remaining 2,158 ambiguous rows — covering 2025-07-01 → 2025-12-30. The column is typed VARCHAR (not DATE) by default readers, so a plain `MIN()`/`MAX()` does a **lexicographic string comparison**, not a chronological one. Any downstream query must parse with `COALESCE(TRY_STRPTIME(movement_date,'%Y-%m-%d'), TRY_STRPTIME(movement_date,'%d/%m/%Y'))` or it will silently mis-read half the file.

**2. ⚠️ `week_number` disagrees with `movement_date` on 3,205/11,171 rows (28.7%).**
Split almost evenly across both date-format segments (1,639 of the pre-cutover rows, 1,566 of the post-cutover rows) — so this is **not** caused by the format migration in #1; it's a separate, ongoing issue. 98.3% of the mismatches (3,149/3,205) are off by exactly one ISO week; the rest (56 rows) are a year-boundary wrap (week 1 vs week 52). The consistent off-by-one pattern points to `week_number` being computed with a different week-start rule, not random corruption.

**3. ⚠️ `timezone` looks unreliable before the same cutover point as #1.**
January–June 2025 rows are 100% "UTC" with zero "BST" recorded, even though the UK is on BST (UTC+1) from late March onward in reality. From August onward "BST" becomes the dominant value, matching real UK clock rules. Since this flips at the same `movement_id` boundary as the date-format change, the pre-migration feed appears to have never tracked real local/DST time and defaulted every row to "UTC" — so `timezone` can't be trusted for roughly the first half of the file, and this can't be recovered from the file alone.

| month | timezone | n   |
|-------|----------|-----|
| 1     | UTC      | 992 |
| 2     | UTC      | 832 |
| 3     | UTC      | 930 |
| 4     | UTC      | 959 |
| 5     | UTC      | 897 |
| 6     | UTC      | 945 |
| 7     | BST      | 42  |
| 7     | UTC      | 913 |
| 8     | BST      | 608 |
| 8     | UTC      | 350 |
| 9     | BST      | 617 |
| 9     | UTC      | 332 |
| 10    | BST      | 669 |
| 10    | UTC      | 327 |
| 11    | BST      | 646 |
| 11    | UTC      | 276 |
| 12    | BST      | 548 |
| 12    | UTC      | 288 |

*Expect UTC to dominate Nov–Mar, BST to dominate Apr–Oct. Anything inverted is worth checking.*

**4. `reached_epos` is null for 101/11,171 rows (0.90%).** Spread across all three `movement_type`s (receipt 60, transfer 24, write_off 17) with no business rule explaining it, and the column never contains "N", only "Y" or blank. Looks like a genuine data gap rather than an intentional state — needs an owner decision on what blank means before Silver.

**5. Structural gap, not a data bug:** `transfer` rows (2,179) record only one `dc_code` with no from/to direction field, so a transfer can't be signed (+/-) for stock reconciliation — any netting of receipt − write_off ± transfer per DC will be wrong for the transfer component. This needs a schema fix upstream, not a data cleanup.


## Nullable Columns
"Why is the column nullable? What happens in Silver?"

All source-derived columns are kept nullable in the Bronze layer, regardless of whether the business expects them to always be populated. Bronze's responsibility is to be a faithful, unfiltered mirror of the source system — not to enforce business rules. Applying a `NOT NULL` constraint at this stage means any row the source sends with a missing value is rejected outright (or fails the whole load), destroying the raw evidence needed to detect, count, and document the data quality issue in the first place.

This is why the audits in this project were run *before* any constraint was applied: columns like `reached_epos` (101 nulls) and `store_id` on `in_store` transactions were only identifiable as findings because Bronze let the incomplete rows land.

**What happens in Silver:**
Once the nulls have been measured and classified — genuine defect vs. an expected business state (e.g. a `redeem` transaction legitimately having no `sku`) — Silver is where constraints get applied. At that point, `NOT NULL` is enforced deliberately and selectively, based on verified findings, with a defined handling strategy (quarantine, default-fill, or flag) for rows that fail it.

The only exception is pipeline-generated metadata columns (e.g. `_ingested_at`, `_source_file`) added during ingestion itself — these can be `NOT NULL` in Bronze because the ingestion process, not the source system, guarantees they're always populated.

**Rule of thumb:** Bronze is a mirror — it reflects whatever arrived, broken or not. Silver is the bouncer — it checks the data against rules that were established *after* looking at it, not before.

## Design Rationale 
"Explain your approach to handling data issues, such as the use of the UNKNOWN_CUSTOMER sentinel (-1) and your rationale for treating negative inventory values as valid adjustments."

## Table Design
"For each of the nine tables: purpose, grain, and primary key choice"

| Table | Purpose | Grain | Primary Key Choice (Silver) |
|---|---|---|---|
| `orders.csv` | Order-level transaction headers from the Legacy POS | One row = one order | `order_id` — source-issued, carried forward as-is |
| `order_items.csv` | Individual product lines within an order | One row = one product line in one order | Composite: `order_id` + line-item identifier — no single source column is unique alone at this grain |
| `customers.csv` | Master customer record from the FreshMart acquisition batch | One row = one customer | `customer_id` — treated as a surrogate/conformed key specifically so Silver and Gold never need to join on PII (email, phone) |
| `supplylink_dc_movements.csv` | Individual stock movement events (receipt / write-off / transfer) at distribution centers | One row = one movement event | `movement_id` — confirmed unique in the Bronze audit (0 duplicate IDs, 0 exact-duplicate movements), so it's trustworthy as-is |
| `rewardsco_loyalty_transactions.csv` | Individual loyalty points-earning/redeeming transactions per customer | One row = one loyalty transaction | `transaction_id` — usable as PK, but the points-sign-convention finding must be resolved before this table feeds any points-balance aggregate |
| `inventory.csv` | Store-level stock position per SKU | *Intended:* one row = one store+SKU stock position | **Not** `inventory_id` alone — confirmed not a safe/unique join key. Silver PK = composite `store_id` + `sku`, rebuilt from the natural key rather than trusting the source's row ID |
| `products.csv` | Master product catalog | One row = one product/SKU | `product_id` / `sku` — the key itself is reliable; it's specific attribute columns (brand, pack_size, is_own_brand) that need cleanup, not the PK |
| `stores.csv` | Master store/location record | One row = one store | `store_id` |
| `suppliers.csv` | Master supplier/vendor record | One row = one supplier | `supplier_id` / `supplier_code` — the `SUP###` code format is already confirmed to join cleanly against `supplylink_dc_movements.supplier_ref` |


## Table Design
"For each of the nine tables: purpose, grain, and primary key choice"

| Table | Source system | Purpose | Grain (one row = ?) | Primary key (Silver) | Why this key |
|---|---|---|---|---|---|
| `orders` | Legacy POS | Order header: who bought, where, when, how they paid, totals | One order (1,228 rows) | `order_id` | Unique on every row. `order_ref` is **not** used as a key: it has 26 repeated values (1,200 distinct in 1,228 rows). The 17 orders with no `customer_id` are kept and mapped to `UNKNOWN_CUSTOMER` (-1), not dropped. |
| `order_items` | Legacy POS | The product lines inside an order: quantity, price, discount | One product on one order (5,310 rows) | `order_item_id` | Source-issued, 0 duplicates. `order_id` points to `orders`, `product_id` points to `products`. |
| `customers` | FreshMart migration | Master record for each customer | One customer (500 rows) | `customer_id` | `email`, `legacy_customer_ref` and `loyalty_member_id` all have blanks (30, 420 and 121 rows), so none of them can be a key. PII columns are dropped in Silver, so `customer_id` is the only join key. |
| `supplylink_dc_movements` | SupplyLink | Stock moving in and out of distribution centres (receipt, write-off, transfer) | One stock movement (11,171 rows) | `movement_id` | 0 duplicate IDs and 0 duplicate movements. Stock-on-hand is worked out by adding up movements, not read from a row. |
| `rewardsco_loyalty_transactions` | RewardsCo | Points earned and redeemed by members | One loyalty transaction (13,439 rows) | `transaction_id` | Unique on every row. `member_id` is a plain number (1–530) while `customers.loyalty_member_id` looks like `NR0000001`, so Silver builds the link by turning `member_id` into `NR` plus 7 digits padded with zeros. On this extract 379 of 530 members match a customer. The other 151 are kept and flagged, not dropped. |
| `inventory` | Inventory system | How much of each product each store has | One product in one store (385 rows) | Composite `store_id` + `product_id` | This pair is unique on all 385 rows. `inventory_id` is also unique inside this one file, but the xlsx copy reuses the same IDs for different store and product pairs, so the ID is not a stable identity. (This table has `product_id`, not `sku`.) |
| `products` | Inventory system | Product catalogue: name, brand, category, price, size | One product (150 rows) | `product_id` | Unique. `sku` is also unique and stays as the business key. The problems in this file are in the `brand`, `is_own_brand` and `pack_size` columns, not in the key. |
| `stores` | Inventory system | Store list: region, type, location | One store (30 rows) | `store_id` | Unique. `store_code` (`NP0XX`) is also unique and stays as the business key. |
| `suppliers` | Inventory system | Supplier list: code, country, payment terms | One supplier (20 rows) | `supplier_id` | Unique. `supplier_code` (`SUP0XX`) is also unique. SupplyLink's `supplier_ref` starts with this code, so that is how movements join to suppliers. |

**Rule used:** a key must be unique and never blank. Where the source ID fails that test, as with `order_ref`, the table uses a different column.

## Indexing Decisions
"Which indexes will be created and why for each and every table? Name the specific query patterns each index supports"

**Rules used**
- Postgres builds an index by itself for every `PRIMARY KEY` and `UNIQUE` constraint, so those are listed as *implicit* and have no `CREATE INDEX` line.
- Foreign key columns are indexed because joins use them (for example "all orders for this customer").
- Columns used in `WHERE` filters or date ranges are indexed.
- A single-column index is not added when it is the first column of an existing multi-column index. That index already serves it, and a copy only slows writes. Two indexes were removed for this reason (`idx_products_sku`, `idx_inventory_store`).
- `np_core` is a live OLTP system with constant inserts, so every index has to earn its place.

### `stores`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `store_id` | Look up one store. Join target for `orders` and `inventory`. |
| implicit (UNIQUE) | `store_code` | Find a store by its code. |
| `idx_stores_region` | `region` | "All stores in this region". Small table, so the gain is small. |
| `idx_stores_type` | `store_type` | "All superstores / locals / express / online_dc". Small table, so the gain is small. |

### `customers`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `customer_id` | Look up one customer. Join target for `orders`. |
| `idx_customers_loyalty` | `loyalty_member_id` | Join to RewardsCo by member ID. |
| `idx_customers_postcode` | `postcode` | Area-level customer analysis. |
| `idx_customers_email` | `email` | Find an account by email (support lookups). 6% of rows have no email. |

### `products`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `product_id` | Look up one product. Join target for `order_items`, `inventory` and `stock_movements`. |
| implicit (UNIQUE) | `sku` | Find a product by SKU. (A separate `idx_products_sku` was a duplicate of this and is removed.) |
| `idx_products_category` | `category_l1, category_l2` | "All products in Food > Dairy", and also category-level only (`category_l1` is the first column). |
| `idx_products_supplier` | `supplier_id` | "All products from this supplier". |

### `suppliers`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `supplier_id` | Look up one supplier. Join target for `products`. |
| implicit (UNIQUE) | `supplier_code` | Find a supplier by code (`SUP0XX`). |

No extra index. It is a 20-row table, so a scan is already fast.

### `orders`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `order_id` | Look up one order. Join target for `order_items`. |
| implicit (UNIQUE) | `order_ref` | Find an order by its reference (`NP-YYYY-XXXXXXX`). |
| `idx_orders_customer` | `customer_id` | "All orders by this customer" (order history). |
| `idx_orders_store` | `store_id` | "All orders at this store" (store sales). |
| `idx_orders_date` | `order_date` | Date-range reports, such as daily or monthly sales. |
| `idx_orders_channel` | `order_channel` | Filter by in_store, online or click_collect. Only 3 values, so it helps most on big tables. |
| `idx_orders_status` | `order_status` | Filter by status, such as completed. Same caveat as above. |

### `order_items`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `order_item_id` | Look up one line. |
| `idx_order_items_order` | `order_id` | "All lines on this order". This is the join back to `orders`. |
| `idx_order_items_product` | `product_id` | "Every order this product appears in" (product sales). |

### `inventory`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `inventory_id` | Look up one row. |
| implicit (UNIQUE) | `store_id, product_id` | "Stock of this product in this store". It also serves "everything in this store", because `store_id` is the first column. (A separate `idx_inventory_store` was redundant and is removed.) |
| `idx_inventory_product` | `product_id` | "This product's stock across all stores". Needed, because `product_id` is the second column of the unique index and can't be searched on its own. |

### `stock_movements`
(Exists in `np_core` only. It is not one of the nine extracted files.)

| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `movement_id` | Look up one movement. |
| `idx_movements_store` | `store_id` | "All movements at this store". |
| `idx_movements_product` | `product_id` | "History of this product", used to work out stock on hand. |
| `idx_movements_date` | `movement_date` | Date-range reports. |
| `idx_movements_type` | `movement_type` | Filter by receipt, sale, return, adjustment, transfer or write_off. |

### `supplylink_dc_movements`
(Proposed. This external system has no table in the DDL file yet.)

| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `movement_id` | Look up one movement. |
| `idx_dc_movements_sku_date` | `sku, movement_date` | "Movements for this product, in date order". Used to work out stock on hand. It also serves a plain `sku` filter. |
| `idx_dc_movements_date` | `movement_date` | Date-range reports across all products. |
| `idx_dc_movements_dc` | `dc_code` | "All movements at this distribution centre". |
| `idx_dc_movements_type` | `movement_type` | Filter by receipt, write_off or transfer. |

The date index only works if `movement_date` is stored as a real `DATE`. Raw text would sort wrongly (see the mixed-format finding).

### `rewardsco_loyalty_transactions`
| Index | Columns | Query pattern it supports |
|---|---|---|
| implicit (PK) | `transaction_id` | Look up one transaction. |
| `idx_loyalty_member_date` | `member_id, transaction_at` | "This member's points history, in order". Used to work out a running balance. It also serves a plain `member_id` filter. |
| `idx_loyalty_date` | `transaction_at` | Date-range reports across all members. |
| `idx_loyalty_type` | `transaction_type` | Filter earn vs redeem. |
| `idx_loyalty_store` | `store_id` | "Loyalty activity at this store". |
| `idx_loyalty_channel` | `channel` | Filter by in_store, online or click_collect. |
| `idx_loyalty_sku` | `sku` | "Loyalty transactions for this product". |

**Total after clean-up:** 25 explicit indexes across 9 tables (plus the implicit PK and UNIQUE ones).


## GitHub Evidence

https://github.com/datawithhasan/northpeak-data-platform