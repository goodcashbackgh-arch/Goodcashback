BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $migration$
DECLARE
  v_oid oid := to_regprocedure('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)');
  v_definition text;
  v_definition_md5 text;
  v_start integer;
  v_end integer;
  v_new_definition text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'V1.2 bridge: staff_decide_physical_receipt_review_v1 is missing.';
  END IF;

  SELECT pg_get_functiondef(v_oid), md5(pg_get_functiondef(v_oid))
  INTO v_definition, v_definition_md5;

  IF v_definition_md5 <> '1425cb06befeae6851303eab2ecd9efb' THEN
    RAISE EXCEPTION
      'V1.2 bridge: installed v1 fingerprint drifted (expected %, actual %). Stop and re-run live preflight.',
      '1425cb06befeae6851303eab2ecd9efb',
      v_definition_md5;
  END IF;

  IF md5(pg_get_functiondef('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)'::regprocedure))
       <> '63822bed13e02b23cd412d1ae3e5d915'
  THEN
    RAISE EXCEPTION 'V1.2 bridge: protected v2 gateway fingerprint drifted. Stop.';
  END IF;

  IF pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = v_oid)) <> 'postgres'
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid)
     OR (SELECT proconfig FROM pg_proc WHERE oid = v_oid) IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[]
  THEN
    RAISE EXCEPTION 'V1.2 bridge: v1 owner/security/search_path differs from approved live preflight.';
  END IF;

  v_start := strpos(v_definition, E'  SELECT o.operator_id, o.sop_version\n');
  v_end := strpos(v_definition, E'END;\n$function$');

  IF v_start = 0 OR v_end = 0 OR v_end <= v_start THEN
    RAISE EXCEPTION 'V1.2 bridge: approved replacement anchors were not found in installed v1 definition.';
  END IF;

  v_new_definition := substring(v_definition FROM 1 FOR v_start - 1)
    || $bridge$
  -- HYBRID_PHYSICAL_RECEIPT_V1_2_VALUE_PARTITION_BRIDGE
  SELECT o.operator_id, o.sop_version
  INTO v_operator_id, v_sop_version
  FROM public.orders o
  WHERE o.id = v_review.order_id
  FOR UPDATE;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Order operator could not be resolved for physical exception linkage.';
  END IF;

  -- Serialize the commercial-value source before deriving customer value.
  PERFORM 1
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id IN (
    SELECT remedy_row.tracking_line_allocation_id
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
  )
  ORDER BY allocation.id
  FOR UPDATE;

  IF EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    LEFT JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = remedy_row.tracking_line_allocation_id
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
      AND (
        allocation.id IS NULL
        OR allocation.order_id <> v_review.order_id
        OR allocation.supplier_invoice_line_id <> remedy_row.supplier_invoice_line_id
        OR allocation.qty_allocated <= 0
        OR allocation.adjusted_net_value_gbp <= 0
        OR remedy_row.approved_remedy_qty <= 0
        OR remedy_row.approved_remedy_qty > allocation.qty_allocated + 0.0005
      )
  ) THEN
    RAISE EXCEPTION 'Approved physical remedy has ambiguous or non-positive tracking-allocation commercial provenance.';
  END IF;

  -- Deterministic penny apportionment within each tracking allocation.
  WITH source_rows AS (
    SELECT
      remedy_row.id AS remedy_allocation_id,
      remedy_row.tracking_line_allocation_id,
      (allocation.adjusted_net_value_gbp * 100
        * remedy_row.approved_remedy_qty / allocation.qty_allocated) AS raw_cents
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = remedy_row.tracking_line_allocation_id
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
  ), ranked AS (
    SELECT
      source_rows.*,
      floor(raw_cents)::bigint AS floor_cents,
      row_number() OVER (
        PARTITION BY tracking_line_allocation_id
        ORDER BY (raw_cents - floor(raw_cents)) DESC, remedy_allocation_id
      ) AS remainder_rank,
      round(sum(raw_cents) OVER (PARTITION BY tracking_line_allocation_id))::bigint
        - sum(floor(raw_cents)::bigint) OVER (PARTITION BY tracking_line_allocation_id)
        AS pennies_to_distribute
    FROM source_rows
  ), apportioned AS (
    SELECT
      remedy_allocation_id,
      (floor_cents + CASE WHEN remainder_rank <= pennies_to_distribute THEN 1 ELSE 0 END)::numeric / 100
        AS commercial_value_gbp
    FROM ranked
  )
  UPDATE public.physical_exception_remedy_allocations remedy_row
  SET customer_commercial_value_gbp = apportioned.commercial_value_gbp,
      updated_at = v_now
  FROM apportioned
  WHERE remedy_row.id = apportioned.remedy_allocation_id;

  IF EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
      AND COALESCE(remedy_row.customer_commercial_value_gbp, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'Customer commercial value apportionment produced a missing or non-positive result.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines existing_line
    WHERE existing_line.supplier_invoice_line_id IN (
      SELECT remedy_row.supplier_invoice_line_id
      FROM public.physical_exception_remedy_allocations remedy_row
      WHERE remedy_row.physical_receipt_review_id = v_review.id
        AND remedy_row.status = 'approved'
        AND remedy_row.approved_remedy_type IN ('refund','replacement')
    )
      AND existing_line.resolved_at IS NULL
      AND existing_line.physical_remedy_allocation_id IS NULL
  ) THEN
    RAISE EXCEPTION 'An ambiguous unresolved legacy exception already exists for an approved physical source line.';
  END IF;

  FOR v_item IN
    SELECT
      remedy_row.id AS remedy_allocation_id,
      remedy_row.approved_remedy_type,
      remedy_row.approved_remedy_qty,
      remedy_row.supplier_invoice_line_id,
      remedy_row.customer_commercial_value_gbp,
      disposition.disposition_type
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN public.shipper_package_receipt_line_dispositions disposition
      ON disposition.id = remedy_row.receipt_line_disposition_id
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
    ORDER BY
      CASE remedy_row.approved_remedy_type WHEN 'refund' THEN 1 ELSE 2 END,
      remedy_row.supplier_invoice_line_id,
      disposition.disposition_type,
      remedy_row.id
  LOOP
    v_issue_type := CASE v_item.disposition_type
      WHEN 'missing' THEN 'missing'
      WHEN 'damaged' THEN 'damaged'
      WHEN 'wrong' THEN 'wrong_item'
      ELSE NULL
    END;

    IF v_issue_type IS NULL THEN
      RAISE EXCEPTION 'Disposition % cannot enter the existing refund/replacement route automatically.', v_item.disposition_type;
    END IF;

    v_dispute_id := NULL;

    IF v_item.approved_remedy_type = 'refund' THEN
      SELECT d.id
      INTO v_dispute_id
      FROM public.physical_receipt_review_dispute_links link_row
      JOIN public.disputes d ON d.id = link_row.dispute_id
      JOIN public.dispute_lines dl ON dl.dispute_id = d.id
      WHERE link_row.physical_receipt_review_id = v_review.id
        AND link_row.desired_outcome = 'refund'
        AND d.order_id = v_review.order_id
        AND d.issue_type = v_issue_type
        AND d.desired_outcome = 'refund'
        AND d.liable_party = p_liable_party
        AND dl.supplier_invoice_line_id = v_item.supplier_invoice_line_id
      ORDER BY d.id
      LIMIT 1;
    END IF;

    IF v_dispute_id IS NULL THEN
      INSERT INTO public.disputes (
        order_id,
        raised_by_operator_id,
        issue_type,
        desired_outcome,
        liable_party,
        stage_detected,
        amount_impact_gbp,
        comments_initial,
        status,
        sop_version,
        refund_approved_by_staff_id,
        refund_approved_at
      ) VALUES (
        v_review.order_id,
        v_operator_id,
        v_issue_type,
        v_item.approved_remedy_type,
        p_liable_party,
        'at_ghana_delivery',
        v_item.customer_commercial_value_gbp,
        'Created from physical receipt review ' || v_review.id::text || '. Customer commercial value is sourced only from order_tracking_line_allocations.adjusted_net_value_gbp; supplier recovery, settlement, VAT, accounting and funding remain separate.',
        'raised',
        v_sop_version,
        CASE WHEN v_item.approved_remedy_type = 'refund' THEN v_staff.id ELSE NULL END,
        CASE WHEN v_item.approved_remedy_type = 'refund' THEN v_now ELSE NULL END
      )
      RETURNING id INTO v_dispute_id;

      INSERT INTO public.physical_receipt_review_dispute_links (
        physical_receipt_review_id,
        dispute_id,
        desired_outcome,
        created_by_staff_id,
        created_at
      ) VALUES (
        v_review.id,
        v_dispute_id,
        v_item.approved_remedy_type,
        v_staff.id,
        v_now
      );
    ELSE
      -- A refund group may have only one physical remedy under the live one-line-per-invoice constraints.
      IF EXISTS (
        SELECT 1
        FROM public.dispute_lines dl
        WHERE dl.dispute_id = v_dispute_id
          AND dl.supplier_invoice_line_id = v_item.supplier_invoice_line_id
      ) THEN
        RAISE EXCEPTION 'Multiple approved physical refund allocations resolve to the same invoice/issue group under a one-line live constraint. Return for a revised importer split rather than guessing.';
      END IF;
    END IF;

    INSERT INTO public.dispute_lines (
      dispute_id,
      supplier_invoice_line_id,
      qty_impact,
      amount_impact_gbp,
      line_status,
      intended_remedy,
      conversation_status,
      physical_remedy_allocation_id
    ) VALUES (
      v_dispute_id,
      v_item.supplier_invoice_line_id,
      ROUND(v_item.approved_remedy_qty)::integer,
      v_item.customer_commercial_value_gbp,
      'affected',
      v_item.approved_remedy_type,
      CASE
        WHEN v_item.approved_remedy_type = 'refund' THEN 'refund_pending_approval'
        ELSE 'remedy_selected'
      END,
      v_item.remedy_allocation_id
    )
    RETURNING id INTO v_dispute_line_id;

    UPDATE public.physical_exception_remedy_allocations
    SET dispute_line_id = v_dispute_line_id,
        updated_at = v_now
    WHERE id = v_item.remedy_allocation_id;

    UPDATE public.disputes dispute_row
    SET amount_impact_gbp = (
      SELECT round(sum(dl.amount_impact_gbp), 2)
      FROM public.dispute_lines dl
      WHERE dl.dispute_id = dispute_row.id
    )
    WHERE dispute_row.id = v_dispute_id;

    IF v_item.approved_remedy_type = 'refund' AND v_refund_dispute_id IS NULL THEN
      v_refund_dispute_id := v_dispute_id;
    ELSIF v_item.approved_remedy_type = 'replacement' AND v_replacement_dispute_id IS NULL THEN
      v_replacement_dispute_id := v_dispute_id;
    END IF;
  END LOOP;

  SELECT link_row.dispute_id
  INTO v_primary_dispute_id
  FROM public.physical_receipt_review_dispute_links link_row
  WHERE link_row.physical_receipt_review_id = v_review.id
  ORDER BY
    CASE link_row.desired_outcome WHEN 'refund' THEN 1 ELSE 2 END,
    link_row.dispute_id
  LIMIT 1;

  IF v_primary_dispute_id IS NULL THEN
    RAISE EXCEPTION 'No outcome-specific dispute was linked for the approved physical review.';
  END IF;

  UPDATE public.physical_receipt_reviews
  SET status = 'approved_to_existing_exception',
      supervisor_decided_by_staff_id = v_staff.id,
      supervisor_decided_at = v_now,
      approved_liable_party = p_liable_party,
      decision_note = v_note,
      linked_dispute_id = v_primary_dispute_id,
      updated_at = v_now
  WHERE id = v_review.id;

  -- LINK_SHAPE_SEQUENCE_V1: establish the required review link before terminal remedy status.
  UPDATE public.physical_exception_remedy_allocations
  SET status = 'linked_to_exception',
      updated_at = v_now
  WHERE physical_receipt_review_id = v_review.id
    AND status = 'approved'
    AND approved_remedy_type IN ('refund','replacement')
    AND dispute_line_id IS NOT NULL;

  RETURN jsonb_build_object(
    'ok', true,
    'review_id', v_review.id,
    'status', 'approved_to_existing_exception',
    'primary_dispute_id', v_primary_dispute_id,
    'refund_dispute_id', v_refund_dispute_id,
    'replacement_dispute_id', v_replacement_dispute_id
  );
