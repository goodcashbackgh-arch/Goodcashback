BEGIN;

-- Surgical display integration only.
-- The VAT return page uses the latest Sage snapshot for both comparator boxes and the
-- Box 4/Box 7 purchase review. Imported Sage draft snapshots must remain latest for
-- comparator purposes, while diagnostic Sage reconstruction snapshots hold the
-- purchase_vat_line_review. This copies that diagnostic review onto the imported
-- draft snapshot so the existing UI can display it without changing statutory rules.
-- Does not touch vat_return_run_lines, blockers, evidence breach logic, prepayment
-- timing, no-invoice logic, journal validation, approval, or Sage posting.

CREATE OR REPLACE FUNCTION public.carry_purchase_vat_review_into_imported_sage_draft_snapshot_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_review jsonb;
  v_imported_id uuid;
BEGIN
  v_review := NEW.source_summary #> '{purchase_vat_line_review}';

  IF v_review IS NULL OR jsonb_typeof(v_review) <> 'object' THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.source_basis, '') LIKE 'sage_draft_vat_return_totals_import%' THEN
    RETURN NEW;
  END IF;

  SELECT r.id
  INTO v_imported_id
  FROM public.vat_return_sage_reconstruction_snapshots r
  WHERE r.vat_return_run_id = NEW.vat_return_run_id
    AND COALESCE(r.source_basis, '') LIKE 'sage_draft_vat_return_totals_import%'
  ORDER BY r.created_at DESC
  LIMIT 1;

  IF v_imported_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.vat_return_sage_reconstruction_snapshots r
  SET source_summary = COALESCE(r.source_summary, '{}'::jsonb)
        || jsonb_build_object('purchase_vat_line_review', v_review),
      warning_notes = CASE
        WHEN COALESCE(r.warning_notes, ARRAY[]::text[]) @> ARRAY['purchase_vat_line_review copied from latest diagnostic Sage reconstruction for UI display']::text[]
          THEN r.warning_notes
        ELSE COALESCE(r.warning_notes, ARRAY[]::text[]) || ARRAY['purchase_vat_line_review copied from latest diagnostic Sage reconstruction for UI display']::text[]
      END
  WHERE r.id = v_imported_id;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_carry_purchase_vat_review_into_imported_sage_draft_snapshot_v1
ON public.vat_return_sage_reconstruction_snapshots;

CREATE TRIGGER trg_carry_purchase_vat_review_into_imported_sage_draft_snapshot_v1
AFTER INSERT OR UPDATE OF source_summary
ON public.vat_return_sage_reconstruction_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.carry_purchase_vat_review_into_imported_sage_draft_snapshot_v1();

-- One-off repair for returns where diagnostic reconstruction was already run after
-- the imported draft was saved.
WITH latest_diagnostic AS (
  SELECT DISTINCT ON (vat_return_run_id)
    vat_return_run_id,
    source_summary #> '{purchase_vat_line_review}' AS review
  FROM public.vat_return_sage_reconstruction_snapshots
  WHERE COALESCE(source_basis, '') NOT LIKE 'sage_draft_vat_return_totals_import%'
    AND source_summary #> '{purchase_vat_line_review}' IS NOT NULL
  ORDER BY vat_return_run_id, created_at DESC
),
latest_imported AS (
  SELECT DISTINCT ON (vat_return_run_id)
    id,
    vat_return_run_id
  FROM public.vat_return_sage_reconstruction_snapshots
  WHERE COALESCE(source_basis, '') LIKE 'sage_draft_vat_return_totals_import%'
  ORDER BY vat_return_run_id, created_at DESC
)
UPDATE public.vat_return_sage_reconstruction_snapshots imported
SET source_summary = COALESCE(imported.source_summary, '{}'::jsonb)
      || jsonb_build_object('purchase_vat_line_review', latest_diagnostic.review),
    warning_notes = CASE
      WHEN COALESCE(imported.warning_notes, ARRAY[]::text[]) @> ARRAY['purchase_vat_line_review copied from latest diagnostic Sage reconstruction for UI display']::text[]
        THEN imported.warning_notes
      ELSE COALESCE(imported.warning_notes, ARRAY[]::text[]) || ARRAY['purchase_vat_line_review copied from latest diagnostic Sage reconstruction for UI display']::text[]
    END
FROM latest_imported
JOIN latest_diagnostic USING (vat_return_run_id)
WHERE imported.id = latest_imported.id
  AND latest_diagnostic.review IS NOT NULL;

REVOKE ALL ON FUNCTION public.carry_purchase_vat_review_into_imported_sage_draft_snapshot_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.carry_purchase_vat_review_into_imported_sage_draft_snapshot_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
