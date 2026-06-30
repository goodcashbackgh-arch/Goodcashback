import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveCompletionLoyaltySageBatchAction, postCompletionLoyaltySageBatchAction } from "../../actions";

type Row = Record<string, unknown>;
type Params = { batch_id: string } | Promise<{ batch_id: string }>;
type SearchParams = Record<string, string | string[] | undefined> | Promise<Record<string, string | string[] | undefined>>;

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

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

function gbp(value: unknown) { return gbpFormatter.format(num(value)); }
function pretty(value: unknown) { const raw = text(value); return raw ? raw.replaceAll("_", " ") : "—"; }
function short(value: unknown, max = 38) { const raw = text(value); return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw || "—"; }
function asObject(value: unknown): Row { return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {}; }
function asArray(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }

function tone(value: unknown) {
  const raw = text(value);
  if (["validated", "locally_validated", "posted_to_sage", "approved", "admin_approved", "ok_to_post"].includes(raw)) return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (["blocked", "failed_retryable", "failed_terminal", "cancelled", "superseded", "invalidated"].includes(raw)) return "border-rose-200 bg-rose-50 text-rose-900";
  if (["not_approved", "not_posted", "posting_to_sage", "warning_only"].includes(raw)) return "border-amber-200 bg-amber-50 text-amber-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function Chip({ value }: { value: unknown }) {
  return <span className={`inline-flex rounded-full border px-2 py-0.5 text-[10px] font-bold ${tone(value)}`}>{pretty(value)}</span>;
}

function Stat({ label, value }: { label: string; value: string }) {
  return <span className="inline-flex rounded-full border border-slate-200 bg-slate-50 px-2 py-1 text-[11px] font-bold text-slate-800"><span className="mr-1 text-slate-500">{label}</span>{value}</span>;
}

function orderedSteps(row: Row) {
  return asArray(row.steps_json).map(asObject).sort((a, b) => text(a.step_type).localeCompare(text(b.step_type)));
}

function payloadBlocks(row: Row, prefix: string) {
  return orderedSteps(row).flatMap((step, index) => [
    <details key={`${prefix}-${index}-payload`} className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs"><summary className="cursor-pointer font-bold text-slate-900">{pretty(step.step_type)} · request payload</summary><pre className="mt-2 max-h-72 overflow-auto rounded-xl bg-white p-3 text-[11px] leading-5 text-slate-700">{JSON.stringify(step.request_payload ?? {}, null, 2)}</pre></details>,
    <details key={`${prefix}-${index}-response`} className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs"><summary className="cursor-pointer font-bold text-slate-900">{pretty(step.step_type)} · Sage response</summary><pre className="mt-2 max-h-72 overflow-auto rounded-xl bg-white p-3 text-[11px] leading-5 text-slate-700">{JSON.stringify(step.response_payload ?? {}, null, 2)}</pre></details>,
  ]);
}

function movement(row: Row) {
  const step = orderedSteps(row)[0] ?? {};
  const journal = asObject(asObject(step.request_payload).journal);
  const lines = asArray(journal.journal_lines).map(asObject);
  const debit = lines.find((line) => num(line.debit) > 0) ?? {};
  const credit = lines.find((line) => num(line.credit) > 0) ?? {};
  const from = short(credit.details || "Main GBP bank", 24).replace("Completion loyalty transfer from ", "");
  const to = short(debit.details || "destination wallet", 24).replace("Completion loyalty transfer to ", "");
  return `${from} → ${to}`;
}

function SourceCell({ row, internal }: { row: Row; internal: boolean }) {
  return <div className="space-y-1 text-[11px]"><p className="font-bold text-slate-900">{internal ? movement(row) : `Order ${text(row.order_ref) || "—"}`}</p><p className="break-all text-slate-600">Group: {short(row.posting_group_ref, 34)}</p></div>;
}

function TargetCell({ internal }: { internal: boolean }) {
  return <div className="space-y-1 text-[11px]"><p className="font-semibold text-slate-900">{internal ? "Internal bank movement" : "Customer settlement"}</p><p className="text-slate-600">{internal ? "No customer invoice allocation." : "Uses frozen allocation target."}</p></div>;
}

function StepsCell({ row }: { row: Row }) {
  const steps = orderedSteps(row);
  return <div className="space-y-1">{steps.length === 0 ? <span className="text-[11px] text-rose-700">No steps</span> : steps.map((step, index) => <p key={`${text(row.item_id)}-${index}`} className="flex flex-wrap items-center gap-1 text-[11px]"><span className="font-bold text-slate-900">{pretty(step.step_type)}</span><Chip value={step.status} /></p>)}</div>;
}

