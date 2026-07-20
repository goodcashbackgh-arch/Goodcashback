BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $$
BEGIN
  IF to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shipper_shipment_batch_packages') IS NULL
     OR to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.customer_pre_shipment_hold_requests') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.staff') IS NULL
  THEN
    RAISE EXCEPTION 'Mini-build 3 prerequisite relation missing';
  END IF;
  IF to_regprocedure('public.is_active_staff()') IS NULL THEN
    RAISE EXCEPTION 'Mini-build 3 prerequisite function missing: is_active_staff()';
  END IF;
END $$;

CREATE TABLE public.customer_sales_release_legacy_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_invoice_id uuid NOT NULL REFERENCES public.sales_invoices(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  issue_code text NOT NULL,
  issue_detail text NOT NULL,
  source_payload jsonb,
  detected_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolved_by_staff_id uuid REFERENCES public.staff(id),
  resolution_note text,
  CONSTRAINT csrli_resolution_chk CHECK (
    (resolved_at IS NULL AND resolved_by_staff_id IS NULL)
    OR (resolved_at IS NOT NULL AND resolved_by_staff_id IS NOT NULL
        AND NULLIF(BTRIM(COALESCE(resolution_note,'')),'') IS NOT NULL)
  )
);

CREATE UNIQUE INDEX uq_csrli_open
  ON public.customer_sales_release_legacy_issues(sales_invoice_id,issue_code)
  WHERE resolved_at IS NULL;

CREATE TABLE public.customer_sales_release_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_invoice_id uuid NOT NULL REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  sales_invoice_type text NOT NULL CHECK (sales_invoice_type IN ('main','supplementary','credit_note')),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  commercial_parent_order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  source_shipment_batch_id uuid REFERENCES public.shipper_shipment_batches(id) ON DELETE RESTRICT,
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  tracking_submission_id uuid NOT NULL REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  tracking_line_allocation_id uuid NOT NULL REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  released_qty numeric(12,3) NOT NULL CHECK (released_qty >= 0),
  goods_amount_gbp numeric(14,2) NOT NULL DEFAULT 0 CHECK (goods_amount_gbp >= 0),
  delivery_share_gbp numeric(14,2) NOT NULL DEFAULT 0 CHECK (delivery_share_gbp >= 0),
  discount_share_gbp numeric(14,2) NOT NULL DEFAULT 0 CHECK (discount_share_gbp >= 0),
  shipping_amount_gbp numeric(14,2) NOT NULL DEFAULT 0 CHECK (shipping_amount_gbp >= 0),
  customer_charge_amount_gbp numeric(14,2) NOT NULL CHECK (customer_charge_amount_gbp > 0),
  release_status text NOT NULL DEFAULT 'active' CHECK (release_status IN ('active','reversed')),
  membership_fingerprint text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by_staff_id uuid REFERENCES public.staff(id),
  reversed_at timestamptz,
  reversed_by_staff_id uuid REFERENCES public.staff(id),
  reversal_reason text,
  CONSTRAINT csrl_total_chk CHECK (
    ABS(customer_charge_amount_gbp-(goods_amount_gbp+shipping_amount_gbp)) <= 0.02
  ),
  CONSTRAINT csrl_component_chk CHECK (
    released_qty > 0 OR goods_amount_gbp > 0 OR shipping_amount_gbp > 0
  ),
  CONSTRAINT csrl_reversal_chk CHECK (
    (release_status='active' AND reversed_at IS NULL AND reversed_by_staff_id IS NULL AND reversal_reason IS NULL)
    OR
    (release_status='reversed' AND reversed_at IS NOT NULL AND reversed_by_staff_id IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(reversal_reason,'')),'') IS NOT NULL)
  )
);

CREATE UNIQUE INDEX uq_csrl_invoice_membership
  ON public.customer_sales_release_lines(sales_invoice_id,membership_fingerprint);
CREATE INDEX idx_csrl_allocation_active
  ON public.customer_sales_release_lines(tracking_line_allocation_id)
  WHERE release_status='active';
CREATE INDEX idx_csrl_parent_active
  ON public.customer_sales_release_lines(commercial_parent_order_id,created_at)
  WHERE release_status='active';
