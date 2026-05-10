-- Shipping document intake v1
-- Governing source: docs/governing-pack/backend/Shipping_Control_Centre_Document_Intake_and_Export_Evidence_Flow_Addendum_v1.md

BEGIN;

CREATE TABLE IF NOT EXISTS public.shipping_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id),
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  importer_id uuid REFERENCES public.importers(id),
  uploaded_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  document_kind varchar NOT NULL CHECK (document_kind IN ('shipper_invoice','shipper_receipt','supporting_charge_document')),
  document_ref varchar,
  document_date date,
  currency_code varchar NOT NULL DEFAULT 'GBP',
  total_amount numeric(14,2),
  file_url text NOT NULL,
  ocr_status varchar NOT NULL DEFAULT 'not_started',
  review_status varchar NOT NULL DEFAULT 'uploaded_pending_ocr',
  notes text,
  version_no integer NOT NULL DEFAULT 1,
  active boolean NOT NULL DEFAULT true,
  replaced_by_document_id uuid,
  superseded_at timestamptz,
  accepted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shipping_documents_batch_active
  ON public.shipping_documents(shipment_batch_id, active, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_shipping_documents_active_batch_kind
  ON public.shipping_documents(shipment_batch_id, document_kind)
  WHERE active = true;

CREATE TABLE IF NOT EXISTS public.shipping_document_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipping_document_id uuid NOT NULL REFERENCES public.shipping_documents(id),
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id),
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  importer_id uuid REFERENCES public.importers(id),
  message_type varchar NOT NULL CHECK (message_type IN ('resubmission_request','shipper_note','supervisor_note')),
  message_body text NOT NULL,
  status varchar NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  created_by_shipper_user_id uuid REFERENCES public.shipper_users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.shipping_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipping_document_messages ENABLE ROW LEVEL SECURITY;

COMMIT;
