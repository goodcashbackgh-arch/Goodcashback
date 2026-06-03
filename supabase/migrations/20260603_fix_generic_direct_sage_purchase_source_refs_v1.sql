-- Improve audit labels for existing active accepted direct Sage purchase postings.
-- This updates labels only for unlocked VAT returns; it does not change VAT amounts,
-- Sage coverage flags, adjustment flags, Sage ids/paths, or lineage evidence.

WITH direct_purchase_rows AS (
  SELECT
    l.id,
    concat_ws(
      ' — ',
      COALESCE(NULLIF(BTRIM(l.source_json ->> 'supplier_contact'), ''), 'Sage purchase document'),
      CASE
        WHEN COALESCE(l.source_json ->> 'document_date', '') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
          THEN substring(l.source_json ->> 'document_date' from 1 for 10)
        ELSE NULL
      END,
      CASE
        WHEN abs(COALESCE(NULLIF(regexp_replace(l.source_json ->> 'gross_amount', '[^0-9.\-]', '', 'g'), '')::numeric, 0)) > 0.005
          THEN '£' || to_char(abs(COALESCE(NULLIF(regexp_replace(l.source_json ->> 'gross_amount', '[^0-9.\-]', '', 'g'), '')::numeric, 0)), 'FM999999999990.00')
        ELSE NULL
      END
    ) AS fallback_label
  FROM public.vat_return_run_lines l
  JOIN public.vat_return_runs r ON r.id = l.vat_return_run_id
  WHERE r.locked_at IS NULL
    AND l.status = 'active'
    AND l.line_kind IN (
      'direct_sage_purchase_posting_not_via_platform_box4',
      'direct_sage_purchase_posting_not_via_platform_box7'
    )
    AND (
      COALESCE(BTRIM(l.source_ref), '') = ''
      OR lower(regexp_replace(BTRIM(COALESCE(l.source_ref, '')), '[_-]+', ' ', 'g')) IN ('document', 'invoice', 'purchase invoice', 'credit note', 'purchase credit note', 'bill', 'unknown')
      OR COALESCE(BTRIM(l.source_json ->> 'document_label'), '') = ''
      OR lower(regexp_replace(BTRIM(COALESCE(l.source_json ->> 'document_label', '')), '[_-]+', ' ', 'g')) IN ('document', 'invoice', 'purchase invoice', 'credit note', 'purchase credit note', 'bill', 'unknown')
    )
)
UPDATE public.vat_return_run_lines l
SET
  source_ref = d.fallback_label,
  source_json = jsonb_set(l.source_json, '{document_label}', to_jsonb(d.fallback_label), true)
FROM direct_purchase_rows d
WHERE l.id = d.id;
