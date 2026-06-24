import { createClient } from "@/utils/supabase/server";
import { materialiseAppliedLoyaltySettlementAction } from "./loyalty-controls/actions";

type Row = Record<string, unknown>;

type Props = {
  searchQuery?: string;
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

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function rowKey(row: Row) {
  return text(row.order_funding_event_id) || text(row.source_id) || `${text(row.order_ref)}-${text(row.amount_gbp)}`;
}

function groupKey(row: Row) {
  return text(row.posting_group_id) || text(row.posting_group_ref) || `${text(row.order_ref)}-${text(row.amount_gbp)}`;
}

export default async function CompletionLoyaltySagePostingMaterialisationPanel({ searchQuery = "" }: Props) {
  const supabase = await createClient();
  const cleanSearch = searchQuery.trim() || null;

  const [{ data: previewData, error: previewError }, { data: groupData, error: groupError }] = await Promise.all([
    (supabase as any).rpc("internal_completion_loyalty_applied_accounting_preview_v1", {
      p_search: cleanSearch,
      p_limit: 300,
      p_offset: 0,
    }),
    (supabase as any).rpc("internal_completion_loyalty_sage_posting_groups_v1", {
      p_search: cleanSearch,
      p_status: "all",
      p_limit: 300,
      p_offset: 0,
    }),
  ]);

  const groups = ((groupData ?? []) as Row[]).filter((row) => text(row.posting_group_type) === "completion_loyalty_applied_settlement");
  const groupedEventIds = new Set(groups.map((row) => text(row.order_funding_event_id)).filter(Boolean));
  const previews = ((previewData ?? []) as Row[]).filter((row) => !groupedEventIds.has(text(row.order_funding_event_id)));
  const totalPreviewAmount = previews.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const totalGroupAmount = groups.reduce((sum, row) => sum + num(row.amount_gbp), 0);

  return (
    <section className="rounded-3xl border border-emerald-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-emerald-600">Applied loyalty Sage posting build</p>
          <h2 className="mt-2 text-xl font-semibold text-slate-950">Materialise applied-loyalty posting groups</h2>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            This is the first build step after the contract: it creates dedicated completion-loyalty posting groups and local Sage payload steps. It does not call Sage, approve posting, or touch VAT rows.
          </p>
        </div>
        <div className="rounded-2xl bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-950 ring-1 ring-emerald-200">
          {previews.length} new candidates · {gbp(totalPreviewAmount)}<br />
          {groups.length} groups · {gbp(totalGroupAmount)}
        </div>
      </div>

      {previewError ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Applied-loyalty preview RPC unavailable: {previewError.message}
        </div>
      ) : null}
      {groupError ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Posting group RPC unavailable: {groupError.message}. Run the completion-loyalty Sage posting phase 1 migration before using this section.
        </div>
      ) : null}

      <div className="mt-5 grid gap-4 xl:grid-cols-2">
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <h3 className="font-bold text-slate-950">Candidates not yet materialised</h3>
          <p className="mt-1 text-xs leading-5 text-slate-500">Creates a local posting group. Blocked candidates are stored as blocked groups with their blocker; valid candidates get receipt/allocation/clearing steps.</p>
          <div className="mt-4 space-y-2">
            {previews.length === 0 ? (
              <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-500">No unapplied candidates match the current filters.</div>
            ) : previews.map((row) => (
              <div key={rowKey(row)} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="font-bold text-slate-950">{text(row.order_ref) || "—"}</p>
                    <p className="mt-1 text-sm text-slate-500">{text(row.importer_name) || "Importer/customer"}</p>
                    <p className="mt-2 text-xs text-slate-400">Event: {text(row.order_funding_event_id) || "—"}</p>
                  </div>
                  <p className="text-lg font-extrabold text-slate-950">{gbp(row.amount_gbp)}</p>
                </div>
                <form action={materialiseAppliedLoyaltySettlementAction} className="mt-3 grid gap-2 sm:grid-cols-[1fr_auto]">
                  <input type="hidden" name="order_funding_event_id" value={text(row.order_funding_event_id)} />
                  <input
                    name="notes"
                    placeholder="Optional materialisation note"
                    className="rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950 outline-none focus:border-emerald-300 focus:ring-2 focus:ring-emerald-100"
                  />
                  <button type="submit" className="rounded-2xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white shadow-sm hover:bg-emerald-800">
                    Create group
                  </button>
                </form>
              </div>
            ))}
          </div>
        </div>

        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <h3 className="font-bold text-slate-950">Materialised posting groups</h3>
          <p className="mt-1 text-xs leading-5 text-slate-500">These are local controlled groups only. Live posting remains separate and feature-gated.</p>
          <div className="mt-4 space-y-2">
            {groups.length === 0 ? (
              <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-500">No materialised applied-loyalty posting groups yet.</div>
            ) : groups.map((group) => {
              const targets = asArray(group.target_allocation_json);
              return (
                <details key={groupKey(group)} className="group rounded-2xl border border-slate-200 bg-white p-4 shadow-sm open:bg-slate-50">
                  <summary className="flex cursor-pointer list-none items-start justify-between gap-3">
                    <div>
                      <p className="font-bold text-slate-950">{text(group.posting_group_ref) || "—"}</p>
                      <p className="mt-1 text-sm text-slate-500">{text(group.order_ref) || "—"} · {text(group.importer_name) || "Importer/customer"}</p>
                      <p className={`mt-2 text-xs font-bold ${text(group.status) === "blocked" ? "text-rose-700" : "text-emerald-700"}`}>{pretty(group.status)}</p>
                    </div>
                    <div className="text-right">
                      <p className="text-lg font-extrabold text-slate-950">{gbp(group.amount_gbp)}</p>
                      <p className="mt-1 text-[11px] font-semibold text-slate-500">{text(group.step_count)} step(s)</p>
                    </div>
                  </summary>
                  <div className="mt-3 border-t border-slate-200 pt-3 text-sm text-slate-700">
                    {text(group.blocker) ? <p className="font-semibold text-rose-700">Blocker: {pretty(group.blocker)}</p> : null}
                    <p className="mt-2 text-xs text-slate-500">Posting date: {text(group.posting_date) || "—"}</p>
                    <p className="mt-2 text-xs font-semibold text-slate-600">Target customer invoice allocation(s):</p>
                    <ul className="mt-1 space-y-1 text-xs text-slate-500">
                      {targets.length === 0 ? <li>—</li> : targets.map((target, index) => {
                        const targetObj = target && typeof target === "object" && !Array.isArray(target) ? target as Row : {};
                        return (
                          <li key={`${text(targetObj.target_sage_invoice_id)}-${index}`}>
                            {text(targetObj.target_sage_invoice_id) || "Sage invoice"}: {gbp(targetObj.allocation_amount_gbp)}
                          </li>
                        );
                      })}
                    </ul>
                  </div>
                </details>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
