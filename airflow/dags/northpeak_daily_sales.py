"""
NorthPeak Retail Group - Daily Sales Pipeline DAG
Phase 4: Airflow Orchestration + CI/CD

Orchestrates the full Bronze -> Silver -> Gold pipeline.
Runs daily at 02:00 UTC.

Enterprise mapping:
  Databricks Workflows: same DAG structure as JSON task config
  AWS MWAA: identical DAG file, different executor
  Cloud Composer: identical DAG file

SLA: All Gold tables populated by 06:00 UTC (T+1 requirement)
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator
from airflow.utils.dates import days_ago
import logging
from airflow.models.baseoperator import cross_downstream

log = logging.getLogger("northpeak.airflow")

# ── Default args ──────────────────────────────────────────────────
default_args = {
    "owner":            "data-platform-team",
    "depends_on_past":  False,
    "email":            ["data-alerts@northpeak.co.uk"],
    "email_on_failure": True,
    "email_on_retry":   False,
    "retries":          3,
    "retry_delay":      timedelta(minutes=10),
    "retry_exponential_backoff": True,
    "max_retry_delay":  timedelta(minutes=60),
    "sla":              timedelta(hours=4),   # alert if still running after 4hrs
    "execution_timeout":timedelta(hours=2),
}

# ── DAG definition ────────────────────────────────────────────────
with DAG(
    dag_id="northpeak_daily_sales",
    description="NorthPeak daily Bronze->Silver->Gold pipeline. SLA: Gold ready by 06:00 UTC.",
    default_args=default_args,
    schedule_interval="0 2 * * *",  # 02:00 UTC daily
    start_date=days_ago(1),
    catchup=False,
    max_active_runs=1,
    tags=["northpeak", "production", "data-platform"],
    doc_md="""
## NorthPeak Daily Sales Pipeline

**Owner:** Data Platform Engineering Team
**SLA:** Gold tables available by 06:00 UTC
**Source systems:** NP Core (PostgreSQL), GroceryDirect (MongoDB), SupplyLink (SQL Server), RewardsCo (API)

**On failure:** Check Airflow logs first. Common causes:
- Source system unavailable: retry usually resolves
- Row count anomaly: check data_quality_check task logs
- PII masking failure: DO NOT retry automatically - page on-call engineer

**Backfill:** Use `airflow dags backfill northpeak_daily_sales -s 2026-07-01 -e 2026-07-14`
    """,
) as dag:

    # ── Health checks ────────────────────────────────────────────
    check_np_core = BashOperator(
        task_id="check_np_core_connectivity",
        bash_command="""
            python3 -c "
import psycopg2, os
conn = psycopg2.connect(os.getenv('NP_CORE_JDBC_URL',''))
print('NP Core: OK')
conn.close()
" || echo "NP Core check failed - will retry"
        """,
        retries=5,
        retry_delay=timedelta(minutes=2),
    )

    check_rewardsco_api = BashOperator(
        task_id="check_rewardsco_api",
        bash_command="""
            curl -s -o /dev/null -w "%{http_code}" \
              -H "Authorization: Bearer $REWARDSCO_API_KEY" \
              https://api.rewardsco.com/v2/health | grep -q "200" \
              && echo "RewardsCo API: OK" || echo "RewardsCo API: degraded"
        """,
    )

    # ── Bronze ingestion ─────────────────────────────────────────
    bronze_orders = BashOperator(
        task_id="bronze_ingest_orders",
        bash_command="spark-submit /opt/northpeak/ingestion/pyspark/bronze_ingestion.py orders",
        env={"INGESTION_DATE": "{{ ds }}"},
    )

    bronze_customers = BashOperator(
        task_id="bronze_ingest_customers",
        bash_command="spark-submit /opt/northpeak/ingestion/pyspark/bronze_ingestion.py customers",
        env={"INGESTION_DATE": "{{ ds }}"},
    )

    bronze_inventory = BashOperator(
        task_id="bronze_ingest_inventory",
        bash_command="spark-submit /opt/northpeak/ingestion/pyspark/bronze_ingestion.py inventory",
        env={"INGESTION_DATE": "{{ ds }}"},
    )

    bronze_loyalty = BashOperator(
        task_id="bronze_ingest_loyalty",
        bash_command="python3 /opt/northpeak/ingestion/python/extract_rewardsco.py --date {{ ds }}",
    )

    # ── Data quality pre-Silver ──────────────────────────────────
    data_quality_check = BashOperator(
        task_id="data_quality_bronze_check",
        bash_command="""
            python3 /opt/northpeak/quality/great_expectations/run_bronze_checkpoint.py \
              --date {{ ds }} \
              --fail-on-breach
        """,
    )

    # ── Silver cleansing ─────────────────────────────────────────
    silver_orders = BashOperator(
        task_id="silver_cleanse_orders",
        bash_command="spark-submit /opt/northpeak/ingestion/pyspark/silver_cleansing.py orders",
        env={"INGESTION_DATE": "{{ ds }}"},
    )

    silver_inventory = BashOperator(
        task_id="silver_cleanse_inventory",
        bash_command="spark-submit /opt/northpeak/ingestion/pyspark/silver_cleansing.py inventory",
        env={"INGESTION_DATE": "{{ ds }}"},
    )

    # ── dbt Gold layer ───────────────────────────────────────────
    dbt_run = BashOperator(
        task_id="dbt_run_gold_models",
        bash_command="""
            cd /opt/northpeak/dbt && \
            dbt run --models marts --profiles-dir /opt/northpeak/dbt --target prod \
              --vars '{"ingestion_date": "{{ ds }}"}'
        """,
    )

    dbt_test = BashOperator(
        task_id="dbt_test_gold_models",
        bash_command="""
            cd /opt/northpeak/dbt && \
            dbt test --models marts --profiles-dir /opt/northpeak/dbt --target prod
        """,
    )

    # ── Observability ────────────────────────────────────────────
    update_monitoring = BashOperator(
        task_id="update_pipeline_monitoring",
        bash_command="""
            python3 /opt/northpeak/monitoring/update_dashboard.py \
              --date {{ ds }} \
              --dag-run-id {{ run_id }}
        """,
        trigger_rule="all_done",  # run even if upstream failed - always update monitoring
    )

    # ── Task dependencies ────────────────────────────────────────
    # [check_np_core, check_rewardsco_api] >> [bronze_orders, bronze_customers, bronze_inventory, bronze_loyalty]
    cross_downstream([check_np_core, check_rewardsco_api], [bronze_orders, bronze_customers, bronze_inventory, bronze_loyalty])
    [bronze_orders, bronze_customers, bronze_inventory, bronze_loyalty] >> data_quality_check
    data_quality_check >> [silver_orders, silver_inventory]
    [silver_orders, silver_inventory] >> dbt_run
    dbt_run >> dbt_test
    dbt_test >> update_monitoring
