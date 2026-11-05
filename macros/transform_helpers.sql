{#
    Reusable transformation helpers for the sales_analytics project.
    All macros are dialect-aware for Databricks SQL and safe on NULL inputs.
#}

{#- Strip currency symbols / thousands separators and cast to decimal. -#}
{% macro clean_amount(column, precision=18, scale=2) -%}
    cast(
        nullif(regexp_replace({{ column }}, '[^0-9.-]', ''), '')
        as decimal({{ precision }}, {{ scale }})
    )
{%- endmacro %}


{#- Try a list of date formats in order. Returns NULL if none match. -#}
{% macro parse_date(column, formats=none) -%}
    {%- set fmts = formats if formats is not none else [
        'yyyy-MM-dd', 'dd-MM-yyyy', 'dd/MM/yyyy', 'MMM dd, yyyy', 'yyyy/MM/dd'
    ] -%}
    coalesce(
        {%- for fmt in fmts %}
        try_to_date(trim({{ column }}), '{{ fmt }}'){% if not loop.last %},{% endif %}
        {%- endfor %}
    )
{%- endmacro %}


{#- Same idea for timestamps; falls back to date-only parsing. -#}
{% macro parse_timestamp(column, formats=none) -%}
    {%- set fmts = formats if formats is not none else [
        'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd', 'dd-MM-yyyy', 'dd/MM/yyyy',
        'MMM dd, yyyy', 'yyyy/MM/dd'
    ] -%}
    coalesce(
        {%- for fmt in fmts %}
        try_to_timestamp(trim({{ column }}), '{{ fmt }}'){% if not loop.last %},{% endif %}
        {%- endfor %}
    )
{%- endmacro %}


{#- Trim + optional case folding: 'upper' (default), 'lower', 'none'. -#}
{% macro normalize_text(column, case='upper') -%}
    {%- if case == 'upper' -%}
        upper(trim({{ column }}))
    {%- elif case == 'lower' -%}
        lower(trim({{ column }}))
    {%- else -%}
        trim({{ column }})
    {%- endif -%}
{%- endmacro %}


{#- Map free-text variants onto a canonical set via a CASE expression. -#}
{% macro map_values(column, mapping, default='UNKNOWN') -%}
    case lower(trim({{ column }}))
        {%- for key, value in mapping.items() %}
        when '{{ key }}' then '{{ value }}'
        {%- endfor %}
        else '{{ default }}'
    end
{%- endmacro %}


{#- Normalize the many boolean encodings (Y/N/true/false/1/0). -#}
{% macro to_boolean(column) -%}
    case
        when lower(trim({{ column }})) in ('1', 'true', 'y', 'yes', 't') then true
        when lower(trim({{ column }})) in ('0', 'false', 'n', 'no', 'f') then false
        else null
    end
{%- endmacro %}


{#- Deterministic surrogate key (md5) over one or more columns. -#}
{% macro surrogate_key(columns) -%}
    md5(concat_ws('||',
        {%- for col in columns %}
        coalesce(cast({{ col }} as string), '~NULL~'){% if not loop.last %}, {% endif %}
        {%- endfor %}
    ))
{%- endmacro %}


{#- Row hash for change detection; ignores volatile audit columns. -#}
{% macro record_hash(columns) -%}
    md5(concat_ws('||',
        {%- for col in columns %}
        coalesce(cast({{ col }} as string), '~NULL~'){% if not loop.last %}, {% endif %}
        {%- endfor %}
    ))
{%- endmacro %}


{#- Standard audit columns for any incremental model. -#}
{% macro audit_columns(source_column=none) -%}
    current_timestamp() as _loaded_at
    {%- if source_column is not none %},
    {{ source_column }} as _source_file
    {%- endif %}
{%- endmacro %}