function MobileRow({ row, internal, laneLabel, batchType }: { row: Row; internal: boolean; laneLabel: string; batchType: string }) {
  return <article className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><div className="flex items-start justify-between gap-3"><div><div className="flex flex-wrap gap-1"><Chip value={row.item_posting_status} /><Chip value={row.group_validation_status} /></div><p className="mt-3 text-sm font-extrabold text-slate-950">{pretty(laneLabel)}</p><p className="text-xs font-semibold text-slate-500">{pretty(batchType)}</p></div><p className="rounded-xl bg-slate-50 px-3 py-2 text-lg font-extrabold">{gbp(row.amount_gbp)}</p></div><div className="mt-4 grid gap-3"><div className="rounded-xl border border-slate-100 bg-slate-50 p-3"><p className="text-[10px] font-bold uppercase tracking-wide text-slate-500">Source facts</p><SourceCell row={row} internal={internal} /></div><div className="rounded-xl border border-slate-100 bg-slate-50 p-3"><p className="text-[10px] font-bold uppercase tracking-wide text-slate-500">Sage target / control</p><TargetCell internal={internal} /></div><div className="rounded-xl border border-slate-100 bg-slate-50 p-3"><p className="text-[10px] font-bold uppercase tracking-wide text-slate-500">Steps</p><StepsCell row={row} /></div></div></article>;
}

function hasAccountingAccess(value: unknown) {
  const permissions = asObject(value);
  return permissions.accounting_admin_testing === true || permissions.admin_testing === true;
}

