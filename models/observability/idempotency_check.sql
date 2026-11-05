{{ config(materialized='view', tags=['observability']) }}

{#
    Idempotency verdict per pipeline model.

    For every model, compare the latest successful `end` audit row with the
    previous one. A model is idempotent when both are true:

      * rows_written is unchanged          (no duplicated / lost rows)
      * content_hash is unchanged          (same business data)

    content_hash ignores volatile columns (_ingest_ts, _loaded_at, dbt_*), so
    re-running a deterministic model yields the same fingerprint.

    `is_idempotent` is NULL when a model has only one observed run. Observability
    models are excluded: the view's own output changes as the log grows.
#}

with ends as (

    select *
    from {{ source('observability', 'pipeline_step_log') }}
    where step = 'end'
      and status = 'success'
      and model_name <> '__run__'
      and schema_name <> '{{ var('audit_schema', 'observability') }}'

),

ranked as (

    select
        *,
        row_number() over (
            partition by model_name
            order by logged_at desc
        ) as _rn
    from ends

),

latest as (select * from ranked where _rn = 1),
previous as (select * from ranked where _rn = 2)

select
    latest.model_name,
    latest.schema_name,
    latest.materialization,
    previous.run_id                      as previous_run_id,
    latest.run_id                        as latest_run_id,
    previous.logged_at                   as previous_logged_at,
    latest.logged_at                     as latest_logged_at,
    previous.rows_read                   as previous_rows_read,
    latest.rows_read                     as latest_rows_read,
    previous.rows_written                as previous_rows_written,
    latest.rows_written                  as latest_rows_written,
    latest.rows_written - previous.rows_written as row_delta,
    previous.content_hash                as previous_content_hash,
    latest.content_hash                  as latest_content_hash,
    case
        when previous.content_hash is null then null
        when previous.content_hash = latest.content_hash then true
        else false
    end as content_unchanged,
    case
        when previous.rows_written is null then null
        when previous.rows_written = latest.rows_written then true
        else false
    end as row_count_unchanged,
    case
        when previous.content_hash is null then null
        when previous.content_hash = latest.content_hash
             and previous.rows_written = latest.rows_written then true
        else false
    end as is_idempotent
from latest
left join previous
    on latest.model_name = previous.model_name
