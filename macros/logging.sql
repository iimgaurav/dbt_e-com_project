{#
    Structured, model-level logging.

    Two sinks receive every event:

      1. stdout / logs/dbt.log  - greppable `[sales_analytics] ...` lines
      2. <catalog>.observability.pipeline_step_log - queryable audit table

    Levels:

      run    on-run-start / on-run-end   model_name = '__run__'
      model  project pre/post hooks      start + end rows (end carries metrics)
      step   inline {{ log_step('...') }} rows written via run_query()

    All logging is gated on `{% if execute %}` so dbt's parse pass is silent.
    Inline table writes are additionally gated on run/build so `dbt compile`
    never mutates the audit table.
#}


{#- Console-only log line. -#}
{% macro log_line(step, detail=none, model_name=none) -%}
    {%- set name = model_name if model_name is not none else model.name -%}
    {%- set schema_name = target.schema -%}
    {%- set catalog_name = target.catalog -%}
    {%- if this is defined -%}
        {%- set schema_name = this.schema -%}
        {%- set catalog_name = this.database -%}
    {%- endif -%}
    {%- set msg = '[' ~ project_name ~ ']'
        ~ ' model=' ~ name
        ~ ' step=' ~ step
        ~ ' target=' ~ target.name
        ~ ' catalog=' ~ catalog_name
        ~ ' schema=' ~ schema_name -%}
    {%- if detail is not none -%}
        {%- set msg = msg ~ ' detail=' ~ detail -%}
    {%- endif -%}
    {%- if execute -%}
        {{ log(msg, info=true) }}
    {%- endif -%}
{%- endmacro %}


{#- Inline step: console line + audit-table row (run/build only). -#}
{% macro log_step(step, model_name=none, detail=none) -%}
    {{ log_line(step, detail=detail, model_name=model_name) }}
    {%- if execute and flags.WHICH in ['run', 'build'] and model is defined -%}
        {%- do insert_step_event(step, detail=detail, model_name=model_name) -%}
    {%- endif -%}
{%- endmacro %}


{#- Pre-hook: console line + audit `start` row. -#}
{% macro log_model_start() -%}
    {{ log_line('start') }}
    {%- if execute -%}
        {{ insert_model_event('start', 'started') }}
    {%- else -%}
        select 1
    {%- endif -%}
{%- endmacro %}


{#- Post-hook: console line + audit `end` row with metrics. -#}
{% macro log_model_end() -%}
    {{ log_line('end') }}
    {%- if execute -%}
        {{ insert_model_event('end', 'success') }}
    {%- else -%}
        select 1
    {%- endif -%}
{%- endmacro %}


{#- on-run-start: console line + audit `run_start` row. -#}
{% macro log_run_start() -%}
    {%- if execute -%}
        {{ log(
            '[' ~ project_name ~ '] run=start'
            ~ ' target=' ~ target.name
            ~ ' catalog=' ~ target.catalog
            ~ ' ts=' ~ run_started_at,
            info=true
        ) }}
insert into {{ audit_relation() }}
select
    '{{ invocation_id }}',
    current_timestamp(),
    '{{ target.name }}',
    '{{ target.catalog }}',
    '{{ var('audit_schema', 'observability') }}',
    '__run__',
    'run',
    'run_start',
    'started',
    cast(null as bigint),
    cast(null as bigint),
    cast(null as string),
    {{ sql_str('run started at ' ~ run_started_at) }}
    {%- else -%}
        select 1
    {%- endif -%}
{%- endmacro %}


{#- on-run-end: console summary + audit `run_end` row, plus an `error`
    end-row for any model that failed before its post-hook could run. -#}
{% macro log_run_end(results) -%}
    {%- if results | length == 0 -%}
        {#- dbt renders hooks once during parsing; stay silent until a real run. -#}
        select 1
    {%- else -%}
    {%- set ns = namespace(success=0, warn=0, error=0, other=0) -%}
    {%- for r in results -%}
        {%- if r.status in ('success', 'pass') -%}
            {%- set ns.success = ns.success + 1 -%}
        {%- elif r.status == 'warn' -%}
            {%- set ns.warn = ns.warn + 1 -%}
        {%- elif r.status in ('error', 'fail') -%}
            {%- set ns.error = ns.error + 1 -%}
        {%- else -%}
            {%- set ns.other = ns.other + 1 -%}
        {%- endif -%}
    {%- endfor -%}
    {%- set total = results | length -%}
    {{ log(
        '[' ~ project_name ~ '] run=end'
        ~ ' total=' ~ total
        ~ ' success=' ~ ns.success
        ~ ' warn=' ~ ns.warn
        ~ ' error=' ~ ns.error
        ~ ' other=' ~ ns.other,
        info=true
    ) }}
    {%- set detail = 'total=' ~ total
        ~ ' success=' ~ ns.success
        ~ ' warn=' ~ ns.warn
        ~ ' error=' ~ ns.error
        ~ ' other=' ~ ns.other -%}
    {%- set rows = [] -%}
    {%- do rows.append(
        "select '" ~ invocation_id ~ "' as run_id, current_timestamp() as logged_at, "
        ~ sql_str(target.name) ~ " as target_name, " ~ sql_str(target.catalog) ~ " as catalog_name, "
        ~ sql_str(var('audit_schema', 'observability')) ~ " as schema_name, "
        ~ "'__run__' as model_name, 'run' as materialization, 'run_end' as step, "
        ~ sql_str('success' if ns.error == 0 else 'error') ~ " as status, "
        ~ "cast(null as bigint) as rows_read, cast(null as bigint) as rows_written, "
        ~ "cast(null as string) as content_hash, " ~ sql_str(detail) ~ " as detail"
    ) -%}
    {%- for r in results -%}
        {%- if r.node.resource_type == 'model' and r.status in ('error', 'fail') -%}
            {%- do rows.append(
                "select '" ~ invocation_id ~ "', current_timestamp(), "
                ~ sql_str(target.name) ~ ", " ~ sql_str(target.catalog) ~ ", "
                ~ sql_str(r.node.schema) ~ ", " ~ sql_str(r.node.name) ~ ", "
                ~ sql_str(r.node.config.materialized | string) ~ ", 'end', 'error', "
                ~ "cast(null as bigint), cast(null as bigint), cast(null as string), "
                ~ sql_str('run failed with status ' ~ r.status)
            ) -%}
        {%- endif -%}
    {%- endfor -%}
insert into {{ audit_relation() }}
{{ rows | join('\nunion all\n') }}
    {%- endif -%}
{%- endmacro %}
