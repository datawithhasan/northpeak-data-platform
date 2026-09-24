# ADR-001: Medallion Architecture for NorthPeak Data Platform

**Status:** Accepted
**Date:** 24 September 2026
**Author:** Data Platform Engineering Team
**Deciders:** Aisha Okafor (Data Engineering Manager), Marcus Webb (Head of Data Platform)

---

## Context

NorthPeak Retail Group operates five disconnected source systems from acquisitions (2018-2023):

- **NP Core** (PostgreSQL 14) — primary EPOS, orders, customers, inventory
- **GroceryDirect** (MongoDB 6.0) — online orders, returns, baskets
- **SupplyLink** (SQL Server 2019) — DC stock movements, purchase orders
- **RewardsCo** (REST API JSON) — loyalty members, points transactions
- **NP Financial** (Azure SQL) — FCA-regulated credit and insurance

The business requires: unified revenue reporting, GDPR DSAR within 30 days, T+1 dashboards, and a platform built with free/open source tools that maps to enterprise Databricks stacks.

---

## Decision

Implement the **Medallion Architecture** (Bronze / Silver / Gold) using PySpark, Delta Lake OSS, DuckDB, dbt Core, and Apache Airflow.

---

## Layers

**Bronze:** Raw, immutable, append-only Parquet partitioned by `ingestion_date`. No transformation. Full audit trail.

**Silver:** Cleansed Delta tables. Deduplication, PII masking (SHA-256), timezone normalisation (all UTC), null handling (`UNKNOWN_CUSTOMER` flag), quarantine for failed records.

**Gold:** Star schema via dbt. `FactSales`, `FactInventory`, `FactLoyaltyPoints`, `DimCustomer`, `DimProduct`, `DimStore`, `DimDate`, `DimSupplier`.

---

## Alternatives Considered

**Single flat warehouse:** Rejected — no audit trail, cannot reprocess, unsafe PII boundary.

**Fivetran + Snowflake only:** Rejected — paid tools, no PySpark skills demonstrated, not accessible to candidates.

**Lambda architecture (batch + streaming):** Deferred to Phase 8 optional extension. Batch meets all current SLAs.

---

## Local to Enterprise Mapping

| Local | Enterprise Equivalent |
|---|---|
| PySpark local | Databricks Runtime / AWS EMR |
| Delta Lake OSS | Databricks Delta Lake |
| DuckDB | Snowflake / Azure Synapse |
| Airflow Docker | Databricks Workflows / AWS MWAA |
| GitHub Actions | Azure DevOps / Jenkins |
| Terraform plan | Azure / AWS full deployment |
| Great Expectations | Monte Carlo / Acceldata |

---