CREATE INDEX idx_csrl_batch_active
  ON public.customer_sales_release_lines(source_shipment_batch_id)
  WHERE release_status='active';

COMMENT ON TABLE public.customer_sales_release_lines IS
'Durable exact source membership for customer sales releases. This table, not reconstructed JSON, is authoritative for already-released quantity/value.';

ALTER TABLE public.customer_sales_release_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_sales_release_legacy_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY csrl_staff_select ON public.customer_sales_release_lines
  FOR SELECT TO authenticated USING (public.is_active_staff());
CREATE POLICY csrli_staff_select ON public.customer_sales_release_legacy_issues
  FOR SELECT TO authenticated USING (public.is_active_staff());

REVOKE ALL ON public.customer_sales_release_lines FROM PUBLIC;
REVOKE ALL ON public.customer_sales_release_legacy_issues FROM PUBLIC;
GRANT SELECT ON public.customer_sales_release_lines TO authenticated;
GRANT SELECT ON public.customer_sales_release_legacy_issues TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public.customer_sales_release_lines TO service_role;
GRANT SELECT,INSERT,UPDATE ON public.customer_sales_release_legacy_issues TO service_role;

CREATE OR REPLACE FUNCTION public.customer_sales_payload_lines_v1(p_payload jsonb)
RETURNS SETOF jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT value
  FROM jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(p_payload)='array' THEN p_payload
      WHEN jsonb_typeof(p_payload->'lines')='array' THEN p_payload->'lines'
      ELSE '[]'::jsonb
    END
  );
$$;

CREATE OR REPLACE FUNCTION public.customer_sales_release_guard_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
  v_src record;
  v_sales record;
  v_parent uuid;
  v_qty numeric;
  v_goods numeric;
  v_ship numeric;
  v_receipt text;
