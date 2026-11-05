{#
    Incremental / late-arriving helpers.

    Late-arriving window: on every incremental run we re-read the last N days of
    source data relative to the watermark already stored in the target table,
    instead of only brand-new rows. This catches backfills, retries and CDC
    re-sends while keeping the scan small.

    Databricks does not allow an aggregate scalar subquery directly in a WHERE
    clause, so the watermark is exposed as a CTE that models join to:

        with {{ late_arriving_window('last_modified_at') }},
        ...
        from parsed cross join late_arriving_window
        where last_modified_at >= window_start
#}
{% macro late_arriving_window(
    watermark_column, lookback_days=none, cte_name="late_arriving_window"
) -%}
    {%- set lookback = (
        lookback_days
        if lookback_days is not none
        else var("late_arriving_lookback_days", 3)
    ) -%}
    {{ cte_name }} as (
        {%- if is_incremental() %}
            select
                coalesce(max({{ watermark_column }}), timestamp '1900-01-01 00:00:00')
                - interval {{ lookback }} days as window_start
            from {{ this }}
        {%- else %}select timestamp '1900-01-01 00:00:00' as window_start
        {%- endif %}
    )
{%- endmacro %}


{#
    Dedupe + reconcile helper.

    On an incremental run a re-read late row must not overwrite a newer row that
    is already in the target. This unions the incoming window with matching
    target rows and keeps the latest version per key.

    Args:
        incoming_cte   - CTE holding the transformed source rows
        target_columns - explicit column list (must match incoming_cte)
        unique_key     - key used to find matching target rows
        order_by       - expression deciding which version wins
        alias          - output CTE name
#}
{% macro reconcile_with_target(
    incoming_cte, target_columns, unique_key, order_by, alias="deduped"
) -%}
    {%- if is_incremental() -%}
        ,
        target_rows as (
            select {{ target_columns }}
            from {{ this }}
            where {{ unique_key }} in (select {{ unique_key }} from {{ incoming_cte }})
        ),
        combined as (
            select {{ target_columns }}
            from {{ incoming_cte }}
            union all
            select {{ target_columns }}
            from target_rows
        )
    {%- else -%}, combined as (select {{ target_columns }} from {{ incoming_cte }})
    {%- endif -%},
    {{ alias }} as (
        select {{ target_columns }}
        from
            (
                select
                    {{ target_columns }},
                    row_number() over (
                        partition by {{ unique_key }} order by {{ order_by }}
                    ) as _rn
                from combined
            ) _
        where _rn = 1
    )
{%- endmacro %}
