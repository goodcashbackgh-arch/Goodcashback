-- Exact fixture diagnostic for the shipper original-contents preview.
-- Read-only. It resolves the grouped fixture's tracking submission from the
-- existing shipper dashboard RPC, then invokes the exact preview RPC used by UI.
--
-- If the preview RPC fails, Supabase will show the real database error.

WITH target AS (
  SELECT
    d.tracking_submission_id,
    d.order_id,
    d.order_ref,
    d.tracking_ref
  FROM public.shipper_package_receipt_dashboard_v1() d
  WHERE d.order_id = '1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
    AND d.tracking_submission_id IS NOT NULL
  ORDER BY d.submitted_at DESC NULLS LAST
  LIMIT 1
), preview AS (
  SELECT p.*
  FROM target t
  CROSS JOIN LATERAL public.shipper_package_original_contents_preview_v1(
    t.tracking_submission_id
  ) p
)
SELECT jsonb_build_object(
  'probe', 'shipper_original_contents_fixture_call_v1',
  'target', (SELECT to_jsonb(target) FROM target),
  'preview_row_count', (SELECT count(*) FROM preview),
  'preview_rows', COALESCE((SELECT jsonb_agg(to_jsonb(preview)) FROM preview), '[]'::jsonb)
) AS result;