BEGIN
  SELECT si.id,si.order_id,si.invoice_type::text invoice_type,si.sage_status::text sage_status,
         si.sage_invoice_id,si.sage_posted_at,si.amount_gbp
  INTO v_sales
  FROM public.sales_invoices si WHERE si.id=NEW.sales_invoice_id FOR UPDATE;
  IF v_sales.id IS NULL THEN RAISE EXCEPTION 'Sales invoice not found'; END IF;

  IF TG_OP='UPDATE' THEN
    IF (to_jsonb(NEW)-ARRAY['release_status','reversed_at','reversed_by_staff_id','reversal_reason'])
       IS DISTINCT FROM
       (to_jsonb(OLD)-ARRAY['release_status','reversed_at','reversed_by_staff_id','reversal_reason'])
    THEN
      RAISE EXCEPTION 'Release provenance is immutable; only audited reversal fields may change';
    END IF;
    IF OLD.release_status='reversed' THEN
      RAISE EXCEPTION 'Reversed release membership is immutable';
    END IF;
    IF NEW.release_status='reversed' THEN
      IF v_sales.sage_status<>'void' OR v_sales.sage_invoice_id IS NOT NULL OR v_sales.sage_posted_at IS NOT NULL THEN
        RAISE EXCEPTION 'Release membership may only be reversed after an unposted invoice is void';
      END IF;
      IF EXISTS (
        SELECT 1 FROM public.sage_posting_snapshots s
        WHERE s.source_table='sales_invoices' AND s.source_id=NEW.sales_invoice_id
          AND COALESCE(s.active,true)=true
          AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'
      ) THEN
        RAISE EXCEPTION 'Release membership cannot be reversed while an active Sage snapshot exists';
      END IF;
      RETURN NEW;
    END IF;
  END IF;

  IF v_sales.invoice_type IS DISTINCT FROM NEW.sales_invoice_type THEN
    RAISE EXCEPTION 'Release invoice type mismatch';
  END IF;
  IF v_sales.sage_status='void' THEN RAISE EXCEPTION 'Cannot attach active release membership to a void invoice'; END IF;

  SELECT a.*,sil.supplier_invoice_id,si.review_status,si.blocked_from_sage_yn,
         o.order_type,o.parent_order_id,sil.eligible_for_invoice_yn
  INTO v_src
  FROM public.order_tracking_line_allocations a
  JOIN public.supplier_invoice_lines sil ON sil.id=a.supplier_invoice_line_id
  JOIN public.supplier_invoices si ON si.id=sil.supplier_invoice_id
  JOIN public.orders o ON o.id=a.order_id
  WHERE a.id=NEW.tracking_line_allocation_id
  FOR UPDATE OF a;

  IF v_src.id IS NULL
     OR v_src.order_id IS DISTINCT FROM NEW.order_id
     OR v_src.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
     OR v_src.supplier_invoice_id IS DISTINCT FROM NEW.supplier_invoice_id
     OR v_src.tracking_submission_id IS DISTINCT FROM NEW.tracking_submission_id
  THEN RAISE EXCEPTION 'Release source identity does not match the exact tracking allocation'; END IF;

  v_parent := CASE WHEN v_src.order_type='replacement_child' AND v_src.parent_order_id IS NOT NULL
                   THEN v_src.parent_order_id ELSE v_src.order_id END;
  IF NEW.commercial_parent_order_id IS DISTINCT FROM v_parent
     OR v_sales.order_id IS DISTINCT FROM v_parent
  THEN RAISE EXCEPTION 'Release commercial parent identity mismatch'; END IF;

  IF COALESCE(v_src.review_status,'pending_review') NOT IN ('approved_current','ref_corrected_approved')
     OR COALESCE(v_src.blocked_from_sage_yn,false)=true
  THEN RAISE EXCEPTION 'Supplier invoice is not approved/current for release'; END IF;

  IF lower(COALESCE(v_src.eligible_for_invoice_yn::text,'')) NOT IN ('y','yes','true','1') THEN
    RAISE EXCEPTION 'Supplier invoice line is not progressed for release';
  END IF;

  SELECT r.receipt_status::text INTO v_receipt
  FROM public.shipper_package_receipts r
  WHERE r.tracking_submission_id=NEW.tracking_submission_id
  ORDER BY r.recorded_at DESC,r.created_at DESC,r.id DESC LIMIT 1;
  IF v_receipt IS DISTINCT FROM 'received_clean' THEN RAISE EXCEPTION 'Package is not currently received clean'; END IF;

  IF NEW.source_shipment_batch_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.shipper_shipment_batch_packages p
    WHERE p.shipment_batch_id=NEW.source_shipment_batch_id
      AND p.tracking_submission_id=NEW.tracking_submission_id AND p.active=true
  ) THEN RAISE EXCEPTION 'Tracking allocation is not active in the stated shipment batch'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id=NEW.order_id AND h.resolved_at IS NULL
      AND h.status IN ('requested','supervisor_approved')
      AND (h.requested_scope='order'
        OR (h.requested_scope='tracking' AND h.tracking_submission_id=NEW.tracking_submission_id)
        OR (h.requested_scope='line' AND h.supplier_invoice_line_id=NEW.supplier_invoice_line_id))
  ) THEN RAISE EXCEPTION 'Active customer hold conflicts with release membership'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.dispute_lines dl JOIN public.disputes d ON d.id=dl.dispute_id
    WHERE dl.supplier_invoice_line_id=NEW.supplier_invoice_line_id
      AND dl.resolved_at IS NULL AND d.resolved_at IS NULL
  ) THEN RAISE EXCEPTION 'Unresolved exception conflicts with release membership'; END IF;

  SELECT COALESCE(SUM(l.released_qty),0),COALESCE(SUM(l.goods_amount_gbp),0),
         COALESCE(SUM(l.shipping_amount_gbp),0)
  INTO v_qty,v_goods,v_ship
  FROM public.customer_sales_release_lines l
  WHERE l.tracking_line_allocation_id=NEW.tracking_line_allocation_id
    AND l.release_status='active'
    AND (TG_OP='INSERT' OR l.id<>NEW.id);

  IF v_qty+NEW.released_qty > COALESCE(v_src.qty_allocated,0)+0.001 THEN
    RAISE EXCEPTION 'Release quantity exceeds exact tracking allocation';
  END IF;
  IF v_goods+NEW.goods_amount_gbp > COALESCE(v_src.adjusted_net_value_gbp,0)+0.02 THEN
    RAISE EXCEPTION 'Release goods value exceeds exact tracking allocation';
  END IF;
  IF NEW.delivery_share_gbp > COALESCE(v_src.retailer_delivery_share_gbp,0)+0.02
     OR NEW.discount_share_gbp > COALESCE(v_src.discount_share_gbp,0)+0.02
  THEN RAISE EXCEPTION 'Release delivery/discount share exceeds exact tracking allocation'; END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_sales_release_guard_v1
