BEGIN;

-- Clean historic VAT return labels created when Sage tax scheme object was stringified as [object Object].
-- This is display/data hygiene only; it does not change VAT amounts, source lines, blockers, journals or statuses.

UPDATE public.vat_return_runs
SET return_period_label = trim(
  regexp_replace(
    regexp_replace(return_period_label, '\\s*\\(\\[object Object\\]\\)', '', 'g'),
    '\\s*\\[object Object\\]',
    '',
    'g'
  )
)
WHERE return_period_label ILIKE '%[object Object]%';

NOTIFY pgrst, 'reload schema';

COMMIT;
