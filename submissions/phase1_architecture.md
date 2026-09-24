# Phase 1 Submission: Platform Architecture and Sprint 0

**Submission**
**Sprint 0: 24-27 September 2026**
**Phase:** Architecture and Onboarding

---

## Section 1: Business Problem (Context)

*Describe what business problem NorthPeak is trying to solve and why a data platform is the answer.*

NorthPeak is struggling with a fragmented data landscape. Because the company grew through acquisitions between 2018 and 2023, it now relies on five completely different source systems that do not talk to each other.

### Here is the breakdown of the business problem:

- Data Silos: Different systems use different definitions and formats, making it impossible to get a single, accurate view of daily sales or inventory levels across all 247 stores.
- Lack of Visibility: The business is currently blind to silent failures. For example, technical issues in the supply chain are often mistaken for drops in customer demand, which leads to poor decision-making.
- Operational Bottlenecks: Simple tasks, such as responding to a customer's request for their data (GDPR/DSAR), take far too long because staff must manually pull records from five disconnected sources.
- Inability to Scale: Management cannot generate reliable T+1 (next-day) performance dashboards, which are critical for staying competitive in the retail grocery sector.

### A unified data platform solves these issues by acting as a central nervous system for the business:

- Automated Governance: It standardizes inconsistent data from all legacy sources into a clean, unified structure.
- Early Warning Systems: By implementing automated data quality checks, the platform detects technical errors—like supply chain pipeline failures—before they impact management reporting.
- Regulatory Compliance: Centralizing the data makes it possible to search and retrieve specific customer records within the mandatory 30-day window.
- Reliable Analytics: It replaces guesswork with a "single version of the truth," giving leadership the confidence that their reports are based on accurate, audited data.

---

## Section 2: Architecture Decision (Implementation)

*Explain why the medallion architecture was choosen.*

Reference: See `/architecture/ADR/ADR-001-medallion-architecture.md` 

The Medallion architecture acts as a pipeline that filters, cleans, and structures data as it moves from raw chaos into business-ready insights.

- Bronze is our raw landing zone. We keep it exactly as it came from the source systems. This is our safety net; if we ever need to re-run our pipelines, we have the original, untampered evidence.

- Silver is our quality-controlled layer. Here, we fix the "noisy" data by deduplicating records, standardizing timezones to UTC, and masking sensitive information. This is where we catch and quarantine records that don't meet our standards, ensuring the Gold layer stays reliable.

- Gold is our decision-ready layer. We organize the data into a star schema, which is the industry standard for retail reporting. This makes it incredibly easy for analysts and business users to query sales, inventory, and loyalty data without needing to understand the complex backend plumbing.

By using this approach, we ensure that every piece of data is traceable, clean, and easily accessible. We aren't just moving files; we are transforming raw logs into a reliable asset for the business.

---

## Section 3: Technical Justification (Technical Decision)

*Why were these specific tools choosen?*


### Why PySpark over plain Python for the pipeline?

Plain Python (e.g. pandas) loads an entire dataset into a single machine's memory, which does not scale to NorthPeak's real transaction volume across five source systems. PySpark distributes processing across multiple cores or machines, allowing the same code to run unmodified from a local development environment through to a production cluster. PySpark is also the open-source engine underlying Databricks Runtime (see ADR-001 enterprise mapping), so pipeline logic written here transfers directly to that platform without rewriting.

### Why DuckDB as the local warehouse?

DuckDB provides a full analytical SQL engine (joins, window functions, aggregates) as an embedded library, requiring no server or cluster setup. It serves as a local, zero-infrastructure stand-in for the enterprise warehouse layer (Snowflake / Azure Synapse), enabling development and testing of transformation logic before deployment against a managed cloud warehouse.

### Why dbt Core for transformations?

dbt Core converts SQL transformation logic into version-controlled, testable, and documented code rather than untracked one-off scripts. Its built-in test types (`not_null`, `unique`, `relationships`) formalise and automate data quality checks that would otherwise be performed manually and inconsistently. The `ref()`/`source()` functions construct the model dependency graph automatically, removing the need to manually sequence execution order. dbt is the current industry standard for the Silver-to-Gold transformation layer across cloud platforms, not only Databricks.

