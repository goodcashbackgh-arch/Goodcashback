import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

type Props = {
  searchQuery?: string;
  previewStatusFilter?: string;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function configuredBadge(value: unknown) {
  const configured = value === true || text(value).toLowerCase() === "true";
  return configured ? "Configured" : "Not configured";
}

function debitConfigured(row: Row) {
  const mapping = asObject(row.mapping_status_json);
  const debit = asObject(mapping.debit_candidate);
  return debit.configured === true || text(debit.configured).toLowerCase() === "true";
}

function firstCreditCandidateStatus(value: unknown) {
  const json = asObject(value);
  const candidates = json.credit_candidates;
  if (!Array.isArray(candidates) || candidates.length === 0) return "Handled in Step 3 settlement mappings";
  const configured = candidates.filter((candidate) => asObject(candidate).configured === true).length;
  return configured > 0 ? `${configured} candidate configured` : "Handled in Step 3 settlement mappings";
}

function rowKey(row: Row) {
  return text(row.preview_row_id) || text(row.source_id) || `${text(row.order_ref)}-${text(row.amount_gbp)}`;
}

function statusLabel(status: string) {
  if (status === "blocked") return "Blocked from Step 3";
  if (status === "debit_mapping_configured") return "Expense mapping configured";
  if (status === "debit_mapping_missing") return "Expense mapping missing";
  return "All preview rows";
}

function legacyContractBlocker(value: unknown) {
  const raw = text(value).toLowerCase();
  return raw.includes("mapping endpoint idempotency logging and reversal contract not locked")
    || raw.includes("preview only mapping not confirmed");
}

function readinessLabel(row: Row) {
  const status = text(row.readiness_status);
  const blocker = text(row.blocker);
  if (legacyContractBlocker(status) || legacyContractBlocker(blocker) || status.startsWith("preview_only")) {
    return "Ready for Step 3 freeze when target invoice and mappings validate";
  }
  return pretty(status || "read only preview");
}

function visibleBlocker(row: Row) {
  const blocker = text(row.blocker);
  if (!blocker || legacyContractBlocker(blocker)) return "";
  return pretty(blocker);
}

function matchesPreviewStatus(row: Row, filter: string) {
  if (!filter || filter === "all") return true;
  if (filter === "blocked") return visibleBlocker(row) !== "";
  if (filter === "debit_mapping_configured") return debitConfigured(row);
  if (filter === "debit_mapping_missing") return !debitConfigured(row);
  return true;
}

export default async function CompletionLoyaltyAppliedAccountingPreviewPanel({ searchQuery = "", previewStatusFilter = "all" }: Props) {
  const supabase = await createClient();
  const cleanSearch = searchQuery.trim() || null;
  const { data, error } = await (supabase as any).rpc("internal_completion_loyalty_applied_accounting_preview_v1", {
    p_search: cleanSearch,
    p_limit: 300,
    p_offset: 0,
  });

  const allRows = ((data ?? []) as Row[]);
  const rows = allRows.filter((row) => matchesPreviewStatus(row, previewStatusFilter));
  const totalCount = rows.length;
  const totalAmount = rows.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const blockedCount = rows.filter((row) => visibleBlocker(row) !== "").length;

  return (
    <section id="step-2-eligibility" className="rounded-3xl border border-sky-200 bg-white p-5 shadow-sm scroll-mt-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-sky-500">Step 2 · Applied-loyalty eligibility preview</p>
          <h2 className="mt-2 text-xl font-semibold text-slate-950">Which applied loyalty rows can move to Step 3?</h2>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            This step only reads staff-applied completion loyalty from existing <code>credit_applied</code> order-funding events. It is the read-only eligibility view. Step 3 performs the controlled freeze, batch approval, Sage posting, and audit trail.
          </p>
        </div>
        <div className="rounded-2xl bg-sky-50 px-4 py-3 text-sm font-semibold text-sky-900 ring-1 ring-sky-200">
          {totalCount} shown · {gbp(totalAmount)}
        </div>
      </div>

      {(cleanSearch || previewStatusFilter !== "all") ? (
        <div className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700">
          Filtered by {cleanSearch ? <span className="font-semibold">search “{cleanSearch}”</span> : <span className="font-semibold">all search terms</span>}
          {previewStatusFilter !== "all" ? <> · preview status <span className="font-semibold">{statusLabel(previewStatusFilter)}</span></> : null}
        </div>
      ) : null}

      {error ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Applied loyalty accounting preview RPC unavailable: {error.message}. Run the applied-loyalty accounting preview migration before testing this section.
        </div>
      ) : null}

      <div className="mt-5 grid gap-3 sm:grid-cols-3">
        <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sky-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Applied loyalty amount</p>
          <p className="mt-2 text-2xl font-extrabold">{gbp(totalAmount)}</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Sourced only from completion-loyalty <code>credit_applied</code> events.</p>
        </div>
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-amber-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Blocked before Step 3</p>
          <p className="mt-2 text-2xl font-extrabold">{blockedCount}</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Only real current blockers are counted here; old contract-warning text is no longer treated as a live blocker.</p>
        </div>
        <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-emerald-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Posting route</p>
          <p className="mt-2 text-2xl font-extrabold">Step 3</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Receipt → allocation → clearing journal is controlled from the lifecycle batch lane.</p>
        </div>
      </div>

      <div className="mt-5 space-y-2 md:hidden">
        {rows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-center text-sm text-slate-500">
            No applied completion-loyalty accounting preview rows match the current filters.
          </div>
        ) : rows.map((row) => {
          const mapping = asObject(row.mapping_status_json);
          const debit = asObject(mapping.debit_candidate);
          const blocker = visibleBlocker(row);
          return (
            <details key={rowKey(row)} className="group rounded-2xl border border-slate-200 bg-white shadow-sm open:bg-slate-50">
              <summary className="flex cursor-pointer list-none items-start justify-between gap-3 p-3">
                <div className="min-w-0">
                  <p className="truncate font-bold text-slate-950">{text(row.order_ref) || "—"}</p>
                  <p className="mt-1 truncate text-xs text-slate-500">{text(row.importer_name) || "Importer/customer"}</p>
                  <p className="mt-2 text-[11px] font-semibold text-emerald-800">{readinessLabel(row)}</p>
                </div>
                <div className="shrink-0 text-right">
                  <p className="text-sm font-extrabold text-slate-950">{gbp(row.amount_gbp)}</p>
                  <p className="mt-1 text-[11px] font-semibold text-slate-500">Details ▾</p>
                </div>
              </summary>
              <div className="border-t border-slate-200 px-3 pb-3 pt-2 text-sm text-slate-700">
                <div className="rounded-2xl bg-white p-3">
                  <p className="font-semibold text-slate-950">Applied loyalty customer settlement</p>
                  <p className="mt-1 text-slate-500">Step 3 will freeze the non-cash receipt, customer allocation, and loyalty clearing journal.</p>
                </div>
                <div className="mt-3 grid gap-1">
                  <p><span className="font-semibold text-slate-950">Reward expense:</span> {configuredBadge(debit.configured)}</p>
                  <p><span className="font-semibold text-slate-950">Settlement mappings:</span> {firstCreditCandidateStatus(row.mapping_status_json)}</p>
                  <p><span className="font-semibold text-slate-950">Policy:</span> Step 3 lifecycle locked</p>
                </div>
                {blocker ? <p className="mt-3 font-semibold text-rose-700">{blocker}</p> : null}
                <div className="mt-3">
                  <span className="rounded-full border border-slate-200 bg-white px-2 py-1 text-[11px] font-bold text-slate-700">
                    Step 2 eligibility · read-only
                  </span>
                </div>
                <p className="mt-3 break-all text-[11px] text-slate-400">Event: {text(row.order_funding_event_id) || "—"}</p>
              </div>
            </details>
          );
        })}
      </div>

      <div className="mt-5 hidden overflow-x-auto rounded-2xl border border-slate-200 md:block">
        <table className="min-w-[1180px] divide-y divide-slate-200 text-xs">
          <thead className="bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2 text-left">Order / importer</th>
              <th className="px-3 py-2 text-right">Amount</th>
              <th className="px-3 py-2 text-left">Accounting preview</th>
              <th className="px-3 py-2 text-left">Mapping status</th>
              <th className="px-3 py-2 text-left">Readiness</th>
              <th className="px-3 py-2 text-left">Gate</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {rows.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-3 py-6 text-center text-sm text-slate-500">
                  No applied completion-loyalty accounting preview rows match the current filters.
                </td>
              </tr>
            ) : rows.map((row) => {
              const mapping = asObject(row.mapping_status_json);
              const debit = asObject(mapping.debit_candidate);
              const blocker = visibleBlocker(row);
              return (
                <tr key={rowKey(row)} className="align-top hover:bg-slate-50">
                  <td className="px-3 py-3">
                    <p className="font-bold text-slate-950">{text(row.order_ref) || "—"}</p>
                    <p className="mt-1 text-slate-500">{text(row.importer_name) || "Importer/customer"}</p>
                    <p className="mt-1 text-[11px] text-slate-400">Event: {text(row.order_funding_event_id) || "—"}</p>
                  </td>
                  <td className="px-3 py-3 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}</td>
                  <td className="px-3 py-3 text-slate-700">
                    <p className="font-semibold text-slate-950">Applied loyalty customer settlement</p>
                    <p className="mt-1 text-slate-500">Step 3 freezes the non-cash receipt, customer allocation, and loyalty clearing journal.</p>
                  </td>
                  <td className="px-3 py-3 text-slate-700">
                    <p><span className="font-semibold">Reward expense:</span> {configuredBadge(debit.configured)}</p>
                    <p className="mt-1"><span className="font-semibold">Settlement mappings:</span> {firstCreditCandidateStatus(row.mapping_status_json)}</p>
                    <p className="mt-1 text-slate-500">Policy: Step 3 lifecycle locked</p>
                  </td>
                  <td className="px-3 py-3 text-slate-700">
                    <p className="font-semibold text-emerald-800">{readinessLabel(row)}</p>
                    {blocker ? <p className="mt-1 text-rose-700">{blocker}</p> : null}
                  </td>
                  <td className="px-3 py-3">
                    <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-1 text-[11px] font-bold text-slate-700">
                      Step 2 eligibility · read-only
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
