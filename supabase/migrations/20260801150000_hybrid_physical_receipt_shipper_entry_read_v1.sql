BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE FUNCTION public.shipper_physical_receipt_entry_v1(p_tracking_submission_id uuid)
RETURNS TABLE (
  tracking_line_allocation_id uuid,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  latest_receipt_id uuid,
  latest_receipt_model_version smallint