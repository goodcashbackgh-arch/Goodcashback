-- Manual expected tests for public.staff_pair_loyalty_funding_pot_and_release_v1 hardening.
-- Replace placeholder UUIDs with fixture rows in a migrated test database.
-- Preconditions for the positive fixture:
--   * MATCH_A and MATCH_B are confirmed source_out_reserved rows.
--   * They share one importer_id and one source OUT dva_statement_line_id.
--   * Their matched_gbp_amount values sum exactly to DEST_IN_EXACT.remaining_gbp within 0.01.
--   * DEST_IN_EXACT is an importer_dva_card_account IN line for the same importer.

-- A. Wrong importer IN must fail.
-- Expected: exception containing "Destination importer ... does not match loyalty importer".
-- SELECT public.staff_pair_loyalty_funding_pot_and_release_v1(
--   ARRAY['MATCH_A'::uuid, 'MATCH_B'::uuid],
--   'DEST_IN_OTHER_IMPORTER'::uuid,
--   'negative test: wrong importer'
-- );

-- B. Wrong amount IN must fail.
-- Expected: exception containing "must exactly equal selected loyalty pot total".
-- SELECT public.staff_pair_loyalty_funding_pot_and_release_v1(
--   ARRAY['MATCH_A'::uuid, 'MATCH_B'::uuid],
--   'DEST_IN_SAME_IMPORTER_WRONG_REMAINING_AMOUNT'::uuid,
--   'negative test: wrong amount'
-- );

-- C. Already released match must fail.
-- Expected: exception containing "is not an unpaired staged OUT row".
-- SELECT public.staff_pair_loyalty_funding_pot_and_release_v1(
--   ARRAY['MATCH_A'::uuid, 'MATCH_ALREADY_RELEASED'::uuid],
--   'DEST_IN_EXACT'::uuid,
--   'negative test: already released match'
-- );

-- D. Exact same-importer exact-amount IN must pass.
-- Expected: ok=true, bulk_release=true, released_count=2, released_total_gbp equals selected total.
-- SELECT public.staff_pair_loyalty_funding_pot_and_release_v1(
--   ARRAY['MATCH_A'::uuid, 'MATCH_B'::uuid],
--   'DEST_IN_EXACT'::uuid,
--   'positive test: exact same importer exact amount'
-- );
