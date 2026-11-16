{{ config(severity='error') }}

{#
    Quarantine circuit breaker (Tier-1 alerting gap).

    The pipeline's job is to tag bad rows, not to stop on every one of them -
    the practice dataset is intentionally dirty, so individual quarantine rows
    are expected. What IS an incident is the quarantine growing without bound,
    which means the upstream source has changed shape or a rule is broken.

    This test fails the build when the quarantine table exceeds
    `quarantine_alert_threshold` (dbt_project.yml, default 2000 rows).
    Tune the threshold down after the first production run establishes the
    real baseline (the current practice dataset quarantines ~165 rows).
#}

select
    'quarantine_threshold_exceeded' as check_name,
    count(*)                        as quarantine_rows,
    {{ var('quarantine_alert_threshold', 2000) }} as threshold
from {{ ref('quarantine_records') }}
having count(*) > {{ var('quarantine_alert_threshold', 2000) }}
