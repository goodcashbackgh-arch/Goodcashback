# Final locked backend pack v4 — Day 2 to Day 9, clarified v3

Use only these files, in this order:

1. `goodcashback-complete.v4.sql`
2. `closure_v2_migration_v2.sql`
3. `closure_v2_functions_final_day6_8_clarified.sql`
4. `closure_v2_seed.sql`
5. `day2_to_day9_final_regression_v5.sql`

Important correction in v3:

- Regression v5 fixes the false Day 9 hardening check that looked for Box 1 / Box 6 adjustment strings in `post_to_vat_return_workings(uuid)`.
- In the final SQL, `post_to_vat_return_workings(uuid)` is only a wrapper.
- The real adjustment logic lives in `post_to_vat_return_workings_for_period(varchar, uuid)`.

Do not use older combined regression files.
