BEGIN;

DO $$
DECLARE
  v_constraint_name text;
BEGIN
  SELECT c.conname INTO v_constraint_name
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND t.relname = 'shipper_final_export_evidence_documents'
    AND c.contype = 'c'
    AND pg_get_constraintdef(c.oid) ILIKE '%document_kind%'
  ORDER BY c.conname
  LIMIT 1;

  IF v_constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.shipper_final_export_evidence_documents DROP CONSTRAINT %I', v_constraint_name);
  END IF;
END $$;

ALTER TABLE public.shipper_final_export_evidence_documents
  ADD CONSTRAINT shipper_final_export_evidence_documents_document_kind_check
  CHECK (document_kind IN (
    'completed_cos',
    'final_eep_packing_list',
    'mbl_bol_sea_waybill',
    'container_seal_evidence',
    'export_date_departure_evidence',
    'pod_delivery_evidence',
    'other_final_export_evidence'
  ));

NOTIFY pgrst, 'reload schema';

COMMIT;
