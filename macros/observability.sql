{#
    Table-based pipeline audit logging.

    Every run writes to:

        <catalog>.observability.pipeline_step_log

    Rows are appended at three levels:

      run_start / run_end   model_name = '__run__'
      start / end           one pair per model
      <step>                inline steps from log_step()

    The `end` row carries the metrics that make idempotency checkable:

      rows_read      sum of the direct parents' row counts (logical inputs)
      rows_written   count(*) of the model relation after materialisation
      content_hash   sum(hash(...)) over stable columns only

    Volatile columns (`_ingest_ts`, `_loaded_at`, `dbt_*`) are excluded from
    the hash so a re-run of an idempotent model produces the same fingerprint.

    The companion model `observability.idempotency_check` compares the latest
    two `end` rows per model.
#}


{#- Fully-qualified audit table name, e.g. dbt.observability.pipeline_step_log -#}
{% macro audit_relation() -%}
    {{ target.catalog }}.{{ var('audit_schema', 'observability') }}.{{ var('audit_table', 'pipeline_step_log') }}
{%- endmacro %}


{#- Safe SQL string literal (or typed NULL). -#}
{% macro sql_str(value) -%}
    {%- if value is none -%}
        cast(null as string)
    {%- else -%}
        '{{ value | string | replace("'", "''") }}'
    {%- endif -%}
{%- endmacro %}


{#- Create the observability schema (idempotent). -#}
{% macro create_audit_schema() -%}
    create schema if not exists {{ target.catalog }}.{{ var('audit_schema', 'observability') }}
{%- endmacro %}


{#- Create the append-only audit table (idempotent). -#}
{% macro create_audit_table() -%}
create table if not exists {{ audit_relation() }} (
    run_id          string    comment 'dbt invocation_id; groups all rows from one invocation',
    logged_at       timestamp comment 'When this event row was written',
    target_name     string    comment 'dbt target (dev / prod)',
    catalog_name    string    comment 'Unity Catalog catalog the model lives in',
    schema_name     string    comment 'Schema the model lives in (bronze / silver / gold)',
    model_name      string    comment 'Model name, or __run__ for run-level rows',
    materialization string    comment 'table / view / incremental / run',
    step            string    comment 'start, end, run_start, run_end, or an inline step name',
    status          string    comment 'started / success / error / step',
    rows_read       bigint    comment 'Sum of direct parent row counts (logical inputs)',
    rows_written    bigint    comment 'count(*) of the model relation after the run',
    content_hash    string    comment 'Stable-column fingerprint used for idempotency checks',
    detail          string    comment 'Free-form context (file name, window, run summary)'
)
using delta
tblproperties ('delta.autoOptimize.optimizeWrite' = 'true')
{%- endmacro %}


{#- Count the model's direct parents. Falls back to the model itself for
    source-less models (bronze read_files, dim_date spine). -#}
{% macro rows_read_sql() -%}
    {%- set parts = [] -%}
    {%- for node_id in model.depends_on.nodes -%}
        {%- set node = graph.nodes.get(node_id) -%}
        {%- if node is not none -%}
            {%- set rel = node.relation_name -%}
            {%- if rel is none -%}
                {%- if node.resource_type == 'source' -%}
                    {%- set identifier = node.identifier -%}
                {%- else -%}
                    {%- set identifier = node.alias -%}
                {%- endif -%}
                {%- set rel = node.database ~ '.' ~ node.schema ~ '.' ~ identifier -%}
            {%- endif -%}
            {%- do parts.append('(select count(*) from ' ~ rel ~ ')') -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if parts | length == 0 -%}
        (select count(*) from {{ this }})
    {%- else -%}
        ({{ parts | join(' + ') }})
    {%- endif -%}
{%- endmacro %}


{#- Fingerprint over business columns only. Volatile audit columns are
    excluded so a re-run of an idempotent model hashes identically. -#}
{% macro content_hash_sql() -%}
    {%- set cols = adapter.get_columns_in_relation(this) -%}
    {%- set stable = [] -%}
    {%- for c in cols -%}
        {%- set n = c.name | lower -%}
        {%- if n != 'detected_at'
              and not n.startswith('_ingest')
              and not n.startswith('_loaded')
              and not n.startswith('dbt_') -%}
            {%- do stable.append(c.name) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if stable | length == 0 -%}
        cast(0 as string)
    {%- else -%}
        cast(coalesce(sum(cast(hash({{ stable | join(', ') }}) as decimal(38, 0))), 0) as string)
    {%- endif -%}
{%- endmacro %}


{#- One-row SELECT returning the three metrics for the current model. -#}
{% macro model_metrics_sql() -%}
select
    {{ rows_read_sql() }} as rows_read,
    (select count(*) from {{ this }}) as rows_written,
    {{ content_hash_sql() }} as content_hash
from {{ this }}
{%- endmacro %}


{#- True when computing this model's `end` metrics would SCAN the audit table.

    Such a statement reads and appends to pipeline_step_log inside ONE Delta
    transaction. While other threads' hooks append concurrently, Delta rejects
    the commit with DELTA_CONCURRENT_APPEND.ROW_LEVEL_CHANGES and dbt marks
    the otherwise-successful model as failed. Observed 2026-11-06 on
    pipeline_step_timeline in BOTH catalogs (dev run under classic dbt, prod
    run under dbt Fusion) - the metrics SELECT reads the very table the
    INSERT writes, so any concurrent hook append can land between the read
    snapshot and the commit.

    Models that live in - or directly source - the audit table therefore
    record NULL metrics on their `end` rows: they are observability views,
    not pipeline models, and idempotency_check already excludes their schema
    (see models/observability/idempotency_check.sql), so the documented
    "24/24 pipeline models idempotent" claim is unaffected.
#}
{% macro model_reads_audit() -%}
    {%- set audit_schema = (var('audit_schema', 'observability') | lower) -%}
    {%- set audit_table = (var('audit_table', 'pipeline_step_log') | lower) -%}
    {%- if this is defined and this.schema is defined and (this.schema | lower) == audit_schema -%}
        {{ return(true) }}
    {%- endif -%}
    {%- for node_id in model.depends_on.nodes -%}
        {%- set node = graph.nodes.get(node_id) -%}
        {%- if node is not none and node.schema is defined -%}
            {%- set ident = node.identifier if node.resource_type == 'source' else node.alias -%}
            {%- if (node.schema | lower) == audit_schema and (ident | lower) == audit_table -%}
                {{ return(true) }}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}
    {{ return(false) }}
{%- endmacro %}


{#- INSERT for a model start or end event. End events include metrics unless
    the metric query would read the audit table itself (model_reads_audit) -#}
{% macro insert_model_event(step, status, detail=none) -%}
{%- set with_metrics = step == 'end' and status == 'success' and not model_reads_audit() -%}
insert into {{ audit_relation() }}
select
    '{{ invocation_id }}' as run_id,
    current_timestamp() as logged_at,
    '{{ target.name }}' as target_name,
    '{{ this.database }}' as catalog_name,
    '{{ this.schema }}' as schema_name,
    '{{ model.name }}' as model_name,
    '{{ model.config.materialized | string }}' as materialization,
    '{{ step }}' as step,
    '{{ status }}' as status,
    {%- if with_metrics %}
    metrics.rows_read as rows_read,
    metrics.rows_written as rows_written,
    metrics.content_hash as content_hash,
    {%- else %}
    cast(null as bigint) as rows_read,
    cast(null as bigint) as rows_written,
    cast(null as string) as content_hash,
    {%- endif %}
    {{ sql_str(detail) }} as detail
{%- if with_metrics %}
from ({{ model_metrics_sql() }}) as metrics
{%- endif %}
{%- endmacro %}


{#- Side-effect INSERT used by inline log_step() calls. This runs during
    compilation via run_query(), so it is only invoked for run/build. -#}
{% macro insert_step_event(step, detail=none, model_name=none) -%}
    {%- set name = model_name if model_name is not none else model.name -%}
    {%- set sql -%}
insert into {{ audit_relation() }}
select
    '{{ invocation_id }}',
    current_timestamp(),
    '{{ target.name }}',
    '{{ this.database }}',
    '{{ this.schema }}',
    '{{ name }}',
    '{{ model.config.materialized | string }}',
    '{{ step }}',
    'step',
    cast(null as bigint),
    cast(null as bigint),
    cast(null as string),
    {{ sql_str(detail) }}
    {%- endset -%}
    {%- do run_query(sql) -%}
{%- endmacro %}


{#- Convenience operation: print the idempotency verdict per model.

    Usage:
        dbt run-operation check_idempotency --profiles-dir .
#}
{% macro check_idempotency() -%}
    {%- set sql -%}
select
    model_name,
    is_idempotent,
    row_delta,
    latest_rows_written,
    previous_rows_written,
    latest_content_hash,
    previous_content_hash
from {{ target.catalog }}.{{ var('audit_schema', 'observability') }}.idempotency_check
order by model_name
    {%- endset -%}
    {%- set res = run_query(sql) -%}
    {%- if execute and res is not none -%}
        {%- for row in res.rows -%}
            {{ log(
                'idempotency: model=' ~ row[0]
                ~ ' is_idempotent=' ~ row[1]
                ~ ' row_delta=' ~ row[2]
                ~ ' rows=' ~ row[4] ~ '->' ~ row[3],
                info=true
            ) }}
        {%- endfor -%}
    {%- endif -%}
{%- endmacro %}
