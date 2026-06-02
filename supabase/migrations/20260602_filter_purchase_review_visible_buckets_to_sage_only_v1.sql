BEGIN;

-- Display-layer filter only.
-- The current VAT return UI renders purchase_vat_line_review.buckets directly.
-- Keep platform-controlled lines in the review summary for bridge/proof, but remove
-- platform-controlled buckets from the visible bucket list so the main section shows
-- only Sage-only differences and Sage-only items needing review.
-- Does not touch vat_return_run_lines, blockers, evidence breach rules, prepayment/no-invoice
-- timing, journal validation, approval, or Sage posting.

CREATE OR REPLACE FUNCTION public.filter_purchase_review_visible_buckets_to_sage_only_v1(
  p_source_summary jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  v_summary jsonb := COALESCE(p_source_summary, '{}'::jsonb);
  v_review jsonb := v_summary #> '{purchase_vat_line_review}';
  v_buckets jsonb := COALESCE(v_review -> 'buckets', '{}'::jsonb);
  v_visible_buckets jsonb := '{}'::jsonb;
  v_excluded_buckets jsonb := '{}'::jsonb;
  v_key text;
  v_value jsonb;
  v_excluded_count integer := 0;
  v_excluded_box4 numeric := 0;
  v_excluded_box7 numeric := 0;
BEGIN
  IF v_review IS NULL OR jsonb_typeof(v_review) <> 'object' THEN
    RETURN v_summary;
  END IF;

  IF jsonb_typeof(v_buckets) <> 'object' THEN
    RETURN v_summary;
  END IF;

  FOR v_key, v_value IN SELECT key, value FROM jsonb_each(v_buckets)
  LOOP
    IF v_key LIKE 'platform_controlled%' THEN
      v_excluded_buckets := jsonb_set(v_excluded_buckets, ARRAY[v_key], v_value, true);
      v_excluded_count := v_excluded_count + COALESCE(NULLIF(v_value ->> 'count', '')::integer, 0);
      v_excluded_box4 := v_excluded_box4 + COALESCE(NULLIF(v_value ->> 'box4', '')::numeric, 0);
      v_excluded_box7 := v_excluded_box7 + COALESCE(NULLIF(v_value ->> 'box7', '')::numeric, 0);
    ELSE
      v_visible_buckets := jsonb_set(v_visible_buckets, ARRAY[v_key], v_value, true);
    END IF;
  END LOOP;

  v_review := jsonb_set(v_review, '{buckets}', v_visible_buckets, true);
  v_review := jsonb_set(
    v_review,
    '{platform_controlled_excluded_summary}',
    jsonb_build_object(
      'count', v_excluded_count,
      'box4', round(v_excluded_box4::numeric, 2),
      'box7', round(v_excluded_box7::numeric, 2),
      'buckets', v_excluded_buckets,
      'display_policy', 'excluded_from_visible_sage_only_bucket_table'
    ),
    true
  );
  v_review := jsonb_set(v_review, '{visible_bucket_policy}', '"sage_only_and_review_only"'::jsonb, true);

  RETURN jsonb_set(v_summary, '{purchase_vat_line_review}', v_review, true);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.apply_purchase_review_visible_bucket_filter_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  NEW.source_summary := public.filter_purchase_review_visible_buckets_to_sage_only_v1(NEW.source_summary);
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_apply_purchase_review_visible_bucket_filter_v1
ON public.vat_return_sage_reconstruction_snapshots;

CREATE TRIGGER trg_apply_purchase_review_visible_bucket_filter_v1
BEFORE INSERT OR UPDATE OF source_summary
ON public.vat_return_sage_reconstruction_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.apply_purchase_review_visible_bucket_filter_v1();

-- One-off repair existing snapshots.
UPDATE public.vat_return_sage_reconstruction_snapshots r
SET source_summary = public.filter_purchase_review_visible_buckets_to_sage_only_v1(r.source_summary)
WHERE r.source_summary #> '{purchase_vat_line_review,buckets}' IS NOT NULL;

REVOKE ALL ON FUNCTION public.filter_purchase_review_visible_buckets_to_sage_only_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.filter_purchase_review_visible_buckets_to_sage_only_v1(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.apply_purchase_review_visible_bucket_filter_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_purchase_review_visible_bucket_filter_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
