{#
    Structured, model-level logging.

    Every model automatically emits a `start` and `end` line through the
    project-level pre/post hooks in dbt_project.yml. Models with multiple
    logical stages also call log_step() inline, e.g.:

        {{ log_step('cleaned') }}

    Output is a single greppable line per event:

        [sales_analytics] model=slv_orders step=cleaned target=dev catalog=dbt schema=silver

    Follow one run with:

        dbt build --profiles-dir . 2>&1 | Select-String '\[sales_analytics\]'
#}


{#- Emit one structured log line for a model step. -#}
{% macro log_step(step, model_name=none, detail=none) -%}
    {%- set name = model_name if model_name is not none else model.name -%}
    {#- Prefer the resolved relation's schema/catalog so logs match where data lands. -#}
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
    {#- `execute` is False while dbt parses; only log real executions. -#}
    {%- if execute -%}
        {{ log(msg, info=true) }}
    {%- endif -%}
{%- endmacro %}


{#- Pre-hook: logs the start of every model. Returns valid SQL for the hook. -#}
{% macro log_model_start() -%}
    {{ log_step('start') }}
    select 1
{%- endmacro %}


{#- Post-hook: logs the successful completion of every model. -#}
{% macro log_model_end() -%}
    {{ log_step('end') }}
    select 1
{%- endmacro %}


{#- on-run-start: one line per invocation. -#}
{% macro log_run_start() -%}
    {%- if execute -%}
    {{ log(
        '[' ~ project_name ~ '] run=start'
        ~ ' target=' ~ target.name
        ~ ' catalog=' ~ target.catalog
        ~ ' ts=' ~ run_started_at,
        info=true
    ) }}
    {%- endif -%}
    select 1
{%- endmacro %}


{#- on-run-end: aggregate status counts for the whole invocation. -#}
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
    select 1
    {%- endif -%}
{%- endmacro %}
