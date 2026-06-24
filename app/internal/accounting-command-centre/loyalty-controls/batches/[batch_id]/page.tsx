import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveCompletionLoyaltySageBatchAction, postCompletionLoyaltySageBatchAction } from "../../actions";

type Row = Record<string, unknown>;
type Params = { batch_id: string } | Promise<{ batch_id: string }>;

type SearchParams = Record<string, string | string[] | undefined> | Promise<Record<string, string | string[] | undefined>>;

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const stepOrder = new Map([
  ["loyalty_customer_receipt", 1],
  ["loyalty_customer_allocation", 2],
  ["loyalty_clearing_offset", 3],
]);

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
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

function short(value: unknown, max = 44) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function orderedSteps(value: unknown) {
  return asArray(value).slice().sort((a, b) => {
    const left = asObject(a);
    const right = asObject(b);
    return (stepOrder.get(text(left.step_type)) ?? 99) - (stepOrder.get(text(right.step_type)) ?? 99);
  });
}

function messageParam(searchParams: Record<string, string | string[] | undefined>, key: "success" | "error") {
  return text(searchParams[key]);
}

function hasAccountingAccess(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

function badgeTone(status: string) {
  if (["blocked", "failed_terminal", "stale_reapproval_required", "invalidated", "cancelled", "superseded"].includes(status)) return "border-rose-200 bg-rose-50 text-rose-700";
  if (["approved", "admin_approved", "posted_to_sage", "ok_to_post"].includes(status)) return "border-emerald-200 bg-emerald-50 text-emerald-700";
  if (["partially_posted_needs_review", "warning_only", "posting_to_sage"].includes(status)) return "border-amber-200 bg-amber-50 text-amber-700";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function StatusBadge({ value }: { value: unknown }) {
  const raw = text(value) || "unknown";
  return <span className={`inline-flex rounded-full border px-2.5 py-1 text-[11px] font-bold ${badgeTone(raw)}`}>{pretty(raw)}</span>;
}

function PayloadBlock({ title, value }: { title: string; value: unknown }) {
  return (
    <details className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs">
      <summary className="cursor-pointer font-bold text-slate-900">{title}</summary>
      <pre className="mt-2 max-h-72 overflow-auto rounded-xl bg-white p-3 text-[11px] leading-5 text-slate-700">{JSON.stringify(value ?? {}, null, 2)}</pre>
    </details>
  );
}

export default async function CompletionLoyaltySageBatchDetailPage({ params, searchParams }: { params: Params; searchParams?: SearchParams }) {
  const resolvedParams = await Promise.resolve(params);
  const resolvedSearchParams = await Promise.resolve(searchParams ?? {});
  const batchId = resolvedParams.batch_id;
  const success = messageParam(resolvedSearchParams, "success");
  const pageError = messageParam(resolvedSearchParams, "error");

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  const canAccess = text(staff.role_type) === "admin" || hasAccountingAccess((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  const { data, error } = await (supabase as any).rpc("internal_completion_loyalty_sage_batch_detail_v1", { p_batch_id: batchId });
  const rows = (data ?? []) as Row[];
  const first = rows[0] ?? {};
  const canApprove = rows.length > 0
    && text(first.batch_status) === "validated"
    && text(first.batch_approval_status) !== "approved"
    && rows.every((row) => ["ok_to_post", "warning_only"].includes(text(row.group_validation_status)) && !text(row.blocker));
  const livePostingEnabled = process.env.SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED === "true" || process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true";
  const canPost = rows.length > 0 && livePostingEnabled && text(first.batch_status) === "approved" && text(first.batch_approval_status) === "approved";
  const postedRows = rows.filter((row) => text(row.item_posting_status) === "posted_to_sage").length;
  const failedRows = rows.filter((row) => ["failed_retryable", "failed_terminal"].includes(text(row.item_posting_status))).length;
  const blockedRows = rows.filter((row) => text(row.blocker) || text(row.group_validation_status).startsWith("blocked")).length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <Link href="/internal/accounting-command-centre/loyalty-controls#step-3-lifecycle" className="text-sm font-semibold text-sky-700">← Loyalty controls</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-emerald-600">Completion loyalty · Sage batch detail</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">{text(first.batch_ref) || "Loyalty Sage batch"}</h1>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            This batch wraps multiple materialised applied-loyalty Sage groups. Approval happens at batch level. Live posting uses the same Sage OAuth/logging infrastructure as the existing workbench and is controlled by the existing cash-posting live flag or the optional dedicated loyalty flag.
          </p>
          <div className="mt-3 flex flex-wrap gap-2 text-[11px] font-bold">
            <StatusBadge value={text(first.batch_status) || "not_loaded"} />
            <StatusBadge value={text(first.batch_validation_status) || "not_validated"} />
            <StatusBadge value={text(first.batch_approval_status) || "not_approved"} />
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">Live flag: {livePostingEnabled ? "enabled" : "disabled"}</span>
          </div>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {pageError ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{pageError}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Batch detail unavailable: {error.message}. Run the loyalty Sage batch migration.</p> : null}
        </section>

        {rows.length === 0 ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-5 text-sm text-slate-600 shadow-sm">
            No batch rows found for this batch id.
          </section>
        ) : (
          <>
            <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
              <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-emerald-900"><p className="text-[11px] font-bold uppercase tracking-wide opacity-70">Status</p><p className="mt-1 text-xl font-extrabold">{pretty(first.batch_status)}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Rows</p><p className="mt-1 text-xl font-extrabold">{text(first.batch_row_count)}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Total</p><p className="mt-1 text-xl font-extrabold">{gbp(first.batch_total_amount_gbp)}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Posted / failed</p><p className="mt-1 text-xl font-extrabold">{postedRows} / {failedRows}</p></div>
              <div className="rounded-2xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Blocked</p><p className="mt-1 text-xl font-extrabold">{blockedRows}</p></div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
              <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">Batch actions</h2>
                  <p className="mt-1 text-sm text-slate-500">Approve the whole batch first. The post button runs the live adapter only when a live Sage flag is enabled and the batch is approved.</p>
                </div>
                <div className="flex flex-wrap gap-2">
                  <form action={approveCompletionLoyaltySageBatchAction}>
                    <input type="hidden" name="batch_id" value={batchId} />
                    <input type="hidden" name="approval_notes" value="Approved from completion loyalty Sage batch detail." />
                    <button type="submit" disabled={!canApprove} className="rounded-xl bg-emerald-700 px-4 py-2 text-xs font-bold text-white hover:bg-emerald-800 disabled:bg-slate-200 disabled:text-slate-500">
                      Approve batch
                    </button>
                  </form>
                  <form action={postCompletionLoyaltySageBatchAction}>
                    <input type="hidden" name="batch_id" value={batchId} />
                    <button disabled={!canPost} className="rounded-xl bg-emerald-700 px-4 py-2 text-xs font-bold text-white hover:bg-emerald-800 disabled:bg-slate-200 disabled:text-slate-500">
                      Post loyalty Sage batch
                    </button>
                  </form>
                </div>
              </div>
              {!livePostingEnabled ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-xs font-semibold text-amber-900">Live posting is disabled. Use the already-approved SAGE_LIVE_CASH_POSTING_ENABLED=true environment switch, or set SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED=true for a dedicated loyalty switch.</p> : null}
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
              <div className="border-b border-slate-100 px-4 py-3">
                <h2 className="text-xl font-semibold">Batch rows</h2>
                <p className="mt-1 text-sm text-slate-500">Each row is one applied-loyalty Sage posting group. The live adapter executes receipt → allocation → journal per group and retries failed steps only.</p>
              </div>
              <div className="overflow-x-auto">
                <table className="min-w-[1320px] divide-y divide-slate-200 text-xs">
                  <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2 text-left">Status</th>
                      <th className="px-3 py-2 text-left">Group</th>
                      <th className="px-3 py-2 text-left">Order</th>
                      <th className="px-3 py-2 text-left">Importer</th>
                      <th className="px-3 py-2 text-right">Amount</th>
                      <th className="px-3 py-2 text-left">Target allocation</th>
                      <th className="px-3 py-2 text-left">Steps</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100 bg-white">
                    {rows.map((row) => {
                      const targets = asArray(row.target_allocation_json);
                      const steps = orderedSteps(row.steps_json);
                      return (
                        <tr key={text(row.item_id)} className="align-top">
                          <td className="px-3 py-3"><StatusBadge value={row.item_posting_status} /><p className="mt-1"><StatusBadge value={row.group_validation_status} /></p>{text(row.blocker) ? <p className="mt-1 text-[11px] font-semibold text-rose-700">{short(row.blocker, 90)}</p> : null}</td>
                          <td className="px-3 py-3 font-mono text-[11px] font-bold">{short(row.posting_group_ref, 34)}</td>
                          <td className="px-3 py-3 font-mono text-[11px] font-bold">{short(row.order_ref, 32)}</td>
                          <td className="px-3 py-3 font-bold">{short(row.importer_name, 36)}</td>
                          <td className="px-3 py-3 text-right font-bold">{gbp(row.amount_gbp)}</td>
                          <td className="px-3 py-3">
                            {targets.length === 0 ? <span className="text-slate-400">—</span> : targets.map((target, index) => {
                              const targetObj = asObject(target);
                              return <p key={`${text(row.item_id)}-${index}`} className="font-mono text-[11px]">{short(targetObj.target_sage_invoice_id, 34)} · {gbp(targetObj.allocation_amount_gbp)}</p>;
                            })}
                          </td>
                          <td className="px-3 py-3">
                            <div className="grid gap-1">
                              {steps.map((step, index) => {
                                const stepObj = asObject(step);
                                return <p key={`${text(row.item_id)}-step-${index}`}><span className="font-bold">{pretty(stepObj.step_type)}</span> · <StatusBadge value={stepObj.status} /></p>;
                              })}
                            </div>
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </section>

            <section className="grid gap-3 lg:grid-cols-2">
              {rows.map((row) => orderedSteps(row.steps_json).map((step, index) => {
                const stepObj = asObject(step);
                return <PayloadBlock key={`${text(row.item_id)}-${index}-payload`} title={`${pretty(stepObj.step_type)} · request payload`} value={stepObj.request_payload} />;
              }))}
              {rows.map((row) => orderedSteps(row.steps_json).map((step, index) => {
                const stepObj = asObject(step);
                return <PayloadBlock key={`${text(row.item_id)}-${index}-response`} title={`${pretty(stepObj.step_type)} · Sage response`} value={stepObj.response_payload} />;
              }))}
            </section>
          </>
        )}
      </div>
    </main>
  );
}
