-- Stale statement Mindee job recovery regression v1
-- Read-only structural regression. No auth.uid(), no RPC execution, no writes.

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'staff_recover_dva_statement_import_missing_mindee_job_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_import_batch_id uuid, p_expected_mindee_job_id character varying, p_http_status integer, p_error_message text';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'FAIL: stale statement Mindee recovery function is missing or signature changed';
  END IF;

  IF position('p_http_status <> 404' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: recovery is not hard-gated to HTTP 404';
  END IF;

  IF position('position(''job'' in lower(v_error_message)) = 0' in v_def) = 0
     OR position('position(''not found'' in lower(v_error_message)) = 0' in v_def) = 0
     OR position('position(lower(v_expected_job_id) in lower(v_error_message)) = 0' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: recovery does not require definitive expected-job not-found detail';
  END IF;

  IF position('v_batch.mindee_statement_job_id is distinct from v_expected_job_id' in v_def) = 0
     OR position('and mindee_statement_job_id = v_expected_job_id' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: expected-job concurrency guard is missing';
  END IF;

  IF position('v_batch.status in (''committed'', ''voided'')' in v_def) = 0
     OR position('coalesce(v_batch.committed_count, 0) <> 0' in v_def) = 0
     OR position('v_batch.committed_at is not null' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: committed/voided guards are missing';
  END IF;

  IF position('from public.dva_statement_import_rows r' in v_def) = 0
     OR position('where r.import_batch_id = p_import_batch_id' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: staged-row guard is missing';
  END IF;

  IF position('status = ''uploaded''' in v_def) = 0
     OR position('mindee_statement_ocr_status = ''not_started''' in v_def) = 0
     OR position('mindee_statement_job_id = null' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: recovery does not restore the proven pre-OCR state';
  END IF;

  IF position('delete from' in lower(v_def)) > 0 THEN
    RAISE EXCEPTION 'FAIL: recovery must not delete batch, PDF, rows, or downstream evidence';
  END IF;

  IF position('dva_statement_lines' in v_def) > 0
     OR position('dva_statement_line_import_links' in v_def) > 0
     OR position('dva_statement_line_allocations' in v_def) > 0
     OR position('sage_' in lower(v_def)) > 0 THEN
    RAISE EXCEPTION 'FAIL: recovery reaches downstream statement/allocation/Sage objects';
  END IF;
END
$$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'recovery is limited to definitive HTTP 404 expected-job-not-found, is concurrency guarded, rejects committed/voided or staged batches, restores only the existing uploaded/not_started OCR state, performs no deletes, and does not reach statement lines, import links, allocations or Sage'
) AS regression_result;
