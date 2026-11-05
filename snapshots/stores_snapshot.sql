{% snapshot stores_snapshot %}

    {{
        config(
            target_schema="snapshots",
            unique_key="store_id",
            strategy="check",
            check_cols=["store_name", "city", "region"],
        )
    }}

    select store_id, store_name, city, region, opened_date
    from {{ ref("slv_stores") }}

{% endsnapshot %}
