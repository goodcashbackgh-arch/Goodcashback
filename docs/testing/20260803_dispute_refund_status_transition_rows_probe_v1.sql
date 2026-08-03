-- Read-only probe for exact active refund dispute status transitions.

SELECT jsonb_build_object(
  'probe','dispute_refund_status_transition_rows_v1',
  'result',CASE WHEN EXISTS(
    SELECT 1 FROM public.status_transitions
    WHERE entity_type='dispute' AND active=true
  ) THEN 'READY' ELSE 'BLOCKED' END,
  'active_transitions',(
    SELECT jsonb_agg(jsonb_build_object(
      'from_status',from_status,
      'to_status',to_status,
      'active',active
    ) ORDER BY from_status,to_status)
    FROM public.status_transitions
    WHERE entity_type='dispute'
      AND active=true
      AND (
        from_status IN ('raised','under_review','approved_refund','awaiting_refund_credit','refunded','closed')
        OR to_status IN ('raised','under_review','approved_refund','awaiting_refund_credit','refunded','closed')
      )
  ),
  'candidate_paths',jsonb_build_object(
    'raised_to_approved_refund',EXISTS(
      SELECT 1 FROM public.status_transitions
      WHERE entity_type='dispute' AND from_status='raised' AND to_status='approved_refund' AND active=true
    ),
    'approved_refund_to_awaiting_refund_credit',EXISTS(
      SELECT 1 FROM public.status_transitions
      WHERE entity_type='dispute' AND from_status='approved_refund' AND to_status='awaiting_refund_credit' AND active=true
    ),
    'awaiting_refund_credit_to_refunded',EXISTS(
      SELECT 1 FROM public.status_transitions
      WHERE entity_type='dispute' AND from_status='awaiting_refund_credit' AND to_status='refunded' AND active=true
    ),
    'refunded_to_closed',EXISTS(
      SELECT 1 FROM public.status_transitions
      WHERE entity_type='dispute' AND from_status='refunded' AND to_status='closed' AND active=true
    )
  )
) AS result;