$bridge$
    || substring(v_definition FROM v_end);

  EXECUTE v_new_definition;

  IF md5(pg_get_functiondef(v_oid)) = v_definition_md5
     OR strpos(pg_get_functiondef(v_oid), 'HYBRID_PHYSICAL_RECEIPT_V1_2_VALUE_PARTITION_BRIDGE') = 0
  THEN
    RAISE EXCEPTION 'V1.2 bridge: replacement did not install.';
  END IF;

  IF pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid = v_oid)) <> 'postgres'
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_oid)
     OR (SELECT proconfig FROM pg_proc WHERE oid = v_oid) IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[]
  THEN
    RAISE EXCEPTION 'V1.2 bridge: owner/security/search_path changed unexpectedly.';
  END IF;
END
$migration$;

-- Preserve the approved direct-v1 posture from live preflight: no PUBLIC/anon/authenticated execute.
REVOKE ALL ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text) TO service_role;

COMMENT ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text) IS
'Hybrid Physical Receipt v1.2 supervisor bridge. Customer commercial value derives only from order_tracking_line_allocations.adjusted_net_value_gbp with deterministic penny apportionment; refund disputes partition by invoice/issue/outcome/liability and replacements remain one dispute per remedy allocation.';

NOTIFY pgrst, 'reload schema';

COMMIT;
