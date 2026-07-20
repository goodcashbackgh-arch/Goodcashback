BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

CREATE OR REPLACE FUNCTION public.internal_customer_sales_release_sources_v1(p_batch_id uuid)
RETURNS TABLE (
  shipment_batch_id uuid,
  booking_ref text,
  importer_id uuid,
  importer_name text,
  shipper_id uuid,
  shipper_name text,
  commercial_parent_order_id uuid,
  source_order_id uuid,
  order_ref text,
  tracking_submission_id uuid,
  tracking_ref text,
  tracking_line_allocation_id uuid,
  supplier_invoice_id uuid,
  supplier_invoice_line_id uuid,
  item_description text,
  release_qty numeric,
  goods_amount_gbp numeric,
  delivery_share_gbp numeric,
  discount_share_gbp numeric,
  shipping_amount_gbp numeric,
  customer_charge_amount_gbp numeric,
  proposed_invoice_type text,
  sales_invoice_state text,
  membership_fingerprint text,
  blocker text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required for customer release source resolution';
  END IF;

  RETURN QUERY
  WITH raw AS (
    SELECT
      b.id batch_id,b.booking_ref::text booking_ref,b.importer_id,
      COALESCE(NULLIF(i.trading_name,''),i.company_name)::text importer_name,
      b.shipper_id,s.name::text shipper_name,
      a.order_id source_order_id,
      CASE WHEN o.order_type='replacement_child' AND o.parent_order_id IS NOT NULL
           THEN o.parent_order_id ELSE o.id END commercial_parent_order_id,
      parent_o.order_ref::text order_ref,
      a.tracking_submission_id,ots.tracking_ref::text tracking_ref,
      a.id tracking_line_allocation_id,
      sil.supplier_invoice_id,a.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description),''),'Goods')::text item_description,
      COALESCE(a.qty_allocated,0)::numeric allocated_qty,
      COALESCE(a.adjusted_net_value_gbp,0)::numeric allocated_goods,
      COALESCE(a.retailer_delivery_share_gbp,0)::numeric allocated_delivery,
      COALESCE(a.discount_share_gbp,0)::numeric allocated_discount,
      si.review_status::text review_status,
      COALESCE(si.blocked_from_sage_yn,false) blocked_from_sage_yn,
      sil.eligible_for_invoice_yn::text eligible_for_invoice_yn,
      receipt.receipt_status::text latest_receipt_status,
      COALESCE(shipping.allocated_amount,0)::numeric allocated_shipping,
      EXISTS (
        SELECT 1 FROM public.sales_invoices x
        WHERE x.order_id=CASE WHEN o.order_type='replacement_child' AND o.parent_order_id IS NOT NULL THEN o.parent_order_id ELSE o.id END
          AND x.invoice_type='main' AND x.sage_status<>'void'
      ) has_main,
      EXISTS (
        SELECT 1 FROM public.sales_invoices x
        WHERE x.order_id=CASE WHEN o.order_type='replacement_child' AND o.parent_order_id IS NOT NULL THEN o.parent_order_id ELSE o.id END
          AND x.invoice_type IN ('main','supplementary') AND x.sage_status='draft'
      ) has_active_draft,
      EXISTS (
        SELECT 1 FROM public.customer_sales_release_legacy_issues li
        JOIN public.sales_invoices xsi ON xsi.id=li.sales_invoice_id
        WHERE xsi.order_id=CASE WHEN o.order_type='replacement_child' AND o.parent_order_id IS NOT NULL THEN o.parent_order_id ELSE o.id END
          AND li.resolved_at IS NULL
      ) has_legacy_issue,
      EXISTS (
        SELECT 1 FROM public.customer_pre_shipment_hold_requests h
        WHERE h.order_id IN (o.id,CASE WHEN o.order_type='replacement_child' AND o.parent_order_id IS NOT NULL THEN o.parent_order_id ELSE o.id END)
          AND h.resolved_at IS NULL
          AND h.status IN ('requested','supervisor_approved')
          AND (h.requested_scope='order'
            OR (h.requested_scope='tracking' AND h.tracking_submission_id=a.tracking_submission_id)
            OR (h.requested_scope='line' AND h.supplier_invoice_line_id=a.supplier_invoice_line_id))
      ) has_hold,
      EXISTS (
        SELECT 1 FROM public.dispute_lines dl JOIN public.disputes d ON d.id=dl.dispute_id
        WHERE dl.supplier_invoice_line_id=a.supplier_invoice_line_id
          AND dl.resolved_at IS NULL AND d.resolved_at IS NULL
      ) has_exception
    FROM public.shipper_shipment_batches b
    JOIN public.shipper_shipment_batch_packages p
      ON p.shipment_batch_id=b.id AND p.active=true
    JOIN public.order_tracking_submissions ots ON ots.id=p.tracking_submission_id
    JOIN public.order_tracking_line_allocations a ON a.tracking_submission_id=p.tracking_submission_id
    JOIN public.orders o ON o.id=a.order_id
    JOIN public.orders parent_o ON parent_o.id=CASE WHEN o.order_type='replacement_child' AND o.parent_order_id IS NOT NULL THEN o.parent_order_id ELSE o.id END
    JOIN public.supplier_invoice_lines sil ON sil.id=a.supplier_invoice_line_id
    JOIN public.supplier_invoices si ON si.id=sil.supplier_invoice_id
    JOIN public.shippers s ON s.id=b.shipper_id
    LEFT JOIN public.importers i ON i.id=b.importer_id
    LEFT JOIN LATERAL (
      SELECT r.receipt_status
      FROM public.shipper_package_receipts r
      WHERE r.tracking_submission_id=a.tracking_submission_id
      ORDER BY r.recorded_at DESC,r.created_at DESC,r.id DESC LIMIT 1
    ) receipt ON true
    LEFT JOIN LATERAL (
      SELECT scal.allocated_amount
      FROM public.shipping_documents sd
      JOIN public.shipping_cost_allocations sca
        ON sca.shipping_document_id=sd.id AND sca.active=true AND sca.allocation_status='approved'
      JOIN public.shipping_cost_allocation_lines scal
        ON scal.shipping_cost_allocation_id=sca.id
       AND scal.tracking_submission_id=a.tracking_submission_id
       AND scal.supplier_invoice_line_id=a.supplier_invoice_line_id
      WHERE sd.shipment_batch_id=b.id AND sd.active=true AND sd.review_status='accepted_current'
      ORDER BY sca.approved_at DESC NULLS LAST,sca.created_at DESC LIMIT 1
    ) shipping ON true
    WHERE b.id=p_batch_id
  ), used AS (
    SELECT l.tracking_line_allocation_id,
           SUM(l.released_qty) released_qty,
           SUM(l.goods_amount_gbp) released_goods,
           SUM(l.delivery_share_gbp) released_delivery,
           SUM(l.discount_share_gbp) released_discount,
           SUM(l.shipping_amount_gbp) released_shipping
    FROM public.customer_sales_release_lines l
    WHERE l.release_status='active'
    GROUP BY l.tracking_line_allocation_id
  ), calc AS (
    SELECT r.*,
      GREATEST(r.allocated_qty-COALESCE(u.released_qty,0),0)::numeric remaining_qty,
      GREATEST(r.allocated_goods-COALESCE(u.released_goods,0),0)::numeric remaining_goods,
      GREATEST(r.allocated_delivery-COALESCE(u.released_delivery,0),0)::numeric remaining_delivery,
      GREATEST(r.allocated_discount-COALESCE(u.released_discount,0),0)::numeric remaining_discount,
      GREATEST(r.allocated_shipping-COALESCE(u.released_shipping,0),0)::numeric remaining_shipping
    FROM raw r LEFT JOIN used u ON u.tracking_line_allocation_id=r.tracking_line_allocation_id
  )
  SELECT
    c.batch_id,c.booking_ref,c.importer_id,c.importer_name,c.shipper_id,c.shipper_name,
    c.commercial_parent_order_id,c.source_order_id,c.order_ref,
    c.tracking_submission_id,c.tracking_ref,c.tracking_line_allocation_id,
    c.supplier_invoice_id,c.supplier_invoice_line_id,c.item_description,
    CASE WHEN c.remaining_goods>0 THEN c.remaining_qty ELSE 0 END,
    ROUND(c.remaining_goods,2),
    ROUND(c.remaining_delivery,2),
    ROUND(c.remaining_discount,2),
    ROUND(CASE WHEN c.has_main THEN c.remaining_shipping ELSE 0 END,2),
    ROUND(c.remaining_goods+CASE WHEN c.has_main THEN c.remaining_shipping ELSE 0 END,2),
    CASE WHEN c.has_main THEN 'supplementary' ELSE 'main' END::text,
    CASE WHEN c.has_main THEN 'main_sales_invoice_exists' ELSE 'no_main_sales_invoice_found' END::text,
    md5(concat_ws('|',c.batch_id,c.commercial_parent_order_id,c.tracking_line_allocation_id,
      c.remaining_qty,c.remaining_goods,CASE WHEN c.has_main THEN c.remaining_shipping ELSE 0 END)),
    CASE
      WHEN c.has_legacy_issue THEN 'customer_sales_release_legacy_provenance_unresolved'
      WHEN c.has_active_draft THEN 'customer_sales_release_draft_already_exists'
      WHEN c.review_status NOT IN ('approved_current','ref_corrected_approved') OR c.blocked_from_sage_yn THEN 'supplier_invoice_not_approved_current'
      WHEN lower(COALESCE(c.eligible_for_invoice_yn,'')) NOT IN ('y','yes','true','1') THEN 'supplier_line_not_progressed'
      WHEN c.latest_receipt_status IS DISTINCT FROM 'received_clean' THEN 'package_not_received_clean'
      WHEN c.has_hold THEN 'customer_hold_active'
      WHEN c.has_exception THEN 'unresolved_exception'
      WHEN ROUND(c.remaining_goods+CASE WHEN c.has_main THEN c.remaining_shipping ELSE 0 END,2)<=0 THEN 'source_fully_released'
      ELSE NULL
    END::text
  FROM calc c;