BEFORE INSERT OR UPDATE ON public.customer_sales_release_lines
FOR EACH ROW EXECUTE FUNCTION public.customer_sales_release_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_sales_invoice_release_identity_guard_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.customer_sales_release_lines l
    WHERE l.sales_invoice_id=OLD.id AND l.release_status='active'
  ) AND (
    NEW.order_id IS DISTINCT FROM OLD.order_id
    OR NEW.invoice_type IS DISTINCT FROM OLD.invoice_type
    OR NEW.linked_invoice_id IS DISTINCT FROM OLD.linked_invoice_id
    OR NEW.amount_gbp IS DISTINCT FROM OLD.amount_gbp
    OR NEW.line_items_json IS DISTINCT FROM OLD.line_items_json
  ) THEN
    RAISE EXCEPTION 'Sales invoice identity/payload is immutable while durable release membership exists';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_sales_invoice_release_identity_guard_v1
BEFORE UPDATE OF order_id,invoice_type,linked_invoice_id,amount_gbp,line_items_json
ON public.sales_invoices
FOR EACH ROW EXECUTE FUNCTION public.customer_sales_invoice_release_identity_guard_v1();

CREATE UNIQUE INDEX uq_sales_invoices_nonvoid_main_v1
  ON public.sales_invoices(order_id)
  WHERE invoice_type='main' AND sage_status<>'void';

CREATE UNIQUE INDEX uq_sales_invoices_active_release_draft_v1
  ON public.sales_invoices(order_id)
  WHERE invoice_type IN ('main','supplementary') AND sage_status='draft';

INSERT INTO public.customer_sales_release_legacy_issues(
  sales_invoice_id,order_id,issue_code,issue_detail,source_payload
)
SELECT si.id,si.order_id,'legacy_release_provenance_unresolved',
       'Existing non-void customer sales document has no durable exact source membership; review is required before overlapping release.',
       si.line_items_json