export default async function CompletionLoyaltySageBatchDetailPage({ params, searchParams }: { params: Params; searchParams?: SearchParams }) {
  const resolvedParams = await Promise.resolve(params);
  const resolvedSearchParams = await Promise.resolve(searchParams ?? {});
  const batchId = resolvedParams.batch_id;
  const success = text(resolvedSearchParams.success);
  const pageError = text(resolvedSearchParams.error);

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("id, role_type, permissions_json").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  const canAccess = text(staff.role_type) === "admin" || hasAccountingAccess((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  const { data, error } = await (supabase as any).rpc("internal_completion_loyalty_sage_batch_detail_v1", { p_batch_id: batchId });
  const rows = (data ?? []) as Row[];
  const first = rows[0] ?? {};
  const batchStatus = text(first.batch_status);
  const batchType = text(first.batch_type);
  const internal = batchType === "completion_loyalty_internal_transfer_journal";
  const approved = text(first.batch_approval_status) === "approved";
  const livePostingEnabled = internal ? process.env.SAGE_LIVE_BANK_GL_POSTING_ENABLED === "true" : process.env.SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED === "true" || process.env.SAGE_LIVE_CASH_POSTING_ENABLED === "true";
  const canApprove = rows.length > 0 && batchStatus === "validated" && !approved && rows.every((row) => ["ok_to_post", "warning_only"].includes(text(row.group_validation_status)) && !text(row.blocker));
  const postableStatus = ["approved", "failed_retryable", "partially_posted_needs_review"].includes(batchStatus);
  const canPost = rows.length > 0 && approved && postableStatus && livePostingEnabled;
  const canRetire = rows.length > 0 && rows.every((row) => text(row.item_posting_status) !== "posted_to_sage");
  const laneLabel = internal ? "internal transfer" : "applied loyalty";
  const postButtonLabel = internal ? "Post internal transfer to Sage" : "Post applied loyalty to Sage";
  const notice = canPost || rows.length === 0 ? "" : !approved && canApprove ? "Approve this batch to enable posting." : !approved ? "Batch must be approved before posting." : !livePostingEnabled ? "Live Sage posting is disabled." : !postableStatus ? `Batch status is ${pretty(batchStatus)}. Posting is available only after approval or for retryable batches.` : "Posting is not available for this batch.";
  const posted = rows.filter((row) => text(row.item_posting_status) === "posted_to_sage").length;
  const failed = rows.filter((row) => ["failed_retryable", "failed_terminal"].includes(text(row.item_posting_status))).length;
  const blocked = rows.filter((row) => text(row.blocker) || text(row.group_validation_status).startsWith("blocked")).length;

  return <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8"><div className="mx-auto max-w-[1900px] space-y-3"><section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><div className="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between"><div className="min-w-0"><div className="flex flex-wrap items-center gap-3"><Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link><Link href="/internal/accounting-command-centre/loyalty-controls#step-3-lifecycle" className="text-sm font-semibold text-sky-700">Loyalty controls</Link></div><div className="mt-3 flex flex-wrap items-center gap-2"><p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Posting batch detail</p><span className="rounded-full border border-violet-200 bg-violet-50 px-2 py-1 text-[10px] font-bold text-violet-900">Completion loyalty</span></div><h1 className="mt-1 truncate text-3xl font-semibold tracking-tight sm:text-4xl">{text(first.batch_ref) || "Posting batch"}</h1><p className="mt-1 max-w-5xl text-sm leading-5 text-slate-600">Local batch lock plus approval. Retry continues the same batch and skips posted steps.</p><p className="mt-1 text-xs font-semibold text-slate-500">Batch id {batchId}</p><div className="mt-3 flex flex-wrap items-center gap-2"><form action={approveCompletionLoyaltySageBatchAction}><input type="hidden" name="batch_id" value={batchId} /><input type="hidden" name="approval_notes" value="Approved from completion loyalty batch detail." /><button type="submit" disabled={!canApprove} className="rounded-2xl bg-violet-700 px-4 py-2 text-sm font-bold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600">Approve batch</button></form><form action={postCompletionLoyaltySageBatchAction}><input type="hidden" name="batch_id" value={batchId} /><button type="submit" disabled={!canPost} className="rounded-2xl bg-emerald-700 px-4 py-2 text-sm font-bold text-white shadow-sm disabled:cursor-not-allowed disabled:bg-slate-300 disabled:text-slate-600">{postButtonLabel}</button></form><Link href={`/internal/accounting-command-centre/loyalty-controls/batches/${batchId}/retire`} aria-disabled={!canRetire} className={`rounded-2xl px-4 py-2 text-sm font-bold shadow-sm ${canRetire ? "border border-rose-200 bg-rose-50 text-rose-700 hover:bg-rose-100" : "pointer-events-none bg-slate-200 text-slate-500"}`}>Retire local batch</Link><span className={`rounded-2xl border px-3 py-2 text-xs font-bold ${livePostingEnabled ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}>Live Sage posting {livePostingEnabled ? "enabled" : "disabled"}.</span></div></div><div className="flex shrink-0 flex-wrap gap-1.5 xl:max-w-[900px] xl:justify-end"><Stat label="Status" value={pretty(batchStatus)} /><Stat label="Lane" value={pretty(laneLabel)} /><Stat label="Rows" value={String(first.batch_row_count ?? rows.length)} /><Stat label="Total" value={gbp(first.batch_total_amount_gbp)} /><Stat label="Approved" value={approved ? "yes" : "no"} /><Stat label="Posted" value={String(posted)} /><Stat label="Failed" value={String(failed)} /><Stat label="Blocked" value={String(blocked)} /></div></div>{success ? <p className="mt-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}{pageError ? <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{pageError}</p> : null}{notice ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">{notice}</p> : null}{error ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Batch detail RPC unavailable: {error.message}</p> : null}</section><section className="rounded-3xl border border-slate-200 bg-white shadow-sm"><div className="border-b border-slate-100 px-4 py-3"><h2 className="text-xl font-semibold">Batch rows</h2><p className="mt-1 text-sm text-slate-500">Each row shows source facts, Sage target/control status and posting status. If blocked, stop before Sage posting.</p></div><div className="grid gap-3 p-4 lg:hidden">{rows.length === 0 ? <p className="py-8 text-center text-sm text-slate-500">No rows.</p> : rows.map((row) => <MobileRow key={text(row.item_id) || text(row.posting_group_ref)} row={row} internal={internal} laneLabel={laneLabel} batchType={batchType} />)}</div><div className="hidden overflow-x-auto rounded-b-3xl lg:block"><table className="min-w-[1320px] table-fixed divide-y divide-slate-200 text-xs"><thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500"><tr><th className="px-2 py-2 text-left">Status</th><th className="px-2 py-2 text-left">Lane</th><th className="px-2 py-2 text-left">Source facts</th><th className="px-2 py-2 text-left">Sage target / control</th><th className="px-2 py-2 text-right">Amount</th><th className="px-2 py-2 text-left">Validation</th><th className="px-2 py-2 text-left">Steps</th><th className="px-2 py-2 text-left">Reason / error</th></tr></thead><tbody className="divide-y divide-slate-100 bg-white">{rows.length === 0 ? <tr><td colSpan={8} className="px-3 py-8 text-center text-sm text-slate-500">No rows.</td></tr> : rows.map((row) => <tr key={text(row.item_id) || text(row.posting_group_ref)} className="align-top hover:bg-slate-50"><td className="px-2 py-2"><Chip value={row.item_posting_status} /></td><td className="px-2 py-2"><p className="truncate font-bold text-slate-950">{pretty(laneLabel)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{pretty(batchType)}</p></td><td className="px-2 py-2"><SourceCell row={row} internal={internal} /></td><td className="px-2 py-2"><TargetCell internal={internal} /></td><td className="px-2 py-2 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}<p className="text-[11px] font-normal text-slate-500">GBP</p></td><td className="px-2 py-2"><Chip value={row.group_validation_status} /></td><td className="px-2 py-2"><StepsCell row={row} /></td><td className="px-2 py-2"><p className="line-clamp-4 text-[11px] font-semibold leading-4 text-slate-600">{text(row.last_posting_error) || text(row.blocker) || "—"}</p></td></tr>)}</tbody></table></div></section><section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><details><summary className="cursor-pointer text-lg font-semibold text-slate-950">Technical audit</summary><p className="mt-1 text-sm text-slate-500">Frozen request payloads and Sage responses are kept here for audit/retry checks.</p><div className="mt-4 grid gap-3 lg:grid-cols-2">{rows.flatMap((row, index) => payloadBlocks(row, `${text(row.item_id) || index}`))}</div></details></section></div></main>;
}
