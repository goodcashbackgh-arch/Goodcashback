import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

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

function firstCreditCandidateStatus(value: unknown) {
  const json = asObject(value);
  const candidates = json.credit_candidates;
  if (!Array.isArray(candidates) || candidates.length === 0) return "Credit mapping not locked";
  const configured = candidates.filter((candidate) => asObject(candidate).configured === true).length;
  return configured > 0 ? `${configured} candidate configured` : "No credit candidate configured";
}

function rowKey(row: Row) {
  return text(row.preview_row_id) || text(row.source_id) || `${text(row.order_ref)}-${text(row.amount_gbp)}`;
}

export default async function CompletionLoyaltyAppliedAccountingPreviewPanel() {
  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("internal_completion_loyalty_applied_accounting_preview_v1", {
    p_search: null,
    p_limit: 50,
    p_offset: 0,
  });

  const rows = ((data ?? []) as Row[]);
  const totalCount = rows.length > 0 ? Number(rows[0].total_count ?? rows.length) : 0;
  const totalAmount = rows.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const blockedCount = rows.filter((row) => text(row.readiness_status).startsWith("preview_only") || text(row.blocker)).length;

  return (
    <section className="rounded-3xl border border-sky-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-sky-500">Applied loyalty accounting / Sage mapping preview</p>
          <h2 className="mt-2 text-xl font-semibold text-slate-950">Applied completion-loyalty preview</h2>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            This section reads staff-applied completion loyalty from existing <code>credit_applied</code> order-funding events. It is preview only: no Sage posting, no cash freeze, no VAT source row, no credit unlock, and no queue posting is enabled here.
          </p>
        </div>
        <div className="rounded-2xl bg-sky-50 px-4 py-3 text-sm font-semibold text-sky-900 ring-1 ring-sky-200">
          {totalCount} preview rows · {gbp(totalAmount)}
        </div>
      </div>

      {error ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Applied loyalty accounting preview RPC unavailable: {error.message}. Run the 23/06 applied-loyalty accounting preview migration before testing this section.
        </div>
      ) : null}

      <div className="mt-5 grid gap-3 sm:grid-cols-3">
        <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sky-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Applied loyalty amount</p>
          <p className="mt-2 text-2xl font-extrabold">{gbp(totalAmount)}</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Sourced only from completion-loyalty <code>credit_applied</code> events.</p>
        </div>
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-amber-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Preview blocked from posting</p>
          <p className="mt-2 text-2xl font-extrabold">{blockedCount}</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Mappings, endpoint, idempotency, logging, reversal, and feature flag are not locked here.</p>
        </div>
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-slate-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Posting gate</p>
          <p className="mt-2 text-2xl font-extrabold">Off</p>
          <p className="mt-1 text-xs leading-5 opacity-80">Rows are non-selectable and non-postable by contract.</p>
        </div>
      </div>

      <div className="mt-5 space-y-3 md:hidden">
        {rows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-center text-sm text-slate-500">
            No applied completion-loyalty accounting preview rows are currently visible.
          </div>
        ) : rows.map((row) => {
          const mapping = asObject(row.mapping_status_json);
          const debit = asObject(mapping.debit_candidate);
          return (
            <article key={rowKey(row)} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <p className="font-bold text-slate-950">{text(row.order_ref) || "—"}</p>
                  <p className="mt-1 text-sm text-slate-500">{text(row.importer_name) || "Importer/customer"}</p>
                </div>
                <span className="text-sm font-extrabold text-slate-950">{gbp(row.amount_gbp)}</span>
              </div>

              <div className="mt-3 rounded-2xl bg-slate-50 p-3 text-sm text-slate-700">
                <p className="font-semibold text-slate-950">Dr loyalty cost / reward expense</p>
                <p className="mt-1 font-semibold text-slate-950">Cr customer account / receivable</p>
                <p className="mt-1 text-slate-500">Non-cash loyalty settlement of customer balance.</p>
              </div>

              <div className="mt-3 grid gap-2 text-sm text-slate-700">
                <div><span className="font-semibold text-slate-950">Debit mapping:</span> {configuredBadge(debit.configured)}</div>
                <div><span className="font-semibold text-slate-950">Credit mapping:</span> {firstCreditCandidateStatus(row.mapping_status_json)}</div>
                <div><span className="font-semibold text-slate-950">Policy:</span> {pretty(mapping.mapping_policy_status)}</div>
              </div>

              <div className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm">
                <p className="font-semibold text-amber-800">{pretty(row.readiness_status)}</p>
                <p className="mt-1 text-rose-700">{pretty(row.blocker)}</p>
              </div>

              <div className="mt-3">
                <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-1 text-[11px] font-bold text-slate-700">
                  Read-only · not selectable · no posting
                </span>
              </div>
              <p className="mt-3 break-all text-[11px] text-slate-400">Event: {text(row.order_funding_event_id) || "—"}</p>
            </article>
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
              <th className="px-3 py-2 text-left">Posting gate</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {rows.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-3 py-6 text-center text-sm text-slate-500">
                  No applied completion-loyalty accounting preview rows are currently visible.
                </td>
              </tr>
            ) : rows.map((row) => {
              const mapping = asObject(row.mapping_status_json);
              const debit = asObject(mapping.debit_candidate);
              return (
                <tr key={rowKey(row)} className="align-top hover:bg-slate-50">
                  <td className="px-3 py-3">
                    <p className="font-bold text-slate-950">{text(row.order_ref) || "—"}</p>
                    <p className="mt-1 text-slate-500">{text(row.importer_name) || "Importer/customer"}</p>
                    <p className="mt-1 text-[11px] text-slate-400">Event: {text(row.order_funding_event_id) || "—"}</p>
                  </td>
                  <td className="px-3 py-3 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}</td>
                  <td className="px-3 py-3 text-slate-700">
                    <p className="font-semibold text-slate-950">Dr loyalty cost / reward expense</p>
                    <p className="mt-1 font-semibold text-slate-950">Cr customer account / receivable</p>
                    <p className="mt-1 text-slate-500">Non-cash loyalty settlement of customer balance.</p>
                  </td>
                  <td className="px-3 py-3 text-slate-700">
                    <p><span className="font-semibold">Debit:</span> {configuredBadge(debit.configured)}</p>
                    <p className="mt-1"><span className="font-semibold">Credit:</span> {firstCreditCandidateStatus(row.mapping_status_json)}</p>
                    <p className="mt-1 text-slate-500">Policy: {pretty(mapping.mapping_policy_status)}</p>
                  </td>
                  <td className="px-3 py-3 text-slate-700">
                    <p className="font-semibold text-amber-800">{pretty(row.readiness_status)}</p>
                    <p className="mt-1 text-rose-700">{pretty(row.blocker)}</p>
                  </td>
                  <td className="px-3 py-3">
                    <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-1 text-[11px] font-bold text-slate-700">
                      Read-only · not selectable · no posting
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