FROM public.sales_invoices si
WHERE si.invoice_type IN ('main','supplementary')
  AND si.sage_status<>'void'
  AND NOT EXISTS (SELECT 1 FROM public.customer_sales_release_lines l WHERE l.sales_invoice_id=si.id)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.staff_reverse_customer_sales_release_v1(p_release_id uuid,p_reason text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_staff uuid; v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN RAISE EXCEPTION 'Active staff required'; END IF;
  IF NULLIF(BTRIM(COALESCE(p_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'Reversal reason is required'; END IF;
  SELECT id INTO v_staff FROM public.staff WHERE auth_user_id=auth.uid() AND active=true LIMIT 1;
  UPDATE public.customer_sales_release_lines
  SET release_status='reversed',reversed_at=now(),reversed_by_staff_id=v_staff,reversal_reason=BTRIM(p_reason)
  WHERE id=p_release_id AND release_status='active'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Active release membership not found'; END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.staff_reverse_customer_sales_release_v1(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reverse_customer_sales_release_v1(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_sales_release_financial_guard_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_alloc record;
  v_parent uuid;
  v_delivery numeric;
  v_discount numeric;
  v_shipping numeric;
  v_shipping_limit numeric;
BEGIN
  IF TG_OP='UPDATE' AND NEW.release_status='reversed' THEN RETURN NEW; END IF;

  SELECT a.*,o.order_type,o.parent_order_id
  INTO v_alloc
  FROM public.order_tracking_line_allocations a
  JOIN public.orders o ON o.id=a.order_id
  WHERE a.id=NEW.tracking_line_allocation_id
  FOR UPDATE OF a;
  v_parent:=CASE WHEN v_alloc.order_type='replacement_child' AND v_alloc.parent_order_id IS NOT NULL
                 THEN v_alloc.parent_order_id ELSE v_alloc.order_id END;

  IF EXISTS (
    SELECT 1 FROM public.customer_pre_shipment_hold_requests hold_row
    WHERE hold_row.order_id IN (NEW.order_id,v_parent)
      AND hold_row.resolved_at IS NULL
      AND hold_row.status IN ('requested','supervisor_approved')
      AND (hold_row.requested_scope='order'
        OR (hold_row.requested_scope='tracking' AND hold_row.tracking_submission_id=NEW.tracking_submission_id)
        OR (hold_row.requested_scope='line' AND hold_row.supplier_invoice_line_id=NEW.supplier_invoice_line_id))
  ) THEN
    RAISE EXCEPTION 'Active source or commercial-parent customer hold conflicts with release membership';
  END IF;

  SELECT COALESCE(SUM(l.delivery_share_gbp),0),COALESCE(SUM(l.discount_share_gbp),0),
         COALESCE(SUM(l.shipping_amount_gbp),0)
  INTO v_delivery,v_discount,v_shipping
  FROM public.customer_sales_release_lines l
  WHERE l.tracking_line_allocation_id=NEW.tracking_line_allocation_id
    AND l.release_status='active'
    AND (TG_OP='INSERT' OR l.id<>NEW.id);

  IF v_delivery+NEW.delivery_share_gbp > COALESCE(v_alloc.retailer_delivery_share_gbp,0)+0.02 THEN
    RAISE EXCEPTION 'Cumulative release delivery share exceeds exact tracking allocation';
  END IF;
  IF v_discount+NEW.discount_share_gbp > COALESCE(v_alloc.discount_share_gbp,0)+0.02 THEN
    RAISE EXCEPTION 'Cumulative release discount share exceeds exact tracking allocation';
  END IF;

  IF NEW.shipping_amount_gbp>0 THEN
    IF NEW.source_shipment_batch_id IS NULL THEN
      RAISE EXCEPTION 'Shipping release requires exact source shipment batch';
    END IF;
    SELECT COALESCE(MAX(scal.allocated_amount),0)
    INTO v_shipping_limit
    FROM public.shipping_documents sd
    JOIN public.shipping_cost_allocations sca
      ON sca.shipping_document_id=sd.id AND sca.active=true AND sca.allocation_status='approved'
    JOIN public.shipping_cost_allocation_lines scal
      ON scal.shipping_cost_allocation_id=sca.id
     AND scal.tracking_submission_id=NEW.tracking_submission_id
     AND scal.supplier_invoice_line_id=NEW.supplier_invoice_line_id
    WHERE sd.shipment_batch_id=NEW.source_shipment_batch_id
      AND sd.active=true AND sd.review_status='accepted_current';

    IF v_shipping+NEW.shipping_amount_gbp > COALESCE(v_shipping_limit,0)+0.02 THEN
      RAISE EXCEPTION 'Cumulative release shipping exceeds approved exact shipping allocation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_sales_release_financial_guard_v1
BEFORE INSERT OR UPDATE ON public.customer_sales_release_lines
FOR EACH ROW EXECUTE FUNCTION public.customer_sales_release_financial_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_sales_release_total_guard_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_invoice_id uuid;
  v_invoice record;
  v_total numeric;
  v_count integer;
BEGIN
  v_invoice_id:=CASE WHEN TG_OP='DELETE' THEN OLD.sales_invoice_id ELSE NEW.sales_invoice_id END;
  SELECT id,invoice_type::text invoice_type,sage_status::text sage_status,amount_gbp
  INTO v_invoice FROM public.sales_invoices WHERE id=v_invoice_id;
  IF v_invoice.id IS NOT NULL
     AND v_invoice.invoice_type IN ('main','supplementary')
     AND v_invoice.sage_status<>'void'
  THEN
    SELECT COUNT(*),ROUND(COALESCE(SUM(customer_charge_amount_gbp),0),2)
    INTO v_count,v_total
    FROM public.customer_sales_release_lines
    WHERE sales_invoice_id=v_invoice_id AND release_status='active';
    IF v_count=0 OR ABS(v_total-v_invoice.amount_gbp)>0.02 THEN
      RAISE EXCEPTION 'Durable release total does not match non-void customer sales invoice amount';
    END IF;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_customer_sales_release_total_guard_v1
AFTER INSERT OR UPDATE OR DELETE ON public.customer_sales_release_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.customer_sales_release_total_guard_v1();

NOTIFY pgrst,'reload schema';
COMMIT;
