import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveCompletionLoyaltySageBatchAction, postCompletionLoyaltySageBatchAction } from "../../actions";

type Row = Record<string, unknown>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";
type Params = { batch_id: string } | Promise<{ batch_id: string }>;
type SearchParams = Record<string, string | string[] | undefined> | Promise<Record<string, string | string[] | undefined>>;

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

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

function walletName(details: unknown) {
  const raw = text(details).toLowerCase();
  if (raw.includes("virtual gbp")) return "Virtual GBP wallet";
  if (raw.includes("dva ghs")) return "DVA GHS wallet";
  if (raw.includes("main gbp bank")) return "Main GBP bank";
  if (raw.includes("main bank")) return "Main bank";
  return short(details, 38);
}

function debitLine(row: Row) {
  return journalLines(row).find((line) => num(line.debit) > 0) ?? {};
}

function creditLine(row: Row) {
  return journalLines(row).find((line) => num(line.credit) > 0) ?? {};
}

function movementSummary(row: Row) {
  const debit = debitLine(row);
  const credit = creditLine(row);
  const to = walletName(debit.details || debit.ledger_account_id) || "destination wallet";
  const from = walletName(credit.details || credit.ledger_account_id) || "main bank";
  return `${from} → ${to}`;
}

function messageParam(searchParams: Record<string, string | string[] | undefined>, key: "success" | "error") {
  return text(searchParams[key]);
}

