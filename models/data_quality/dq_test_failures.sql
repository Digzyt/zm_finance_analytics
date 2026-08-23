{{
  config(
    materialized = 'table',
    tags = ['data_quality', 'dq']
  )
}}

-- =============================================================================
-- dq_test_failures — the drill-through detail behind the Data Quality page.
-- Every evaluated unit that FAILED its automated control, with the control's
-- title, block and severity attached. Power BI uses this as the target of a
-- drill-through from a row of dq_test_results: filter on test_id (+ period) to
-- see exactly which records failed and why (e.g. C-20 lists the unmapped
-- accounts; C-05 lists the entity-periods that do not foot).
-- =============================================================================

select
    e.test_id,
    c.block,
    c.title,
    c.severity,
    e.period,
    e.entity,
    e.unit_type,
    e.unit_key,
    e.description,
    e.metric_value,
    e.threshold,
    e.fail_reason,
    c.exception_codes
from {{ ref('dq_test_evaluations') }} e
left join {{ ref('dq_test_catalog') }} c on c.test_id = e.test_id
where e.passed = false