### Why Great Expectations for data quality?

Great Expectations formalises ad hoc data validation queries into reusable, version-controlled "expectations" that execute automatically as part of the pipeline, rather than being run manually against a static dataset. This directly supports the `data_quality_bronze_check` task in the Airflow DAG, which halts downstream processing on a quality breach (`--fail-on-breach`). Per ADR-001's enterprise mapping, Great Expectations is the open-source equivalent of commercial data observability tools such as Monte Carlo or Acceldata.

### Why Delta Lake OSS?

Bronze data is stored as raw, append-only Parquet with no update capability by design, preserving a full audit trail. Silver requires operations Parquet alone cannot support — deduplication, PII masking, and correction of individual records — which require true update/delete semantics. Delta Lake adds a transaction log on top of Parquet, providing ACID guarantees, `MERGE`/upsert support, and time travel (the ability to query a table's prior state). This is why Delta is introduced starting at the Silver layer rather than Bronze. Delta Lake OSS is the open-source foundation of Databricks' own Delta Lake implementation.

### Why Airflow, in Docker?

Airflow manages task dependencies (Silver cannot begin before Bronze completes), retry behaviour on transient source-system failures, scheduling, and SLA monitoring (Gold tables available by 06:00 UTC), none of which are handled by manually run scripts or cron. Running Airflow via Docker avoids a system-wide install and keeps the environment reproducible and disposable, consistent with the project's approach to environment isolation more broadly. Per ADR-001, this locally-run orchestration maps to Databricks Workflows or AWS MWAA in an enterprise deployment.

### Why GitHub Actions?

GitHub Actions automatically runs validation (dbt tests, linting) against every pull request before it can be merged into `main`, enforcing data and code quality as an automated gate rather than relying solely on manual review. This is the free, open-source equivalent of enterprise CI/CD tooling such as Azure DevOps or Jenkins, per ADR-001's mapping.

### Why Terraform, and why `plan` rather than `apply`?

Terraform defines infrastructure as version-controlled, reviewable code rather than manual configuration through a cloud console. `terraform plan` produces a dry run showing exactly what would change without provisioning any resources. `plan` is used in place of `apply` here because the objective is to demonstrate correct, reviewable infrastructure-as-code design without requiring a paid cloud account; the same configuration would be applied unchanged against a real Azure or AWS environment in an enterprise deployment.

---

## Section 4: Alternatives Considered

*What other architecture would have worked but was not choosen?*

### Single Flat Warehouse

Loading all five source systems directly into one warehouse layer, with transformations applied in place, was considered. This was rejected because it provides no audit trail back to the original source data, offers no way to safely reprocess history if a transformation bug is discovered, and creates an unsafe PII boundary — raw and masked customer data would sit in the same layer with no clear separation. The medallion architecture's Bronze layer solves this directly by keeping an untouched, append-only copy of every source record before any transformation is applied.

### Fivetran + Snowflake Only

A fully managed ELT stack (Fivetran for ingestion, Snowflake as the warehouse, transformations in Snowflake SQL) was considered, since this is a common real-world enterprise pattern. This was rejected for this project specifically because both tools are paid/commercial, which is not viable for a self-directed portfolio build; it would not demonstrate PySpark skills, which are a stated requirement for the target Data Engineer role; and it is not accessible to someone building a project without a company-funded account, unlike the open-source stack chosen (PySpark, Delta Lake OSS, DuckDB, dbt Core, Airflow).

### Lambda Architecture (Batch + Streaming)

A Lambda architecture — running a real-time streaming path alongside the batch pipeline for near-instant data availability — was considered given RewardsCo's API and GroceryDirect's online order volume. This was deferred rather than rejected outright: the current business requirement is a T+1 dashboard (data available by the next day, not the next second), which the batch-only medallion pipeline fully satisfies on its own. Adding a streaming path now would introduce meaningful additional complexity (a second processing path, event ordering, state management) without a corresponding SLA that requires it. It remains an optional Phase 8 extension if a genuine low-latency requirement emerges later.

---

## Section 5: User Stories (Azure DevOps format)

*3 user stories for the work I am about to do.*

**User Story 1:**
As a Data Engineer, I want to profile raw source files (schema, nulls, uniqueness, referential integrity) before declaring dbt sources, so that downstream models are built against the file's real structure instead of assumed or undocumented columns.
Acceptance criteria:
- Given a new or undocumented source file, when I run the profiling checks, then I have a confirmed column list, null rates, and referential integrity results before writing any dbt source or model.

**User Story 2:**
As a Data Analyst consuming the Gold-layer sales dashboards, I want orders with a missing or unmatched customer_id to be flagged with a known sentinel value rather than dropped or left null, so that total revenue figures in FactSales are never silently undercounted.
Acceptance criteria:
- Given an order with a customer_id that is null or has no matching row in DimCustomer, when FactSales is built, then that order is retained and assigned customer_key = -1 instead of being excluded from the table.

**User Story 3:**
As the Data Platform Manager, I want the "unknown customer" rate in FactSales checked against a documented threshold on every run, so that a real upstream data problem is caught before it reaches stakeholder-facing dashboards.
Acceptance criteria:
- Given the sales data contract's documented threshold (warn at 6%), when the pipeline runs, then the actual unknown-customer rate is measured and the run is flagged if it exceeds that threshold.

---

## Section 6: Production Consideration

*How would this architecture differ in a real enterprise deployment on Azure/Databricks?*

Reference: See `/architecture/cloud-mapping/local-to-azure-databricks.md`

The core design does not change in production — the same medallion layers, the same dbt models, the same Airflow DAGs, and the same PySpark transformation code would run largely unmodified on Azure/Databricks. What changes is scale, infrastructure management, and governance enforcement, not application logic.

**Compute and storage.** Local PySpark runs single-machine; Databricks Runtime adds auto-scaling clusters and the Photon engine, so the same code processes far larger volumes without a rewrite. Local Parquet files would move to Azure Data Lake Storage Gen2, gaining encryption at rest and access control through Azure Active Directory. DuckDB, used locally as a stand-in warehouse, comfortably handles gigabyte-scale data; a real deployment would move to Snowflake or Azure Synapse Analytics for petabyte-scale query performance.

**Orchestration.** The DAG files themselves are portable as-is — the same Python code deploys to Databricks Workflows, AWS MWAA, or Cloud Composer. What disappears in production is the operational burden of running and maintaining Airflow's own infrastructure (the Docker containers, scheduler, metadata database); a managed orchestrator removes that entirely.

**Transformation and data quality.** dbt Core's model logic is warehouse-agnostic — migrating from DuckDB to Snowflake or Databricks SQL is a one-line change in `profiles.yml`, not a rewrite of any model. Great Expectations' YAML expectation suites are portable to enterprise equivalents like Monte Carlo or GE Cloud, which add ML-based anomaly detection and direct alerting (Slack/PagerDuty) on top of the same underlying checks already defined here.

**Security and governance — the most consequential production change.** This is where local and enterprise diverge most, not because the design is wrong, but because production carries real regulatory weight: NP Financial's FCA-regulated data and real customer PII mean secrets can no longer live in a local `.env` file — they'd move to Azure Key Vault with managed identity, and access would be enforced programmatically through Azure RBAC and Unity Catalog rather than documented manually. Unity Catalog specifically enforces the YAML data contracts used here at the query level, rather than relying on convention and code review alone.

**Net effect:** the local build demonstrates the same architecture, the same code, and the same governance patterns an enterprise deployment uses — production mainly swaps self-managed infrastructure for managed equivalents and adds the regulatory-grade enforcement (encryption, RBAC, Key Vault) that real customer and financial data legally requires.

---
*How would this architecture differ in a real enterprise deployment on Azure/Databricks?*

Reference: See `/architecture/cloud-mapping/local-to-azure-databricks.md`

[YOUR ANSWER HERE]

---

## Evidence Required

- [ ] ADR-001 committed to `/architecture/ADR/`
- [ ] Cloud mapping doc reviewed and annotated
- [ ] 3 user stories written above
- [ ] GitHub repository URL: https://github.com/alain-Sortnext/northpeak-data-platform