function hasAccountingAccess(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function statusTone(value: unknown): Tone {
  const raw = text(value);
  if (["included", "validated", "locally_validated", "posted", "posted_to_sage", "approved", "admin_approved", "ok_to_post", "source_evidence_available", "present"].includes(raw)) return "complete";
  if (["blocked", "failed_retryable", "failed_terminal", "dry_run_failed", "missing", "cancelled", "superseded", "invalidated"].includes(raw)) return "blocked";
  if (["posting", "posting_to_sage", "not_approved", "not_posted", "not_dry_run_validated"].includes(raw)) return "action";
  if (["partially_posted_needs_review", "warning_only", "stale_reapproval_required"].includes(raw)) return "review";
  return "muted";
}

function Chip({ value }: { value: unknown }) {
  return <span className={`inline-flex max-w-[220px] truncate rounded-full border px-2 py-0.5 text-[10px] font-bold leading-4 ${toneClass(statusTone(value))}`}>{pretty(value)}</span>;
}

function StatPill({ label, value, tone }: { label: string; value: string; tone: Tone }) {
  return (
    <span className={`inline-flex items-center gap-1 rounded-full border px-2 py-1 text-[11px] font-bold leading-4 ${toneClass(tone)}`}>
      <span className="opacity-70">{label}</span>
      <span>{value}</span>
    </span>
  );
}

function PayloadBlock({ title, value }: { title: string; value: unknown }) {
  return (
    <details className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs">
      <summary className="cursor-pointer font-bold text-slate-900">{title}</summary>
      <pre className="mt-2 max-h-72 overflow-auto rounded-xl bg-white p-3 text-[11px] leading-5 text-slate-700">{JSON.stringify(value ?? {}, null, 2)}</pre>
    </details>
  );
}

function StepList({ row }: { row: Row }) {
  const steps = orderedSteps(row.steps_json);
  if (steps.length === 0) return <span className="text-[11px] font-semibold text-rose-700">No steps</span>;
  return (
    <div className="space-y-1">
      {steps.map((step, index) => {
        const stepObj = asObject(step);
        return <p key={`${text(row.item_id)}-step-${index}`} className="flex flex-wrap items-center gap-1"><span className="font-semibold text-slate-900">{pretty(stepObj.step_type)}</span><Chip value={stepObj.status} /></p>;
      })}
    </div>
  );
}

function SourceCell({ row, isInternalTransfer }: { row: Row; isInternalTransfer: boolean }) {
  if (isInternalTransfer) {
    return (
      <div className="space-y-1 text-[11px] leading-4">
        <p className="font-bold text-slate-900">{movementSummary(row)}</p>
        <p className="text-slate-600">Group: {short(row.posting_group_ref, 34)}</p>
      </div>
    );
  }
  return (
    <div className="space-y-1 text-[11px] leading-4">
      <p className="font-bold text-slate-900">Order: {text(row.order_ref) || "—"}</p>
      <p className="text-slate-600">Group: {short(row.posting_group_ref, 34)}</p>
    </div>
  );
}

function TargetCell({ row, isInternalTransfer }: { row: Row; isInternalTransfer: boolean }) {
  if (isInternalTransfer) {
    return (
      <div className="space-y-1 text-[11px] leading-4">
        <p className="font-semibold text-slate-900">Internal bank movement</p>
        <p className="text-slate-600">No customer invoice allocation.</p>
      </div>
    );
  }

  const targets = asArray(row.target_allocation_json);
  return (
    <div className="space-y-1 text-[11px] leading-4">
      {targets.length === 0 ? <span className="text-slate-400">—</span> : targets.map((target, index) => {
        const targetObj = asObject(target);
        return <p key={`${text(row.item_id)}-${index}`} className="font-mono text-[11px]">{short(targetObj.target_sage_invoice_id, 34)} · {gbp(targetObj.allocation_amount_gbp)}</p>;
      })}
    </div>
  );
}

function disabledPostingReason(args: { livePostingEnabled: boolean; approved: boolean; postableStatus: boolean; rows: number }) {
  const reasons: string[] = [];
  if (args.rows === 0) reasons.push("no batch rows");
  if (!args.approved) reasons.push("batch is not approved");
  if (!args.postableStatus) reasons.push("batch status is not postable");
  if (!args.livePostingEnabled) reasons.push("live posting is disabled");
  return reasons;
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
  const includedRows = rows;
  const postedRows = rows.filter((row) => text(row.item_posting_status) === "posted_to_sage").length;
  const failedRows = rows.filter((row) => ["failed_retryable", "failed_terminal"].includes(text(row.item_posting_status))).length;
  const reviewRows = rows.filter((row) => text(row.item_posting_status) === "partially_posted_needs_review").length;
  const blockedRows = rows.filter((row) => text(row.blocker) || text(row.group_validation_status).startsWith("blocked")).length;
  const livePostingEnabled = isInternalTransfer
    ? process.env.SAGE_LIVE_BANK_GL_POSTING_ENABLED === "true"
    : process.env.SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED === "true" || process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true";
  const approved = text(first.batch_approval_status) === "approved";
  const postableStatus = ["approved", "failed_retryable", "partially_posted_needs_review"].includes(batchStatus);
  const canApprove = rows.length > 0
    && batchStatus === "validated"
    && !approved
    && rows.every((row) => ["ok_to_post", "warning_only"].includes(text(row.group_validation_status)) && !text(row.blocker));
  const canPost = rows.length > 0 && livePostingEnabled && approved && postableStatus;
  const canRetire = rows.length > 0 && rows.every((row) => text(row.item_posting_status) !== "posted_to_sage" && !text(firstStep(row).sage_object_id));
  const postingBlockedReasons = disabledPostingReason({ livePostingEnabled, approved, postableStatus, rows: rows.length });
  const laneLabel = isInternalTransfer ? "internal transfer" : "applied loyalty";
  const postButtonLabel = isRetryBatch ? "Retry failed / remaining steps" : isInternalTransfer ? "Post internal transfer to Sage" : "Post applied loyalty to Sage";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1900px] space-y-3">
        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <div className="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-3">
                <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
                <Link href="/internal/accounting-command-centre/loyalty-controls#step-3-lifecycle" className="text-sm font-semibold text-sky-700">Loyalty controls</Link>
              </div>
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Posting batch detail</p>
                <span className="rounded-full border border-violet-200 bg-violet-50 px-2 py-1 text-[10px] font-bold text-violet-900">Completion loyalty</span>
                <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-1 text-[10px] font-bold text-slate-700">Lane-aware Sage action</span>
              </div>
              <h1 className="mt-1 truncate text-3xl font-semibold tracking-tight sm:text-4xl">{text(first.batch_ref) || "Posting batch"}</h1>
              <p className="mt-1 max-w-5xl text-sm leading-5 text-slate-600">Local batch lock plus approval. The correct posting button appears here after the selected lane is approved; retry continues the same batch and skips posted steps.</p>
              <p className="mt-1 text-xs font-semibold text-slate-500">Batch id {batchId}</p>
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <form action={approveCompletionLoyaltySageBatchAction} className="flex flex-wrap items-center gap-2">
                  <input type="hidden" name="batch_id" value={batchId} />
                  <input type="hidden" name="approval_notes" value="Approved from completion loyalty batch detail." />
                  <button type="submit" disabled={!canApprove} className="rounded-2xl bg-violet-700 px-4 py-2 text-sm font-bold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600">
                    Approve batch
                  </button>
                </form>
                <form action={postCompletionLoyaltySageBatchAction} className="flex flex-wrap items-center gap-2">
                  <input type="hidden" name="batch_id" value={batchId} />
                  <button type="submit" disabled={!canPost} className="rounded-2xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600" title={canPost ? `Posts ${laneLabel} batch to Sage.` : postingBlockedReasons.join("; ") || "Posting is not available for this batch."}>
                    {postButtonLabel}
                  </button>
                </form>
                <Link href={`/internal/accounting-command-centre/loyalty-controls/batches/${batchId}/retire`} aria-disabled={!canRetire} className={`rounded-2xl px-4 py-2 text-sm font-bold shadow-sm ${canRetire ? "border border-rose-200 bg-rose-50 text-rose-700 hover:bg-rose-100" : "pointer-events-none bg-slate-200 text-slate-500"}`}>
                  Retire local batch
                </Link>
                {livePostingEnabled ? (
                  <span className="rounded-2xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs font-bold text-emerald-900">Live Sage posting enabled.</span>
                ) : (
                  <span className="rounded-2xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs font-bold text-amber-900">Live Sage posting disabled.</span>
                )}
              </div>
            </div>
            <div className="flex shrink-0 flex-wrap gap-1.5 xl:max-w-[900px] xl:justify-end">
              <StatPill label="Status" value={pretty(batchStatus)} tone={statusTone(batchStatus)} />
              <StatPill label="Lane" value={pretty(laneLabel)} tone="review" />
              <StatPill label="Rows" value={String(first.batch_row_count ?? rows.length)} tone={rows.length > 0 ? "complete" : "muted"} />
              <StatPill label="Total" value={gbp(first.batch_total_amount_gbp)} tone={rows.length > 0 ? "complete" : "muted"} />
              <StatPill label="Approved" value={approved ? "yes" : "no"} tone={approved ? "complete" : "action"} />
              <StatPill label="Posted" value={String(postedRows)} tone={postedRows > 0 ? "complete" : "muted"} />
              <StatPill label="Failed" value={String(failedRows)} tone={failedRows > 0 ? "blocked" : "complete"} />
              <StatPill label="Review" value={String(reviewRows)} tone={reviewRows > 0 ? "review" : "complete"} />
              <StatPill label="Blocked" value={String(blockedRows)} tone={blockedRows > 0 ? "blocked" : "complete"} />
            </div>
          </div>
          {success ? <p className="mt-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {pageError ? <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{pageError}</p> : null}
          {postingBlockedReasons.length > 0 && rows.length > 0 ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Posting blocked: {postingBlockedReasons.join("; ")}.</p> : null}
          {isRetryBatch ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Retry keeps this same batch and skips any step already posted to Sage. Do not retire this batch if any Sage object exists.</p> : null}
          {error ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Batch detail RPC unavailable: {error.message}. Run the latest loyalty Sage batch migration before testing this page.</p> : null}
          {!error && rows.length === 0 ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">No batch rows found for this batch id.</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="flex flex-col gap-2 border-b border-slate-100 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Batch rows</h2>
              <p className="mt-1 text-sm text-slate-500">Each row shows source facts, Sage target/control status and posting status. If blocked, stop before Sage posting.</p>
            </div>
          </div>
          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1320px] table-fixed divide-y divide-slate-200 text-xs">
              <colgroup>
                <col className="w-[112px]" />
                <col className="w-[150px]" />
                <col className="w-[260px]" />
                <col className="w-[260px]" />
                <col className="w-[96px]" />
                <col className="w-[180px]" />
                <col className="w-[180px]" />
                <col className="w-[250px]" />
              </colgroup>
              <thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-2 py-2 text-left">Status</th>
                  <th className="px-2 py-2 text-left">Lane</th>
                  <th className="px-2 py-2 text-left">Source facts</th>
                  <th className="px-2 py-2 text-left">Sage target / control</th>
                  <th className="px-2 py-2 text-right">Amount</th>
                  <th className="px-2 py-2 text-left">Validation</th>
                  <th className="px-2 py-2 text-left">Steps</th>
                  <th className="px-2 py-2 text-left">Reason / error</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? <tr><td colSpan={8} className="px-3 py-8 text-center text-sm text-slate-500">No rows.</td></tr> : includedRows.map((row) => (
                  <tr key={text(row.item_id) || text(row.posting_group_ref)} className="align-top hover:bg-slate-50">
                    <td className="px-2 py-2"><Chip value={row.item_posting_status} /></td>
                    <td className="px-2 py-2"><p className="truncate font-bold text-slate-950">{pretty(laneLabel)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{pretty(batchType)}</p></td>
                    <td className="px-2 py-2"><SourceCell row={row} isInternalTransfer={isInternalTransfer} /></td>
                    <td className="px-2 py-2"><TargetCell row={row} isInternalTransfer={isInternalTransfer} /></td>
                    <td className="px-2 py-2 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}<p className="text-[11px] font-normal text-slate-500">GBP</p></td>
                    <td className="px-2 py-2"><Chip value={row.group_validation_status} />{text(row.blocker) ? <p className="mt-1 line-clamp-3 text-[11px] font-semibold text-rose-700">{text(row.blocker)}</p> : null}</td>
                    <td className="px-2 py-2"><StepList row={row} /></td>
                    <td className="px-2 py-2"><p className="line-clamp-4 text-[11px] font-semibold leading-4 text-slate-600">{text(row.last_posting_error) || text(row.blocker) || "—"}</p></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <details>
            <summary className="cursor-pointer text-lg font-semibold text-slate-950">Technical audit</summary>
            <p className="mt-1 text-sm text-slate-500">Frozen request payloads and Sage responses are kept here for audit/retry checks. They are not part of the normal posting workflow view.</p>
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
          </details>
        </section>
      </div>
    </main>
  );
}
