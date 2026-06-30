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
  ["loyalty_internal_transfer_journal", 1],
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

function firstStep(row: Row) {
  return asObject(orderedSteps(row.steps_json)[0]);
}

function stepPayload(step: Row) {
  return asObject(step.request_payload);
}

function journalLines(row: Row) {
  const payload = stepPayload(firstStep(row));
  const journal = asObject(payload.journal);
  return asArray(journal.journal_lines).map(asObject);
}

function journalLineLabel(line: Row) {
  return short(line.details || line.ledger_account_id, 58);
}

function debitJournalLine(row: Row) {
  return journalLines(row).find((line) => num(line.debit) > 0) ?? {};
}

function creditJournalLine(row: Row) {
  return journalLines(row).find((line) => num(line.credit) > 0) ?? {};
}

function journalSummary(row: Row) {
  const debit = debitJournalLine(row);
  const credit = creditJournalLine(row);
  const debitText = journalLineLabel(debit);
  const creditText = journalLineLabel(credit);
  if (debitText === "—" && creditText === "—") return "Dr wallet · Cr main bank";
  return `Dr ${debitText} · Cr ${creditText}`;
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

function SummaryChip({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white px-3 py-2">
      <p className="text-[10px] font-bold uppercase tracking-wide text-slate-500">{label}</p>
      <p className="mt-1 text-sm font-extrabold text-slate-950">{value}</p>
    </div>
  );
}

function BatchRowCard({ row, isInternalTransfer }: { row: Row; isInternalTransfer: boolean }) {
  const targets = asArray(row.target_allocation_json);
  const steps = orderedSteps(row.steps_json);
  return (
    <article className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-xs font-bold uppercase tracking-wide text-slate-500">{isInternalTransfer ? "Journal group" : "Order"}</p>
          <p className="mt-1 break-all font-mono text-sm font-extrabold text-slate-950">{short(isInternalTransfer ? row.posting_group_ref : row.order_ref, 42)}</p>
          <p className="mt-1 text-sm font-semibold text-slate-700">{short(row.importer_name, 52)}</p>
        </div>
        <p className="rounded-xl bg-slate-50 px-3 py-2 text-lg font-extrabold text-slate-950">{gbp(row.amount_gbp)}</p>
      </div>

      <div className="mt-3 flex flex-wrap gap-2">
        <StatusBadge value={row.item_posting_status} />
        <StatusBadge value={row.group_validation_status} />
      </div>
      {text(row.blocker) ? <p className="mt-2 rounded-xl border border-rose-200 bg-rose-50 p-2 text-xs font-semibold text-rose-700">{short(row.blocker, 120)}</p> : null}

      {isInternalTransfer ? (
        <div className="mt-4 rounded-xl border border-slate-100 bg-slate-50 p-3">
          <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Journal</p>
          <p className="mt-1 text-xs font-semibold text-slate-700">{journalSummary(row)}</p>
          <p className="mt-2 text-[11px] font-bold text-slate-500">Endpoint: {text(firstStep(row).endpoint_path) || "/journals"}</p>
        </div>
      ) : (
        <div className="mt-4 rounded-xl border border-slate-100 bg-slate-50 p-3">
          <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Target allocation</p>
          <div className="mt-2 grid gap-1">
            {targets.length === 0 ? <span className="text-xs text-slate-400">—</span> : targets.map((target, index) => {
              const targetObj = asObject(target);
              return <p key={`${text(row.item_id)}-mobile-target-${index}`} className="break-all font-mono text-[11px] text-slate-700">{short(targetObj.target_sage_invoice_id, 44)} · {gbp(targetObj.allocation_amount_gbp)}</p>;
            })}
          </div>
        </div>
      )}

      <details className="mt-3 rounded-xl border border-slate-100 bg-slate-50 p-3">
        <summary className="cursor-pointer text-xs font-bold uppercase tracking-wide text-slate-500">Steps / audit</summary>
        <div className="mt-2 grid gap-2">
          {steps.map((step, index) => {
            const stepObj = asObject(step);
            return <div key={`${text(row.item_id)}-mobile-step-${index}`} className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-white px-2 py-1.5"><span className="text-xs font-bold text-slate-900">{pretty(stepObj.step_type)}</span><StatusBadge value={stepObj.status} /></div>;
          })}
        </div>
      </details>
    </article>
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
  const batchStatus = text(first.batch_status);
  const batchType = text(first.batch_type);
  const isInternalTransfer = batchType === "completion_loyalty_internal_transfer_journal";
  const isRetryBatch = ["failed_retryable", "partially_posted_needs_review"].includes(batchStatus);
  const canApprove = rows.length > 0
    && batchStatus === "validated"
    && text(first.batch_approval_status) !== "approved"
    && rows.every((row) => ["ok_to_post", "warning_only"].includes(text(row.group_validation_status)) && !text(row.blocker));
  const livePostingEnabled = isInternalTransfer
    ? process.env.SAGE_LIVE_BANK_GL_POSTING_ENABLED === "true"
    : process.env.SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED === "true" || process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true";
  const canPost = rows.length > 0
    && livePostingEnabled
    && text(first.batch_approval_status) === "approved"
    && ["approved", "failed_retryable", "partially_posted_needs_review"].includes(batchStatus);
  const postButtonLabel = isRetryBatch ? "Retry failed / remaining steps" : isInternalTransfer ? "Post Sage journal batch" : "Post applied-loyalty Sage batch";
  const postedRows = rows.filter((row) => text(row.item_posting_status) === "posted_to_sage").length;
  const failedRows = rows.filter((row) => ["failed_retryable", "failed_terminal"].includes(text(row.item_posting_status))).length;
  const reviewRows = rows.filter((row) => text(row.item_posting_status) === "partially_posted_needs_review").length;
  const blockedRows = rows.filter((row) => text(row.blocker) || text(row.group_validation_status).startsWith("blocked")).length;
  const pageTitle = isInternalTransfer ? "Internal-transfer Sage journal batch" : "Applied-loyalty Sage batch";
  const endpointLabel = isInternalTransfer ? "/journals" : "/contact_payments → /contact_allocations → /journals";
  const liveFlagLabel = isInternalTransfer ? "SAGE_LIVE_BANK_GL_POSTING_ENABLED" : "SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED";
  const introCopy = isInternalTransfer
    ? "This is a controlled Sage journal batch. It reuses the existing /journals primitive and posts one journal per validated internal-transfer group."
    : "This batch wraps materialised applied-loyalty Sage groups. The post creates the receipt → allocation → journal chain; retry continues the same batch and skips Sage steps that already have object ids.";
  const rowsCopy = isInternalTransfer
    ? "Each row is one internal-transfer Sage journal group. Payloads, Sage responses and audit metadata are collapsed below."
    : "Each row is one applied-loyalty Sage posting group. Payloads, Sage responses and audit metadata are collapsed below.";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <Link href="/internal/accounting-command-centre/loyalty-controls#step-3-lifecycle" className="text-sm font-semibold text-sky-700">← Loyalty controls</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-emerald-600">Completion loyalty · Sage batch</p>
          <div className="mt-2 flex flex-wrap items-start justify-between gap-3">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">{text(first.batch_ref) || "Loyalty Sage batch"}</h1>
              <p className="mt-1 text-base font-bold text-slate-700">{pageTitle}</p>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">{introCopy}</p>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm font-bold text-slate-800">
              Endpoint: {endpointLabel}<br />
              Live gate: {livePostingEnabled ? "enabled" : "disabled"}
            </div>
          </div>
          <div className="mt-3 flex flex-wrap gap-2 text-[11px] font-bold">
            <StatusBadge value={batchStatus || "not_loaded"} />
            <StatusBadge value={isInternalTransfer ? "sage_journal_batch" : batchType || "unknown_batch_type"} />
            <StatusBadge value={text(first.batch_validation_status) || "not_validated"} />
            <StatusBadge value={text(first.batch_approval_status) || "not_approved"} />
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">{liveFlagLabel}: {livePostingEnabled ? "true" : "false"}</span>
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
            <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
              <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">Approve / post</h2>
                  <p className="mt-1 text-sm text-slate-500">Approve the whole batch first. Posting uses the frozen endpoint and skips any Sage step that already has an object id on retry.</p>
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
                    <button disabled={!canPost} className="rounded-xl bg-slate-950 px-4 py-2 text-xs font-bold text-white hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-500">
                      {postButtonLabel}
                    </button>
                  </form>
                </div>
              </div>
              {!livePostingEnabled ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-xs font-semibold text-amber-900">Live posting is disabled. {isInternalTransfer ? "Enable the existing journal switch SAGE_LIVE_BANK_GL_POSTING_ENABLED=true after the controlled journal test is approved." : "Enable the approved applied-loyalty posting switch before posting."}</p> : null}
              {isRetryBatch ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-xs font-semibold text-amber-900">Retry keeps this same batch and skips any step already posted to Sage. Do not retire this batch if any Sage object exists.</p> : null}
            </section>

            <section className="grid gap-2 sm:grid-cols-3 lg:grid-cols-7">
              <SummaryChip label="Status" value={pretty(batchStatus)} />
              <SummaryChip label="Rows" value={text(first.batch_row_count)} />
              <SummaryChip label="Total" value={gbp(first.batch_total_amount_gbp)} />
              <SummaryChip label="Posted" value={String(postedRows)} />
              <SummaryChip label="Failed" value={String(failedRows)} />
              <SummaryChip label="Review / blocked" value={`${reviewRows} / ${blockedRows}`} />
              <SummaryChip label="Endpoint" value={endpointLabel} />
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
              <div className="border-b border-slate-100 px-4 py-3">
                <h2 className="text-xl font-semibold">Batch rows</h2>
                <p className="mt-1 text-sm text-slate-500">{rowsCopy}</p>
              </div>
              <div className="grid gap-3 p-4 lg:hidden">
                {rows.map((row) => <BatchRowCard key={text(row.item_id)} row={row} isInternalTransfer={isInternalTransfer} />)}
              </div>
              <div className="hidden overflow-x-auto lg:block">
                <table className="min-w-[1120px] divide-y divide-slate-200 text-xs">
                  <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2 text-left">Status</th>
                      <th className="px-3 py-2 text-left">Group</th>
                      <th className="px-3 py-2 text-left">{isInternalTransfer ? "Journal" : "Order"}</th>
                      <th className="px-3 py-2 text-left">Importer</th>
                      <th className="px-3 py-2 text-right">Amount</th>
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
                          <td className="px-3 py-3 text-[11px] font-semibold text-slate-700">
                            {isInternalTransfer ? journalSummary(row) : targets.length === 0 ? short(row.order_ref, 32) : targets.map((target, index) => {
                              const targetObj = asObject(target);
                              return <p key={`${text(row.item_id)}-${index}`} className="font-mono text-[11px]">{short(targetObj.target_sage_invoice_id, 34)} · {gbp(targetObj.allocation_amount_gbp)}</p>;
                            })}
                          </td>
                          <td className="px-3 py-3 font-bold">{short(row.importer_name, 36)}</td>
                          <td className="px-3 py-3 text-right font-bold">{gbp(row.amount_gbp)}</td>
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

            <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
              <h2 className="text-xl font-semibold">Payloads and Sage responses</h2>
              <p className="mt-1 text-sm text-slate-500">Collapsed by default. Open only when checking the frozen request, Sage response, or retry/audit evidence.</p>
              <div className="mt-4 grid gap-3 lg:grid-cols-2">
                {rows.map((row) => orderedSteps(row.steps_json).map((step, index) => {
                  const stepObj = asObject(step);
                  return <PayloadBlock key={`${text(row.item_id)}-${index}-payload`} title={`${pretty(stepObj.step_type)} · request payload`} value={stepObj.request_payload} />;
                }))}
                {rows.map((row) => orderedSteps(row.steps_json).map((step, index) => {
                  const stepObj = asObject(step);
                  return <PayloadBlock key={`${text(row.item_id)}-${index}-response`} title={`${pretty(stepObj.step_type)} · Sage response`} value={stepObj.response_payload} />;
                }))}
              </div>
            </section>
          </>
        )}
      </div>
    </main>
  );
}
