# VAT Test Run Sequence Exclusion Addendum v1

Status: governing implementation contract and non-regression authority

Date: 14 August 2026

## 1. Purpose

This addendum governs one narrow correction to the VAT Return Workbench sequence controls.

A historical VAT journal test run is intentionally retained for audit/testing evidence but must not block generation of the next monthly VAT test pack.

The affected run is exactly:

```text
id: 87b23d75-3729-4695-bef0-d8c5d34cdf06
run_ref: VAT-JOURNAL-TEST-65c54eaea6b24cc6a3a23d9657ac00cd
return_period_label: Journal adjustment test only
current status: sage_adjustment_journals_posted
```

Its notes/source metadata explicitly identify it as a manual test seed. It also contains a real Sage-posted test journal. Therefore this build must not delete it, supersede it, mark the journal reversed, fabricate Sage evidence or mutate its accounting status merely to unblock sequencing.

## 2. Governing rule

VAT sequencing and VAT accounting state are separate concerns.

A VAT run may be explicitly excluded from sequence eligibility while preserving its existing status, source lines, blockers, adjustment journals, Sage IDs, payloads and audit history.

Sequence exclusion is audit metadata only. It must not imply that the VAT run was submitted, matched, locked, superseded or reversed.

## 3. Locked implementation scope

The build contains exactly these changes:

1. add nullable sequence-exclusion metadata to `vat_return_runs`;
2. seed that metadata only for the exact historical journal-test run above, with identity guards;
3. update `enforce_vat_return_run_sequence_v1()` so sequence-excluded rows do not count as an existing open run;
4. update the server-side next-period detector so sequence-excluded rows do not block generation;
5. add read-only regression coverage proving the test run remains accounting-history intact while no longer blocking the next period.

## 4. Explicit non-regression rules

This build must not:

- change the status of the affected test run;
- change or delete Sage journal `6098fed5102947a38191e4767648f3ed`;
- change any VAT adjustment journal status;
- change April or May locked VAT runs;
- change expected VAT box calculations;
- change Sage journal payload construction or posting;
- change VAT submission evidence or lock logic;
- change VAT source-line calculation;
- change admin permissions, RLS or unrelated UI;
- edit already-deployed historical migrations.

April and May locked runs remain valid sequence anchors for the current testing dataset. With May as the latest locked monthly run, the existing next-period calculation must continue to derive June 2026 after the open journal-test run is excluded.

## 5. Data model

Add to `public.vat_return_runs`:

```text
sequence_excluded_at timestamptz null
sequence_excluded_reason text null
```

Invariant:

```text
sequence_excluded_at is null  => normal sequence participation
sequence_excluded_at is not null => ignored only by VAT run sequencing/open-run eligibility
```

The exclusion fields do not alter `status` and do not cascade to source lines, blockers or journals.

## 6. Historical seed guard

The migration may seed exclusion only when exactly one row matches all of:

```text
id = 87b23d75-3729-4695-bef0-d8c5d34cdf06
run_ref = VAT-JOURNAL-TEST-65c54eaea6b24cc6a3a23d9657ac00cd
return_period_label = Journal adjustment test only
status = sage_adjustment_journals_posted
period_start_date = 2026-05-01
period_end_date = 2026-05-31
```

It must also confirm the run has the known posted journal:

```text
id = bfcc0531-ecfd-4f23-b64a-c1c9e5f1ae55
sage_journal_id = 6098fed5102947a38191e4767648f3ed
status = posted_to_sage
```

If these facts do not match, the migration must fail rather than exclude another run.

## 7. Sequence behaviour

`enforce_vat_return_run_sequence_v1()` must continue all existing future/incomplete-period and open-run protections, except that rows with `sequence_excluded_at IS NOT NULL` are not considered open sequence blockers.

The application-level `detectNextEligibleMonthlyVatPeriod` check must apply the same exclusion rule.

The latest locked run lookup remains unchanged. Therefore locked April/May test packs continue to anchor the current monthly test sequence.

## 8. Acceptance criteria

The build is acceptable only when:

1. the exact historical journal-test run retains status `sage_adjustment_journals_posted`;
2. journal `bfcc0531-ecfd-4f23-b64a-c1c9e5f1ae55` retains status `posted_to_sage` and Sage ID `6098fed5102947a38191e4767648f3ed`;
3. the run has non-null sequence-exclusion metadata;
4. no other VAT run is sequence-excluded by this migration;
5. the application open-run detector ignores the excluded test run;
6. the database sequence trigger ignores the excluded test run;
7. latest locked May remains unchanged;
8. the next monthly period remains June 2026;
9. no VAT box, source line, blocker, journal, Sage payload or submission evidence is mutated by the exclusion operation.