END;
$$;
REVOKE ALL ON FUNCTION public.internal_customer_sales_release_sources_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_sales_release_sources_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(p_shipment_batch_id uuid)
RETURNS TABLE (
  shipment_batch_id uuid,booking_ref text,importer_id uuid,importer_name text,
  shipper_id uuid,shipper_name text,proposed_invoice_type text,proposed_invoice_status text,
  customer_recharge_route text,sales_invoice_state text,vat_code text,
  proposed_amount_gbp numeric,proposed_goods_amount_gbp numeric,proposed_shipping_amount_gbp numeric,
  line_items_json jsonb,order_id uuid,order_ref text,tracking_submission_id uuid,tracking_ref text,
  supplier_invoice_line_id uuid,item_description text,qty_allocated numeric,goods_amount_gbp numeric,
  shipping_amount_gbp numeric,total_line_amount_gbp numeric,readiness_status text,blocker text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN RAISE EXCEPTION 'Active staff required'; END IF;
  RETURN QUERY
  WITH src AS (
    SELECT * FROM public.internal_customer_sales_release_sources_v1(p_shipment_batch_id)
  ), totals AS (
    SELECT
      COALESCE(SUM(customer_charge_amount_gbp) FILTER(WHERE blocker IS NULL),0)::numeric amount,
      COALESCE(SUM(goods_amount_gbp) FILTER(WHERE blocker IS NULL),0)::numeric goods,
      COALESCE(SUM(shipping_amount_gbp) FILTER(WHERE blocker IS NULL),0)::numeric shipping,
      COALESCE(jsonb_agg(jsonb_build_object(
        'source_order_id',source_order_id,
        'source_commercial_parent_order_id',commercial_parent_order_id,
        'source_shipment_batch_id',shipment_batch_id,
        'source_tracking_submission_id',tracking_submission_id,
        'source_tracking_line_allocation_id',tracking_line_allocation_id,
        'source_supplier_invoice_id',supplier_invoice_id,
        'source_supplier_invoice_line_id',supplier_invoice_line_id,
        'released_qty',release_qty,
        'goods_amount_gbp',goods_amount_gbp,
        'delivery_share_gbp',delivery_share_gbp,
        'discount_share_gbp',discount_share_gbp,
        'shipping_amount_gbp',shipping_amount_gbp,
        'customer_charge_amount_gbp',customer_charge_amount_gbp,
        'membership_fingerprint',membership_fingerprint,
        'description',item_description,
        'quantity',CASE WHEN release_qty>0 THEN release_qty ELSE 1 END,
        'total_line_amount_gbp',customer_charge_amount_gbp,
        'ledger_account_role','export_sale_income',
        'source','customer_sales_release_ledger'
      ) ORDER BY order_ref,tracking_ref,item_description) FILTER(WHERE blocker IS NULL),'[]'::jsonb) lines
    FROM src
  )
  SELECT s.shipment_batch_id,s.booking_ref,s.importer_id,s.importer_name,s.shipper_id,s.shipper_name,
    s.proposed_invoice_type,CASE WHEN s.blocker IS NULL THEN 'draft_preview' ELSE 'blocked' END,
    CASE WHEN s.proposed_invoice_type='main' THEN 'main_customer_release_invoice' ELSE 'supplementary_customer_release_invoice' END,
    s.sales_invoice_state,'T0 / GB_ZERO',t.amount,t.goods,t.shipping,t.lines,
    s.commercial_parent_order_id,s.order_ref,s.tracking_submission_id,s.tracking_ref,
    s.supplier_invoice_line_id,s.item_description,s.release_qty,s.goods_amount_gbp,
    s.shipping_amount_gbp,s.customer_charge_amount_gbp,
    CASE WHEN s.blocker IS NOT NULL THEN 'blocked'
         WHEN s.proposed_invoice_type='main' THEN 'ready_for_main_invoice_release_preview'
         ELSE 'ready_for_supplementary_invoice_preview' END,
    s.blocker
  FROM src s CROSS JOIN totals t
  WHERE s.blocker IS NULL OR NOT EXISTS(SELECT 1 FROM src x WHERE x.blocker IS NULL)
  ORDER BY s.order_ref,s.tracking_ref,s.item_description;
END;
$$;
REVOKE ALL ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_customer_invoice_readiness_preview_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_customer_invoice_release_queue_v1()
RETURNS TABLE (
  shipment_batch_id uuid,booking_ref text,importer_id uuid,importer_name text,shipper_id uuid,shipper_name text,
  proposed_invoice_type text,customer_action_label text,sales_invoice_state text,vat_code text,
  proposed_amount_gbp numeric,proposed_goods_amount_gbp numeric,proposed_shipping_amount_gbp numeric,
  order_count integer,line_count integer,ready_line_count integer,blocker_count integer,blockers text[],
  readiness_status text,first_order_ref text,order_refs text,created_draft_count integer,posted_invoice_count integer,
  queue_action text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN RAISE EXCEPTION 'Active staff required'; END IF;
  RETURN QUERY
  WITH batches AS (
    SELECT DISTINCT sc.shipment_batch_id
    FROM public.internal_shipping_control_v1() sc
    WHERE sc.shipment_batch_id IS NOT NULL
      AND COALESCE(sc.allocation_status_summary,'')='contents_allocated'
      AND COALESCE(sc.receipt_status_summary,'')='received_clean'
  ), rows AS (
    SELECT p.* FROM batches b
    CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(b.shipment_batch_id) p
  ), g AS (
    SELECT r.shipment_batch_id,MAX(r.booking_ref)::text booking_ref,
      (array_agg(DISTINCT r.importer_id))[1] importer_id,MAX(r.importer_name)::text importer_name,
      (array_agg(DISTINCT r.shipper_id))[1] shipper_id,MAX(r.shipper_name)::text shipper_name,
      CASE WHEN COUNT(DISTINCT r.proposed_invoice_type)=1 THEN MAX(r.proposed_invoice_type)::text ELSE 'mixed'::text END proposed_invoice_type,
      MAX(r.sales_invoice_state)::text sales_invoice_state,MAX(r.vat_code)::text vat_code,
      MAX(r.proposed_amount_gbp)::numeric amount,MAX(r.proposed_goods_amount_gbp)::numeric goods,
      MAX(r.proposed_shipping_amount_gbp)::numeric shipping,
      COUNT(DISTINCT r.order_id)::integer order_count,COUNT(*)::integer line_count,
      COUNT(*) FILTER(WHERE r.blocker IS NULL)::integer ready_count,
      COUNT(*) FILTER(WHERE r.blocker IS NOT NULL)::integer blocker_count,
      array_remove(array_agg(DISTINCT r.blocker),NULL)::text[] blockers,
      MIN(r.order_ref)::text first_order_ref,string_agg(DISTINCT r.order_ref,', ' ORDER BY r.order_ref)::text order_refs,
      COUNT(DISTINCT si.id) FILTER(WHERE si.sage_status='draft')::integer draft_count,
      COUNT(DISTINCT si.id) FILTER(WHERE si.sage_status='posted')::integer posted_count
    FROM rows r
    LEFT JOIN public.sales_invoices si
      ON si.order_id=r.order_id AND si.invoice_type IN ('main','supplementary')
    GROUP BY r.shipment_batch_id
  )
  SELECT g.shipment_batch_id,g.booking_ref,g.importer_id,g.importer_name,g.shipper_id,g.shipper_name,
    g.proposed_invoice_type,
    CASE WHEN g.proposed_invoice_type='main' THEN 'Create main export sale invoice'
         WHEN g.proposed_invoice_type='supplementary' THEN 'Create supplementary export sale invoice'
         ELSE 'Create customer sales invoice drafts' END,
    g.sales_invoice_state,g.vat_code,COALESCE(g.amount,0),COALESCE(g.goods,0),COALESCE(g.shipping,0),
    g.order_count,g.line_count,g.ready_count,g.blocker_count,COALESCE(g.blockers,ARRAY[]::text[]),
    CASE WHEN g.ready_count>0 AND g.draft_count=0 THEN 'ready_to_create_draft'
         WHEN g.draft_count>0 THEN 'draft_exists'
         WHEN g.blocker_count>0 THEN 'blocked'
         WHEN g.posted_count>0 THEN 'posted_exists' ELSE 'blocked' END,
    g.first_order_ref,g.order_refs,g.draft_count,g.posted_count,
    CASE WHEN g.ready_count>0 AND g.draft_count=0 THEN 'ready_for_bulk_draft_creation'
         WHEN g.draft_count>0 THEN 'review_existing_draft'
         WHEN g.blocker_count>0 THEN 'resolve_blockers' ELSE 'review_posted_invoice' END
  FROM g ORDER BY CASE WHEN g.ready_count>0 AND g.draft_count=0 THEN 0 WHEN g.draft_count>0 THEN 1 ELSE 2 END,g.booking_ref;
END;
$$;
REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_queue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_queue_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_customer_invoice_release_create_drafts_v1(p_shipment_batch_ids uuid[])
RETURNS TABLE (
  shipment_batch_id uuid,order_id uuid,order_ref text,booking_ref text,invoice_type text,
  result_status text,sales_invoice_id uuid,amount_gbp numeric,message text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
  v_staff uuid;
  v_batch uuid;
  v_parent uuid;
  v_type text;
  v_main uuid;
  v_invoice uuid;
  v_amount numeric;
  v_payload jsonb;
  v_ref text;
  v_booking text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN RAISE EXCEPTION 'Active staff required'; END IF;
  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids,1) IS NULL THEN
    RAISE EXCEPTION 'At least one shipment batch id is required';
  END IF;
  SELECT id INTO v_staff FROM public.staff WHERE auth_user_id=auth.uid() AND active=true LIMIT 1;

  CREATE TEMP TABLE _release_src ON COMMIT DROP AS
    SELECT s.* FROM (SELECT DISTINCT unnest(p_shipment_batch_ids) id) b
    CROSS JOIN LATERAL public.internal_customer_sales_release_sources_v1(b.id) s
    WHERE s.blocker IS NULL OR s.blocker='customer_sales_release_draft_already_exists';
  CREATE INDEX ON _release_src(commercial_parent_order_id,proposed_invoice_type);

  FOR v_parent IN
    SELECT DISTINCT commercial_parent_order_id FROM _release_src ORDER BY commercial_parent_order_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext('customer_sales_release|'||v_parent::text));
    PERFORM 1 FROM public.orders WHERE id=v_parent FOR UPDATE;

    SELECT id,amount_gbp,invoice_type::text INTO v_invoice,v_amount,v_type
    FROM public.sales_invoices
    WHERE order_id=v_parent AND invoice_type IN ('main','supplementary') AND sage_status='draft'
    ORDER BY created_at DESC LIMIT 1;

    SELECT MIN(shipment_batch_id),MIN(order_ref),string_agg(DISTINCT booking_ref,', ' ORDER BY booking_ref)
      INTO v_batch,v_ref,v_booking
    FROM _release_src WHERE commercial_parent_order_id=v_parent;

    IF v_invoice IS NOT NULL THEN
      RETURN QUERY SELECT v_batch,v_parent,v_ref,v_booking,v_type,
        'skipped_draft_already_exists',v_invoice,v_amount,
        'Existing draft reused; no duplicate release membership created';
      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM _release_src WHERE commercial_parent_order_id=v_parent AND blocker IS NULL
    ) THEN CONTINUE; END IF;

    SELECT id INTO v_main FROM public.sales_invoices
    WHERE order_id=v_parent AND invoice_type='main' AND sage_status<>'void'
    ORDER BY created_at LIMIT 1;
    IF v_main IS NULL THEN v_type:='main'; ELSE v_type:='supplementary'; END IF;

    SELECT ROUND(SUM(customer_charge_amount_gbp),2),
      jsonb_build_object(
        'sage_header',jsonb_build_object('reference',MIN(order_ref),'notes','Booking '||string_agg(DISTINCT booking_ref,', ' ORDER BY booking_ref)),
        'tax_resolution',jsonb_build_object('tax_treatment','zero_rated_export','display_vat_code','zero-rated export'),
        'lines',jsonb_agg(jsonb_build_object(
          'source_order_id',source_order_id,
          'source_commercial_parent_order_id',commercial_parent_order_id,
          'source_shipment_batch_id',shipment_batch_id,
          'source_tracking_submission_id',tracking_submission_id,
          'source_tracking_line_allocation_id',tracking_line_allocation_id,
          'source_supplier_invoice_id',supplier_invoice_id,
          'source_supplier_invoice_line_id',supplier_invoice_line_id,
          'released_qty',release_qty,
          'goods_amount_gbp',goods_amount_gbp,
          'delivery_share_gbp',delivery_share_gbp,
          'discount_share_gbp',discount_share_gbp,
          'shipping_amount_gbp',shipping_amount_gbp,
          'customer_charge_amount_gbp',customer_charge_amount_gbp,
          'membership_fingerprint',membership_fingerprint,
          'description',item_description,
          'quantity',CASE WHEN release_qty>0 THEN release_qty ELSE 1 END,
          'total_line_amount_gbp',customer_charge_amount_gbp,
          'ledger_account_role','export_sale_income'
        ) ORDER BY booking_ref,tracking_ref,item_description),
        'draft_control',jsonb_build_object(
          'created_from','customer_invoice_release_queue',
          'shipment_batch_id',MIN(shipment_batch_id),
          'shipment_batch_ids',jsonb_agg(DISTINCT shipment_batch_id),
          'status','internal_draft_only_not_posted_to_sage'
        )
      )
    INTO v_amount,v_payload
    FROM _release_src
    WHERE commercial_parent_order_id=v_parent AND blocker IS NULL;

    IF COALESCE(v_amount,0)<=0 THEN CONTINUE; END IF;

    INSERT INTO public.sales_invoices(
      order_id,invoice_type,linked_invoice_id,consideration_received_date,sage_invoice_date,
      tax_point_period,sage_invoice_period,vat_box6_reported_period,amount_gbp,vat_code,line_items_json,
      sage_invoice_id,sage_posted_at,sage_status,export_evidence_complete_date,zero_rating_deadline_date,
      zero_rating_status,vat_adjustment_posted_at,reversal_posted_at,raised_by_trigger
    ) VALUES (
      v_parent,v_type,CASE WHEN v_type='supplementary' THEN v_main ELSE NULL END,
      CURRENT_DATE,CURRENT_DATE,to_char(CURRENT_DATE,'YYYY-MM'),to_char(CURRENT_DATE,'YYYY-MM'),NULL,
      v_amount,'ZERO_RATED_EXPORT_INTENT',v_payload,NULL,NULL,'draft',NULL,
      (CURRENT_DATE+INTERVAL '90 days')::date,'on_track',NULL,NULL,false
    ) RETURNING id INTO v_invoice;

    INSERT INTO public.customer_sales_release_lines(
      sales_invoice_id,sales_invoice_type,order_id,commercial_parent_order_id,source_shipment_batch_id,
      supplier_invoice_id,supplier_invoice_line_id,tracking_submission_id,tracking_line_allocation_id,
      released_qty,goods_amount_gbp,delivery_share_gbp,discount_share_gbp,shipping_amount_gbp,
      customer_charge_amount_gbp,membership_fingerprint,created_by_staff_id
    )
    SELECT v_invoice,v_type,source_order_id,commercial_parent_order_id,shipment_batch_id,
      supplier_invoice_id,supplier_invoice_line_id,tracking_submission_id,tracking_line_allocation_id,
      release_qty,goods_amount_gbp,delivery_share_gbp,discount_share_gbp,shipping_amount_gbp,
      customer_charge_amount_gbp,membership_fingerprint,v_staff
    FROM _release_src
    WHERE commercial_parent_order_id=v_parent AND blocker IS NULL;

    RETURN QUERY SELECT v_batch,v_parent,v_ref,v_booking,v_type,'draft_created',v_invoice,v_amount,
      'Draft sales invoice created with durable exact release membership. Not posted to Sage.';
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) TO authenticated;

NOTIFY pgrst,'reload schema';
COMMIT;
