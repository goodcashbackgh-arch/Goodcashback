-- =============================================================================
-- refund_document_credit_note_ocr_v1.sql
-- Multi Tenant Platform Build — credit-note OCR save/match for refund document lane
--
-- Scope:
--   Adds the backend save function used after Mindee extracts a retailer credit note.
--   It does not post to Sage.
--   It does not alter supplier_invoices; credit notes remain in the refund-document lane.
--
-- Flow supported:
--   operator uploads credit note evidence
--   -> staff/Mindee OCR extracts header + lines
--   -> this RPC saves OCR header, compares operator ref/amount/retailer/date where available
--   -> creates dispute_refund_document_lines with line_source='ocr_extracted'
--   -> marks clean submissions as matched_ready_to_release
-- =============================================================================

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

alter table public.dispute_refund_evidence_submissions
  add column if not exists mindee_job_id varchar null,
  add column if not exists mindee_inference_id varchar null,
  add column if not exists mindee_model_id varchar null,
  add column if not exists mindee_last_http_status integer null,
  add column if not exists mindee_pages_consumed integer null,
  add column if not exists mindee_error_message text null,
  add column if not exists mindee_enqueued_at timestamptz null,
  add column if not exists mindee_result_saved_at timestamptz null;

create or replace function public.staff_save_refund_credit_note_ocr_result(
  p_refund_evidence_submission_id uuid,
  p_model_id varchar,
  p_http_status integer,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar,
  p_raw_json jsonb,
  p_ocr_credit_note_ref text,
  p_ocr_retailer_name text,
  p_ocr_credit_note_date date,
  p_ocr_credit_note_total_gbp numeric,
  p_pages_consumed integer,
  p_lines jsonb,
  p_flags jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff_id uuid;
  v_submission public.dispute_refund_evidence_submissions%rowtype;
  v_dispute record;
  v_order record;
  v_expected_retailer_name text;
  v_expected_amount numeric(12,2);
  v_ocr_total numeric(12,2);
  v_line_total numeric(12,2) := 0;
  v_variance numeric(12,2) := 0;
  v_ref_match boolean := true;
  v_amount_match boolean := true;
  v_retailer_match boolean := true;
  v_has_flags boolean := false;
  v_match_status text;
  v_amount_balance_status text;
  v_line jsonb;
  v_line_order integer := 0;
  v_inserted_count integer := 0;
  v_description text;
  v_qty numeric(12,2);
  v_amount numeric(12,2);
  v_sku text;
begin
  select s.id into v_staff_id
  from public.staff s
  where s.auth_user_id = auth.uid()
    and s.active = true
    and s.role_type in ('admin','supervisor')
  limit 1;

  if v_staff_id is null then
    raise exception 'Only active admin/supervisor staff can save credit-note OCR results.';
  end if;

  select * into v_submission
  from public.dispute_refund_evidence_submissions s
  where s.id = p_refund_evidence_submission_id
  for update;

  if v_submission.id is null then
    raise exception 'Refund evidence submission not found: %', p_refund_evidence_submission_id;
  end if;

  if v_submission.document_mode <> 'credit_note' then
    raise exception 'Credit-note OCR can only be saved for document_mode=credit_note. Current mode: %', v_submission.document_mode;
  end if;

  select d.id, d.order_id, d.amount_impact_gbp, d.desired_outcome, d.status
    into v_dispute
  from public.disputes d
  where d.id = v_submission.dispute_id;

  if v_dispute.id is null then
    raise exception 'Dispute not found for refund evidence submission %', p_refund_evidence_submission_id;
  end if;

  select o.id, o.order_ref, o.retailer_id, r.name as retailer_name
    into v_order
  from public.orders o
  left join public.retailers r on r.id = o.retailer_id
  where o.id = v_dispute.order_id;

  if v_order.id is null then
    raise exception 'Order not found for dispute %', v_dispute.id;
  end if;

  v_expected_retailer_name := nullif(btrim(coalesce(v_order.retailer_name, '')), '');
  v_expected_amount := coalesce(
    v_submission.expected_credit_note_total_gbp,
    v_submission.expected_exception_amount_abs_gbp,
    abs(v_dispute.amount_impact_gbp),
    0
  )::numeric(12,2);
  v_ocr_total := coalesce(p_ocr_credit_note_total_gbp, 0)::numeric(12,2);
  v_variance := round(abs(v_expected_amount - v_ocr_total)::numeric, 2);

  if nullif(btrim(coalesce(v_submission.credit_note_ref, '')), '') is not null
     and nullif(btrim(coalesce(p_ocr_credit_note_ref, '')), '') is not null then
    v_ref_match := lower(regexp_replace(v_submission.credit_note_ref, '[^a-zA-Z0-9]+', '', 'g')) = lower(regexp_replace(p_ocr_credit_note_ref, '[^a-zA-Z0-9]+', '', 'g'));
  end if;

  if v_expected_amount > 0 and v_ocr_total > 0 then
    v_amount_match := v_variance <= 0.01;
  elsif v_expected_amount > 0 then
    v_amount_match := false;
  end if;

  if v_expected_retailer_name is not null and nullif(btrim(coalesce(p_ocr_retailer_name, '')), '') is not null then
    v_retailer_match :=
      lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) = lower(regexp_replace(p_ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g'))
      or lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) like '%' || lower(regexp_replace(p_ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) || '%'
      or lower(regexp_replace(p_ocr_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) like '%' || lower(regexp_replace(v_expected_retailer_name, '[^a-zA-Z0-9]+', '', 'g')) || '%';
  end if;

  v_has_flags := jsonb_typeof(coalesce(p_flags, '[]'::jsonb)) = 'array' and jsonb_array_length(coalesce(p_flags, '[]'::jsonb)) > 0;
  v_amount_balance_status := case when v_amount_match then 'balanced' else 'variance' end;
  v_match_status := case when v_ref_match and v_amount_match and v_retailer_match and not v_has_flags then 'matched_ready_to_release' else 'needs_supervisor_review' end;

  delete from public.dispute_refund_document_lines l
  where l.refund_evidence_submission_id = p_refund_evidence_submission_id
    and l.line_source = 'ocr_extracted'
    and l.progressed_to_supplier_control_yn = false;

  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    v_line_order := v_line_order + 1;
    v_description := nullif(btrim(coalesce(v_line->>'description', v_line->>'name', v_line->>'label', '')), '');
    v_qty := coalesce(nullif(v_line->>'qty', '')::numeric, nullif(v_line->>'quantity', '')::numeric, 1)::numeric(12,2);
    v_amount := coalesce(
      nullif(v_line->>'amount_gbp', '')::numeric,
      nullif(v_line->>'amount_inc_vat_gbp', '')::numeric,
      nullif(v_line->>'total_amount', '')::numeric,
      nullif(v_line->>'total_price', '')::numeric,
      nullif(v_line->>'line_total', '')::numeric,
      0
    )::numeric(12,2);
    v_sku := nullif(btrim(coalesce(v_line->>'retailer_sku', v_line->>'sku', v_line->>'product_code', '')), '');

    if v_description is not null and v_amount >= 0 then
      insert into public.dispute_refund_document_lines (
        refund_evidence_submission_id,
        line_order,
        line_source,
        description,
        qty,
        amount_gbp
      ) values (
        p_refund_evidence_submission_id,
        v_line_order,
        'ocr_extracted',
        case when v_sku is not null then v_description || ' [' || v_sku || ']' else v_description end,
        v_qty,
        v_amount
      );
      v_inserted_count := v_inserted_count + 1;
      v_line_total := round((v_line_total + v_amount)::numeric, 2);
    end if;
  end loop;

  if v_inserted_count = 0 then
    v_match_status := 'needs_supervisor_review';
  end if;

  update public.dispute_refund_evidence_submissions s
  set
    ocr_status = 'completed',
    ocr_credit_note_ref = nullif(btrim(coalesce(p_ocr_credit_note_ref, '')), ''),
    ocr_retailer_name = nullif(btrim(coalesce(p_ocr_retailer_name, '')), ''),
    ocr_credit_note_date = p_ocr_credit_note_date,
    ocr_credit_note_total_gbp = nullif(v_ocr_total, 0),
    ocr_raw_json = p_raw_json,
    ocr_extracted_at = now(),
    mindee_job_id = nullif(btrim(coalesce(p_mindee_job_id, '')), ''),
    mindee_inference_id = nullif(btrim(coalesce(p_mindee_inference_id, '')), ''),
    mindee_model_id = nullif(btrim(coalesce(p_model_id, '')), ''),
    mindee_last_http_status = p_http_status,
    mindee_pages_consumed = p_pages_consumed,
    mindee_error_message = null,
    mindee_result_saved_at = now(),
    captured_refund_amount_abs_gbp = case when v_ocr_total > 0 then v_ocr_total else s.captured_refund_amount_abs_gbp end,
    variance_abs_gbp = v_variance,
    amount_balance_status = v_amount_balance_status,
    match_status = v_match_status,
    evidence_control_status = case when v_match_status = 'matched_ready_to_release' then 'credit_note_ocr_matched_ready' else 'credit_note_ocr_review_required' end,
    supplier_readiness_route = case when v_match_status = 'matched_ready_to_release' then 'supplier_credit_note_ready_to_release' else 'supplier_credit_note_review_required' end,
    supplier_control_status = case when v_match_status = 'matched_ready_to_release' then 'not_released' else 'blocked' end,
    supplier_approval_status = case when v_match_status = 'matched_ready_to_release' then 'pending' else 'blocked' end
  where s.id = p_refund_evidence_submission_id;

  return jsonb_build_object(
    'ok', true,
    'refund_evidence_submission_id', p_refund_evidence_submission_id,
    'document_mode', 'credit_note',
    'ocr_status', 'completed',
    'match_status', v_match_status,
    'amount_balance_status', v_amount_balance_status,
    'expected_amount_gbp', v_expected_amount,
    'ocr_total_gbp', v_ocr_total,
    'variance_abs_gbp', v_variance,
    'line_count', v_inserted_count,
    'line_total_gbp', v_line_total,
    'ref_match', v_ref_match,
    'retailer_match', v_retailer_match,
    'has_flags', v_has_flags
  );
end;
$$;

comment on function public.staff_save_refund_credit_note_ocr_result(uuid, varchar, integer, varchar, varchar, jsonb, text, text, date, numeric, integer, jsonb, jsonb) is
'Saves Mindee/OCR result for refund-document credit notes, compares submitted/OCR details, creates OCR refund-document lines, and routes clean rows to supplier credit control. Does not post to Sage.';

grant execute on function public.staff_save_refund_credit_note_ocr_result(uuid, varchar, integer, varchar, varchar, jsonb, text, text, date, numeric, integer, jsonb, jsonb) to authenticated;

commit;
