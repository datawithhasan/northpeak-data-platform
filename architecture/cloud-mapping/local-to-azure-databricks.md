# Local Stack to Azure Databricks Enterprise Mapping

This document maps every tool used in this project to its enterprise equivalent on Azure/Databricks.

---

## Compute and Processing

| Simulation | Enterprise | Key Difference |
|---|---|---|
| PySpark 3.5 local mode | Databricks Runtime 14.x on Azure | Same API. Databricks adds Photon engine, auto-scaling clusters, GPU support |
| `spark.read.parquet()` | Same in Databricks | Identical code |
| Local SparkSession | Databricks cluster SparkSession | Cluster managed by Databricks - no setup needed |

## Storage and Table Format

| Simulation | Enterprise | Key Difference |
|---|---|---|
| Delta Lake OSS (delta-rs 0.18) | Databricks Delta Lake | Databricks adds OPTIMIZE ZORDER, Vacuum automation, Delta Sharing |
| Local Parquet files | Azure Data Lake Storage Gen2 (ADLS) | ADLS adds access control via Azure Active Directory, encryption at rest |
| DuckDB 0.10 (warehouse) | Snowflake / Azure Synapse Analytics | Scale: DuckDB handles GB, Synapse handles PB |

## Orchestration

| Simulation | Enterprise | Key Difference |
|---|---|---|
| Apache Airflow 2.9 (Docker Compose) | Databricks Workflows / AWS MWAA / Google Cloud Composer | Managed Airflow removes infrastructure burden |
| Local DAG files | Same DAG files deployed to managed Airflow | DAG code is identical |
| Airflow retry config | Same retry/alert config in Databricks Workflows | Databricks Workflows uses JSON task config instead of Python decorator |

## Transformation

| Simulation | Enterprise | Key Difference |
|---|---|---|
| dbt Core 1.8 (free) | dbt Cloud / Databricks dbt integration | dbt Cloud adds IDE, scheduler, CI/CD, metadata sync |
| dbt + DuckDB adapter | dbt + Snowflake / Databricks / Synapse adapter | Change one line in `profiles.yml` |
| Local dbt docs | dbt Cloud docs hosting | Same HTML output, hosted automatically |

## Data Quality

| Simulation | Enterprise | Key Difference |
|---|---|---|
| Great Expectations 0.18 | Monte Carlo / Acceldata / GE Cloud | Enterprise tools add ML-based anomaly detection, Slack/PagerDuty integration |
| YAML expectation suites | Same concept in enterprise tools | GE OSS suites are portable to GE Cloud |
| pytest pipeline tests | Same pytest in CI/CD | No difference in test code |

## CI/CD and Infrastructure

| Simulation | Enterprise | Key Difference |
|---|---|---|
| GitHub Actions (free tier) | Azure DevOps Pipelines / Jenkins | Same YAML structure. Azure DevOps adds service connections, environments |
| Terraform CLI plan output | Azure provider full deployment | Same HCL syntax. Production adds state backend (Azure Storage), remote planning |
| Local `.env` secrets | Azure Key Vault / AWS Secrets Manager | Never commit secrets. Enterprise uses managed identity |

## Governance

| Simulation | Enterprise | Key Difference |
|---|---|---|
| YAML data contracts | Unity Catalog (Databricks) / Collibra / Alation | Unity Catalog enforces contracts at query level |
| Custom logging | Azure Monitor / Datadog / CloudWatch | Enterprise tools add dashboards, alerting, cost attribution |
| Manual access control docs | Azure RBAC + Unity Catalog permissions | Programmatic enforcement at storage and compute level |

---


> "We used PySpark locally, but the same code runs unchanged on Databricks. I designed the pipeline to be cloud-portable from day one by avoiding local file paths and using Delta format which Databricks natively supports."

> "Our Airflow DAGs would deploy directly to AWS MWAA or Cloud Composer because we followed standard operator patterns and kept all connection strings in environment variables, not hardcoded."

> "The dbt project targets DuckDB locally but changing one profile setting migrates it to Snowflake or Databricks SQL. The model logic is warehouse-agnostic."
