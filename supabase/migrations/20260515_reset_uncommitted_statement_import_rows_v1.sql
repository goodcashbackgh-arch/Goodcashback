-- Reset staged statement-import rows before commit.
-- Scope: pre-commit only. Keeps uploaded file, Mindee job/raw JSON, and batch header.
-- Does not touch committed DVA/card statement lines or active allocations.

CREATE OR REPLACE FUNCTION public.staff_reset_dva_statement_import_batch(
  p_import_batch_id uuid,
  p_reset_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff record;
  v_batch record;
  v_deleted_count integer := 0;
  v_external_duplicate_refs integer := 0;
BEGIN
  SELECT * INTO v_staff FROM public.current_active_staff_record_();

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for current auth user';
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can reset statement import rows. Current role: %', v_staff.role_type;
  END IF;

  SELECT * INTO v_batch
  FROM public.dva_statement_import_batches
  WHERE id = p_import_batch_id
  FOR UPDATE;

  IF v_batch.id IS NULL THEN
    RAISE EXCEPTION 'Statement import batch not found: %', p_import_batch_id;
  END IF;

  IF v_batch.status IN ('committed', 'voided', 'failed') THEN
    RAISE EXCEPTION 'Cannot reset batch % with status %. Void/reimport or use allocation reversal controls where applicable.', p_import_batch_id, v_batch.status;
  END IF;

  IF COALESCE(v_batch.committed_count, 0) > 0 OR v_batch.committed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot reset batch % because it already has committed statement lines.', p_import_batch_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dva_statement_import_rows r
    WHERE r.import_batch_id = p_import_batch_id
      AND (r.parse_status = 'committed' OR r.committed_dva_statement_line_id IS NOT NULL OR r.committed_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Cannot reset batch % because at least one staged row is already committed.', p_import_batch_id;
  END IF;

  SELECT COUNT(*)::integer INTO v_external_duplicate_refs
  FROM public.dva_statement_import_rows other_rows
  WHERE other_rows.import_batch_id <> p_import_batch_id
    AND other_rows.duplicate_of_import_row_id IN (
      SELECT r.id
      FROM public.dva_statement_import_rows r
      WHERE r.import_batch_id = p_import_batch_id
    );

  IF v_external_duplicate_refs > 0 THEN
    RAISE EXCEPTION 'Cannot reset batch % because staged rows are referenced by duplicate checks in another batch.', p_import_batch_id;
  END IF;

  DELETE FROM public.dva_statement_import_rows r
  WHERE r.import_batch_id = p_import_batch_id;

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  UPDATE public.dva_statement_import_batches b
     SET row_count = 0,
         clean_count = 0,
         error_count = 0,
         duplicate_count = 0,
         committed_count = 0,
         parsed_at = NULL,
         parse_errors_json = NULL,
         status = CASE
           WHEN b.status IN ('parsed_clean', 'parsed_with_errors', 'ocr_or_parsing', 'uploaded') THEN 'ocr_or_parsing'
           ELSE b.status
         END,
         notes = concat_ws(E'\n', b.notes, concat('Reset staged rows before commit: ', COALESCE(NULLIF(trim(p_reset_reason), ''), 'No reason supplied'), ' at ', now()::text))
   WHERE b.id = p_import_batch_id;

  RETURN jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'deleted_rows', v_deleted_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_reset_dva_statement_import_batch(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reset_dva_statement_import_batch(uuid, text) TO authenticated;
