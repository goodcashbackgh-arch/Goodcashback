-- READ-ONLY probe for active order status transitions relevant to fixture creation.
-- No DML. Safe to run repeatedly.

SELECT jsonb_build_object(
  'probe','order_status_transition_rows_probe_v1',
  'result','READY',
  'active_order_transitions',COALESCE((
    SELECT jsonb_agg(to_jsonb(st) ORDER BY st.from_status,st.to_status)
    FROM public.status_transitions st
    WHERE st.entity_type='order'
      AND st.active=true
  ),'[]'::jsonb),
  'into_reconciling',COALESCE((
    SELECT jsonb_agg(to_jsonb(st) ORDER BY st.from_status)
    FROM public.status_transitions st
    WHERE st.entity_type='order'
      AND st.active=true
      AND st.to_status='reconciling'
  ),'[]'::jsonb),
  'from_candidate_start_states',COALESCE((
    SELECT jsonb_agg(to_jsonb(st) ORDER BY st.from_status,st.to_status)
    FROM public.status_transitions st
    WHERE st.entity_type='order'
      AND st.active=true
      AND st.from_status IN ('draft','pending_dva_funding','evidence_collecting','reconciling','partially_progressed')
  ),'[]'::jsonb)
) AS result;
