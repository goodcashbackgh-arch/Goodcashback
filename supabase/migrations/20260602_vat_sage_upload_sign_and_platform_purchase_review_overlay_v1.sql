BEGIN;

-- Surgical overlay only.
-- 1) Imported Sage draft totals are normalised to HMRC/Sage box convention:
--    Box 3 = Box 1 + Box 2; Box 5 = Box 3 - Box 4.
-- 2) Platform-controlled Sage purchase lines are not treated as overhead/review just
--    because they are zero-rated/exempt/no-VAT/non-20%.
-- Does not touch vat_return_run_lines, VAT source generation, evidence breach rules,
-- prepayment/no-invoice timing, journal validation, approval, or Sage posting.

CREATE OR REPLACE FUNCTION public.normalise_purchase_vat_review_platform_controlled_first_v1(
  p_source_summary jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
  v_summary jsonb := COALESCE(p_source_summary, '{}'::jsonb);
  v_review jsonb := v_summary #> '{purchase_vat_line_review}';
  v_sample jsonb := COALESCE(v_review -> 'review_sample', '[]'::jsonb);
  v_new_sample jsonb := '[]'::jsonb;
  v_buckets jsonb := COALESCE(v_review -> 'buckets', '{}'::jsonb);
  v_line jsonb;
  v_bucket text;
  v_target_bucket text := 'platform_controlled_zero_exempt_or_non_standard';
  v_old jsonb;
  v_target jsonb;
  v_box4 numeric;
  v_box7 numeric;
  v_moved_count integer := 0;
  v_moved_box4 numeric := 0;
  v_moved_box7 numeric := 0;
  v_review_count integer;
BEGIN
  IF v_review IS NULL OR jsonb_typeof(v_review) <> 'object' THEN
    RETURN v_summary;
  END IF;

  IF jsonb_typeof(v_sample) <> 'array' THEN
    RETURN v_summary;
  END IF;

  FOR v_line IN SELECT value FROM jsonb_array_elements(v_sample)
  LOOP
    v_bucket := COALESCE(v_line ->> 'bucket', '');

    IF COALESCE((v_line ->> 'platform_controlled')::boolean, false)
       AND v_bucket LIKE 'review\_%'
    THEN
      v_box4 := COALESCE(NULLIF(v_line ->> 'effective_box4_amount', '')::numeric, 0);
      v_box7 := COALESCE(NULLIF(v_line ->> 'effective_box7_amount', '')::numeric, 0);

      v_moved_count := v_moved_count + 1;
      v_moved_box4 := v_moved_box4 + v_box4;
      v_moved_box7 := v_moved_box7 + v_box7;

      v_old := COALESCE(v_buckets -> v_bucket, '{"count":0,"box4":0,"box7":0}'::jsonb);
      v_old := jsonb_build_object(
        'count', GREATEST(COALESCE(NULLIF(v_old ->> 'count', '')::integer, 0) - 1, 0),
        'box4', round((COALESCE(NULLIF(v_old ->> 'box4', '')::numeric, 0) - v_box4)::numeric, 2),
        'box7', round((COALESCE(NULLIF(v_old ->> 'box7', '')::numeric, 0) - v_box7)::numeric, 2)
      );

      IF COALESCE(NULLIF(v_old ->> 'count', '')::integer, 0) = 0
         AND COALESCE(NULLIF(v_old ->> 'box4', '')::numeric, 0) = 0
         AND COALESCE(NULLIF(v_old ->> 'box7', '')::numeric, 0) = 0
      THEN
        v_buckets := v_buckets - v_bucket;
      ELSE
        v_buckets := jsonb_set(v_buckets, ARRAY[v_bucket], v_old, true);
      END IF;
    ELSE
      v_new_sample := v_new_sample || jsonb_build_array(v_line);
    END IF;
  END LOOP;

  IF v_moved_count = 0 THEN
    RETURN v_summary;
  END IF;

  v_target := COALESCE(v_buckets -> v_target_bucket, '{"count":0,"box4":0,"box7":0}'::jsonb);
  v_target := jsonb_build_object(
    'count', COALESCE(NULLIF(v_target ->> 'count', '')::integer, 0) + v_moved_count,
    'box4', round((COALESCE(NULLIF(v_target ->> 'box4', '')::numeric, 0) + v_moved_box4)::numeric, 2),
    'box7', round((COALESCE(NULLIF(v_target ->> 'box7', '')::numeric, 0) + v_moved_box7)::numeric, 2)
  );
  v_buckets := jsonb_set(v_buckets, ARRAY[v_target_bucket], v_target, true);

  v_review_count := GREATEST(COALESCE(NULLIF(v_review ->> 'review_line_count', '')::integer, 0) - v_moved_count, 0);

  v_review := jsonb_set(v_review, '{buckets}', v_buckets, true);
  v_review := jsonb_set(v_review, '{review_sample}', v_new_sample, true);
  v_review := jsonb_set(v_review, '{review_line_count}', to_jsonb(v_review_count), true);
  v_review := jsonb_set(v_review, '{platform_controlled_first_overlay}', 'true'::jsonb, true);

  RETURN jsonb_set(v_summary, '{purchase_vat_line_review}', v_review, true);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.normalise_sage_draft_import_sign_convention_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_box1 numeric := COALESCE(NEW.box1_gbp, 0);
  v_box2 numeric := COALESCE(NEW.box2_gbp, 0);
  v_box4 numeric := COALESCE(NEW.box4_gbp, 0);
  v_box3 numeric;
  v_box5 numeric;
BEGIN
  IF COALESCE(NEW.source_basis, '') LIKE 'sage_draft_vat_return_totals_import%' THEN
    v_box3 := round((v_box1 + v_box2)::numeric, 2);
    v_box5 := round((v_box3 - v_box4)::numeric, 2);

    NEW.box2_gbp := COALESCE(NEW.box2_gbp, 0);
    NEW.box3_gbp := v_box3;
    NEW.box5_gbp := v_box5;
    NEW.box8_gbp := COALESCE(NEW.box8_gbp, 0);
    NEW.box9_gbp := COALESCE(NEW.box9_gbp, 0);

    NEW.source_summary := jsonb_set(
      COALESCE(NEW.source_summary, '{}'::jsonb),
      '{final_boxes}',
      jsonb_build_object(
        '1', NEW.box1_gbp,
        '2', NEW.box2_gbp,
        '3', NEW.box3_gbp,
        '4', NEW.box4_gbp,
        '5', NEW.box5_gbp,
        '6', NEW.box6_gbp,
        '7', NEW.box7_gbp,
        '8', NEW.box8_gbp,
        '9', NEW.box9_gbp,
        'sign_convention', 'hmrc_box5_equals_box3_minus_box4'
      ),
      true
    );
  END IF;

  NEW.source_summary := public.normalise_purchase_vat_review_platform_controlled_first_v1(NEW.source_summary);

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_normalise_sage_draft_import_sign_convention_v1
ON public.vat_return_sage_reconstruction_snapshots;

CREATE TRIGGER trg_normalise_sage_draft_import_sign_convention_v1
BEFORE INSERT OR UPDATE OF source_basis, box1_gbp, box2_gbp, box3_gbp, box4_gbp, box5_gbp, box8_gbp, box9_gbp, source_summary
ON public.vat_return_sage_reconstruction_snapshots
FOR EACH ROW
EXECUTE FUNCTION public.normalise_sage_draft_import_sign_convention_v1();

-- One-off repair existing imported draft snapshots.
UPDATE public.vat_return_sage_reconstruction_snapshots r
SET box2_gbp = COALESCE(r.box2_gbp, 0),
    box3_gbp = round((COALESCE(r.box1_gbp, 0) + COALESCE(r.box2_gbp, 0))::numeric, 2),
    box5_gbp = round(((COALESCE(r.box1_gbp, 0) + COALESCE(r.box2_gbp, 0)) - COALESCE(r.box4_gbp, 0))::numeric, 2),
    box8_gbp = COALESCE(r.box8_gbp, 0),
    box9_gbp = COALESCE(r.box9_gbp, 0),
    source_summary = jsonb_set(
      public.normalise_purchase_vat_review_platform_controlled_first_v1(COALESCE(r.source_summary, '{}'::jsonb)),
      '{final_boxes}',
      jsonb_build_object(
        '1', r.box1_gbp,
        '2', COALESCE(r.box2_gbp, 0),
        '3', round((COALESCE(r.box1_gbp, 0) + COALESCE(r.box2_gbp, 0))::numeric, 2),
        '4', r.box4_gbp,
        '5', round(((COALESCE(r.box1_gbp, 0) + COALESCE(r.box2_gbp, 0)) - COALESCE(r.box4_gbp, 0))::numeric, 2),
        '6', r.box6_gbp,
        '7', r.box7_gbp,
        '8', COALESCE(r.box8_gbp, 0),
        '9', COALESCE(r.box9_gbp, 0),
        'sign_convention', 'hmrc_box5_equals_box3_minus_box4'
      ),
      true
    )
WHERE COALESCE(r.source_basis, '') LIKE 'sage_draft_vat_return_totals_import%';

-- One-off repair diagnostic snapshots / copied purchase reviews too.
UPDATE public.vat_return_sage_reconstruction_snapshots r
SET source_summary = public.normalise_purchase_vat_review_platform_controlled_first_v1(r.source_summary)
WHERE r.source_summary #> '{purchase_vat_line_review}' IS NOT NULL;

REVOKE ALL ON FUNCTION public.normalise_purchase_vat_review_platform_controlled_first_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.normalise_purchase_vat_review_platform_controlled_first_v1(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION public.normalise_sage_draft_import_sign_convention_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.normalise_sage_draft_import_sign_convention_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
