{{ config(materialized='view', tags=['observability']) }}

{#
    Human-readable step timeline.

    Inline steps are written while the model SQL is compiled, so their
    `logged_at` can precede the model's `start` row. This view imposes the
    logical order:

        phase 1  start
        phase 2  inline steps
        phase 3  end

    Every row is also joined to the model's successful `end` row for the same
    invocation, so each step shows the model's rows_read / rows_written.
#}

with events as (

    select *
    from {{ source('observability', 'pipeline_step_log') }}
    where model_name <> '__run__'

),

model_metrics as (

    select
        run_id,
        model_name,
        rows_read,
        rows_written,
        content_hash
    from {{ source('observability', 'pipeline_step_log') }}
    where step = 'end'
      and status = 'success'

),

timeline as (

    select
        e.run_id,
        e.model_name,
        e.schema_name,
        e.materialization,
        e.step,
        e.status,
        e.logged_at,
        case e.step
            when 'start' then 1
            when 'end' then 3
            else 2
        end as phase,
        coalesce(e.rows_read, m.rows_read)         as rows_read,
        coalesce(e.rows_written, m.rows_written)   as rows_written,
        coalesce(e.content_hash, m.content_hash)   as content_hash,
        e.detail
    from events e
    left join model_metrics m
        on e.run_id = m.run_id
       and e.model_name = m.model_name

)

select *
from timeline
order by run_id, model_name, phase, logged_at
