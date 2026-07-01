import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import SelectionControls from "./SelectionControls";
import {
  createCompletionLoyaltySageBatchAction,
  materialiseInternalTransferJournalAction,
  materialiseSelectedInternalTransferJournalsAction,
  supersedeCompletionLoyaltySageGroupAction,
  validateCompletionLoyaltySageGroupAction,
} from "./loyalty-controls/actions";

type Row = Record<string, unknown>;
type Props = { searchQuery?: string; statusFilter?: string };

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });
const activeBatchStatuses = new Set(["draft", "validated", "blocked", "approved", "posting_to_sage", "partially_posted_needs_review", "failed_retryable", "failed_terminal"]);

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

function gbp(value: unknown) { return gbpFormatter.format(num(value)); }
function pretty(value: unknown) { const raw = text(value); return raw ? raw.replaceAll("_", " ") : "-"; }
function asArray(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
function asObject(value: unknown): Row { return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {}; }
function contextValue(group: Row, key: string) { return asObject(group.request_context_json)[key]; }
function batchLink(batchId: unknown) { return `/internal/accounting-command-centre/loyalty-controls/batches/${text(batchId)}`; }
function groupKey(row: Row) { return text(row.posting_group_id) || text(row.posting_group_ref) || `${text(row.source_out_statement_line_id)}-${text(row.destination_in_statement_line_id)}`; }
function candidateKey(row: Row) { return `${text(row.source_out_statement_line_id)}-${text(row.destination_in_statement_line_id)}-${text(row.importer_id)}`; }
function candidatePairValue(row: Row) { return `${text(row.source_out_statement_line_id)}|${text(row.destination_in_statement_line_id)}`; }
function HiddenGroupId({ group }: { group: Row }) { return <input type="hidden" name="posting_group_id" value={text(group.posting_group_id)} />; }

function walletLabel(value: unknown) {
  const raw = text(value);
  if (raw === "virtual_gbp_wallet") return "Virtual GBP wallet";
  if (raw === "dva_ghs_wallet") return "DVA GHS wallet";
  if (raw === "main_gbp_bank") return "Main GBP bank";
  return pretty(raw);
}

function badgeTone(status: string) {
  if (["blocked", "failed_retryable", "failed_terminal", "stale_reapproval_required", "invalidated"].includes(status)) return "border-rose-200 bg-rose-50 text-rose-700";
  if (["validated", "locally_validated", "admin_approved", "approved", "posted_to_sage", "ok_to_post", "already_batched", "ready_to_approve", "ready_to_post", "ready_internal_transfer_journal_materialisation"].includes(status)) return "border-emerald-200 bg-emerald-50 text-emerald-700";
  if (["not_approved", "not_posted", "partially_posted_needs_review", "posting_to_sage", "warning_only", "already_materialised"].includes(status)) return "border-amber-200 bg-amber-50 text-amber-700";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function StatusBadge({ value }: { value: unknown }) {
  const raw = text(value) || "unknown";
  return <span className={`inline-flex rounded-full border px-2.5 py-1 text-[11px] font-bold ${badgeTone(raw)}`}>{pretty(raw)}</span>;
}

function batchReadyToApprove(batch: Row) {
  return text(batch.status) === "validated" && text(batch.approval_status) !== "approved" && num(batch.row_count) > 0;
}

function batchReadyToPost(batch: Row) {
  return text(batch.approval_status) === "approved" && ["approved", "failed_retryable", "partially_posted_needs_review"].includes(text(batch.status)) && num(batch.row_count) > 0;
}

function batchMatchesStatus(batch: Row, statusFilter: string) {
  if (!statusFilter || statusFilter === "all" || statusFilter === "needs_action" || statusFilter === "batched_or_posted") return true;
  if (statusFilter === "ready_to_approve") return batchReadyToApprove(batch);
  if (statusFilter === "ready_to_post") return batchReadyToPost(batch);
  if (statusFilter === "blocked") return ["blocked", "failed_retryable", "failed_terminal"].includes(text(batch.status)) || num(batch.failed_count) > 0;
  return false;
}

function groupReadyForBatch(group: Row, activeBatchedGroupIds: Set<string>) {
  const status = text(group.status);
  const validationStatus = text(group.validation_status);
  const groupId = text(group.posting_group_id);
  return ["locally_validated", "admin_approved"].includes(status)
    && ["ok_to_post", "warning_only"].includes(validationStatus)
    && !text(group.blocker)
    && num(group.posted_step_count) === 0
    && !activeBatchedGroupIds.has(groupId);
}

export default async function CompletionLoyaltyInternalTransferJournalPanel({ searchQuery = "", statusFilter = "needs_action" }: Props) {
  const supabase = await createClient();
  const cleanSearch = searchQuery.trim() || null;

  const [
    { data: candidateData, error: candidateError },
    { data: groupData, error: groupError },
    { data: batchData, error: batchError },
  ] = await Promise.all([
    (supabase as any).rpc("internal_completion_loyalty_internal_transfer_candidates_v1", { p_search: cleanSearch, p_limit: 300, p_offset: 0 }),
    (supabase as any).rpc("internal_completion_loyalty_sage_posting_groups_v1", { p_search: cleanSearch, p_status: "all", p_limit: 300, p_offset: 0 }),
    (supabase as any).rpc("internal_completion_loyalty_sage_batches_v1", { p_search: cleanSearch, p_status: "all", p_limit: 100, p_offset: 0 }),
  ]);

  const candidates = ((candidateData ?? []) as Row[]);
  const materialisableCandidates = candidates.filter((row) => !text(row.blocker) && !text(row.existing_posting_group_id) && text(row.source_out_statement_line_id) && text(row.destination_in_statement_line_id));
  const groups = ((groupData ?? []) as Row[]).filter((row) => text(row.posting_group_type) === "completion_loyalty_internal_transfer_journal");
  const batches = ((batchData ?? []) as Row[]).filter((row) => text(row.batch_type) === "completion_loyalty_internal_transfer_journal");
  const visibleBatches = batches.filter((batch) => batchMatchesStatus(batch, statusFilter));
  const showSourceSections = !["ready_to_approve", "ready_to_post", "batched_or_posted"].includes(statusFilter);
  const activeBatchedGroupIds = new Set(batches.filter((row) => activeBatchStatuses.has(text(row.status))).flatMap((row) => asArray(row.posting_group_ids).map(text)).filter(Boolean));
  const batchReadyGroups = groups.filter((group) => groupReadyForBatch(group, activeBatchedGroupIds));

  const totalCandidateAmount = candidates.reduce((sum, row) => sum + num(row.transfer_amount_gbp), 0);
  const totalMaterialisableAmount = materialisableCandidates.reduce((sum, row) => sum + num(row.transfer_amount_gbp), 0);
  const totalGroupAmount = groups.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const batchReadyAmount = batchReadyGroups.reduce((sum, group) => sum + num(group.amount_gbp), 0);
  const visibleBatchAmount = visibleBatches.reduce((sum, batch) => sum + num(batch.total_amount_gbp), 0);
  const statusSummaryCount = showSourceSections ? batchReadyGroups.length : visibleBatches.length;
  const statusSummaryAmount = showSourceSections ? batchReadyAmount : visibleBatchAmount;
  const statusSummaryLabel = statusFilter === "ready_to_post" ? "postable batch(es)" : statusFilter === "ready_to_approve" ? "approval batch(es)" : statusFilter === "batched_or_posted" ? "batch row(s)" : "unbatched ready group(s)";
  const hasRows = candidates.length > 0 || groups.length > 0 || visibleBatches.length > 0;
  const hasRpcError = Boolean(candidateError || groupError || batchError);

  return (
    <section id="step-3-internal-transfer" className="rounded-3xl border border-cyan-200 bg-white p-5 shadow-sm scroll-mt-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-cyan-700">Step 3 · Internal transfer journal lane</p>
          <h2 className="mt-2 text-xl font-semibold text-slate-950">Completion-loyalty bank movement</h2>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">Paired released main-bank OUT and DVA/card IN rows become CLIT journal groups first. One CLITB batch then wraps one or more CLIT groups for approval, posting and retry.</p>
        </div>
        <div className="rounded-2xl bg-cyan-50 px-4 py-3 text-sm font-semibold text-cyan-950 ring-1 ring-cyan-200">
          {candidates.length} candidate(s) · {gbp(totalCandidateAmount)}<br />
          {groups.length} group(s) · {gbp(totalGroupAmount)}<br />
          {statusSummaryCount} {statusSummaryLabel} · {gbp(statusSummaryAmount)}
        </div>
      </div>

      {[candidateError, groupError, batchError].filter(Boolean).map((error, index) => (
        <div key={index} className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">{error.message}</div>
      ))}

      {!hasRows && !hasRpcError ? (
        <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">No paired released internal-transfer candidates, materialised transfer groups, or transfer batches match the current filters.</div>
      ) : null}

      {showSourceSections ? (
        <div className="mt-5 grid gap-4 xl:grid-cols-2">
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h3 className="font-bold text-slate-950">Paired transfer candidates</h3>
                <p className="mt-1 text-xs leading-5 text-slate-500">Bulk or single materialise/freeze creates local CLIT journal groups only. No Sage API call.</p>
              </div>
              <div className="rounded-xl border border-cyan-200 bg-cyan-50 px-3 py-2 text-right text-xs font-bold text-cyan-900">{materialisableCandidates.length} selectable<br />{gbp(totalMaterialisableAmount)}</div>
            </div>

            {materialisableCandidates.length > 0 ? (
              <form id="bulk-internal-transfer-materialise-form" action={materialiseSelectedInternalTransferJournalsAction} className="mt-3 rounded-2xl border border-cyan-200 bg-white p-3">
                <div className="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-end">
                  <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">Materialisation note<input name="notes" placeholder="Optional bulk materialisation note" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" /></label>
                  <button type="submit" className="rounded-xl bg-cyan-700 px-4 py-2 text-xs font-bold text-white hover:bg-cyan-800">Materialise / freeze selected</button>
                </div>
                <div className="mt-3"><SelectionControls /></div>
              </form>
            ) : null}

            <div className="mt-4 space-y-2">
              {candidates.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-500">No paired released internal-transfer candidates match the current filters.</div> : candidates.map((row) => {
                const blocker = text(row.blocker);
                const alreadyMaterialised = Boolean(text(row.existing_posting_group_id));
                const canMaterialise = !blocker && !alreadyMaterialised && text(row.source_out_statement_line_id) && text(row.destination_in_statement_line_id);
                return (
                  <div key={candidateKey(row)} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div className="flex items-start gap-3">
                        {canMaterialise ? <input type="checkbox" name="internal_transfer_candidate_key" value={candidatePairValue(row)} form="bulk-internal-transfer-materialise-form" defaultChecked data-accounting-row-select="true" className="mt-1 h-4 w-4 rounded border-slate-300" aria-label={`Select ${text(row.importer_name) || "internal transfer"} for materialisation`} /> : <span className="mt-1 text-xs text-slate-300">-</span>}
                        <div><p className="font-bold text-slate-950">{text(row.importer_name) || "Importer/customer"}</p><p className="mt-1 text-sm text-slate-500">Debit: {walletLabel(row.destination_wallet_code)} · Credit: Main GBP bank</p><p className="mt-2 text-xs text-slate-500">Released loyalty {gbp(row.loyalty_released_amount_gbp)} · Wallet excess {gbp(row.excess_remaining_gbp)}</p></div>
                      </div>
                      <div className="text-right"><p className="text-lg font-extrabold text-slate-950">{gbp(row.transfer_amount_gbp)}</p><StatusBadge value={alreadyMaterialised ? "already_materialised" : row.materialisation_status} /></div>
                    </div>
                    {blocker ? <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-xs font-semibold text-rose-700">Blocker: {pretty(blocker)}</p> : null}
                    {alreadyMaterialised ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-xs font-semibold text-amber-900">Existing group: {text(row.existing_posting_group_ref)}</p> : null}
                    <details className="mt-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600"><summary className="cursor-pointer font-bold text-slate-800">Audit details</summary><div className="mt-3 grid gap-2 sm:grid-cols-2"><p>OUT date: {text(row.source_out_date) || "-"}</p><p>IN date: {text(row.destination_in_date) || "-"}</p><p className="break-all sm:col-span-2">OUT ref: {text(row.source_out_reference) || "-"}</p><p className="break-all sm:col-span-2">IN ref: {text(row.destination_in_reference) || "-"}</p><p className="break-all sm:col-span-2">Mappings: {text(row.source_mapping_code) || "-"} / {text(row.destination_mapping_code) || "-"}</p></div></details>
                    <form action={materialiseInternalTransferJournalAction} className="mt-3 grid gap-2 sm:grid-cols-[1fr_auto]"><input type="hidden" name="source_out_statement_line_id" value={text(row.source_out_statement_line_id)} /><input type="hidden" name="destination_in_statement_line_id" value={text(row.destination_in_statement_line_id)} /><input name="notes" placeholder="Optional materialisation note" className="rounded-2xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-950" /><button type="submit" disabled={!canMaterialise} className="rounded-2xl bg-cyan-700 px-4 py-2 text-sm font-bold text-white hover:bg-cyan-800 disabled:bg-slate-200 disabled:text-slate-500">Materialise / freeze</button></form>
                  </div>
                );
              })}
            </div>
          </div>

          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
            <div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="font-bold text-slate-950">CLIT journal groups</h3><p className="mt-1 text-xs leading-5 text-slate-500">These are materialised source groups. Once already batched, open the CLITB batch below to approve, post or retry.</p></div><div className="rounded-xl border border-cyan-200 bg-cyan-50 px-3 py-2 text-right text-xs font-bold text-cyan-900">{batchReadyGroups.length} unbatched ready<br />{gbp(batchReadyAmount)}</div></div>
            {batchReadyGroups.length > 0 ? <form id="create-loyalty-internal-transfer-batch-form" action={createCompletionLoyaltySageBatchAction} className="mt-3 rounded-2xl border border-cyan-200 bg-white p-3"><div className="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-end"><label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">Batch note<input name="batch_notes" placeholder="Optional batch note" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" /></label><button type="submit" className="rounded-xl bg-cyan-700 px-4 py-2 text-xs font-bold text-white hover:bg-cyan-800">Create transfer Sage batch</button></div><div className="mt-3"><SelectionControls /></div></form> : groups.length > 0 ? <div className="mt-3 rounded-2xl border border-slate-200 bg-white p-3 text-xs font-semibold text-slate-500">No locally validated unbatched transfer groups are ready for batching.</div> : null}
            <div className="mt-4 space-y-2">
              {groups.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-500">No materialised internal-transfer journal groups yet.</div> : groups.map((group) => {
                const status = text(group.status);
                const validationStatus = text(group.validation_status);
                const groupId = text(group.posting_group_id);
                const alreadyBatched = activeBatchedGroupIds.has(groupId);
                const canBatch = groupReadyForBatch(group, activeBatchedGroupIds);
                const canValidate = !alreadyBatched && num(group.posted_step_count) === 0 && !["posted_to_sage", "posting_to_sage", "cancelled", "superseded", "reversed"].includes(status);
                const canSupersede = !["posted_to_sage", "posting_to_sage", "cancelled", "superseded", "reversed"].includes(status) && num(group.posted_step_count) === 0 && !alreadyBatched;
                return <details key={groupKey(group)} className="group rounded-2xl border border-slate-200 bg-white p-4 shadow-sm open:bg-slate-50"><summary className="flex cursor-pointer list-none items-start justify-between gap-3"><div className="flex items-start gap-3">{canBatch ? <input type="checkbox" name="posting_group_id" value={groupId} form="create-loyalty-internal-transfer-batch-form" defaultChecked data-accounting-row-select="true" className="mt-1 h-4 w-4 rounded border-slate-300" aria-label={`Select ${text(group.posting_group_ref)} for internal transfer Sage batch`} /> : <span className="mt-1 text-xs text-slate-300">-</span>}<div><p className="font-bold text-slate-950">{text(group.posting_group_ref) || "-"}</p><p className="mt-1 text-sm text-slate-500">Dr {walletLabel(contextValue(group, "destination_wallet_code"))} · Cr Main GBP bank</p><div className="mt-2 flex flex-wrap gap-2"><StatusBadge value={status} /><StatusBadge value={validationStatus} /><StatusBadge value={group.approval_status} />{alreadyBatched ? <StatusBadge value="already_batched" /> : null}</div></div></div><p className="text-right text-lg font-extrabold text-slate-950">{gbp(group.amount_gbp)}</p></summary><div className="mt-3 border-t border-slate-200 pt-3 text-sm text-slate-700">{text(group.blocker) ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 font-semibold text-rose-700">Blocker: {pretty(group.blocker)}</p> : null}<div className="mt-2 grid gap-2 text-xs text-slate-500 sm:grid-cols-3"><p>Posting date: {text(group.posting_date) || "-"}</p><p>Source OUT: {text(contextValue(group, "source_out_date")) || "-"}</p><p>Destination IN: {text(contextValue(group, "destination_in_date")) || "-"}</p></div><div className="mt-2 grid gap-2 text-xs text-slate-500 sm:grid-cols-3"><p>Released loyalty: {gbp(contextValue(group, "loyalty_released_amount_gbp"))}</p><p>Wallet excess: {gbp(contextValue(group, "excess_remaining_gbp"))}</p><p>Posted steps: {text(group.posted_step_count)} / {text(group.step_count)}</p></div><div className="mt-4 grid gap-2 sm:grid-cols-2">{canValidate ? <form action={validateCompletionLoyaltySageGroupAction}><HiddenGroupId group={group} /><button type="submit" className="w-full rounded-2xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-bold text-sky-800 hover:bg-sky-100">Revalidate</button></form> : null}{canSupersede ? <form action={supersedeCompletionLoyaltySageGroupAction}><HiddenGroupId group={group} /><input type="hidden" name="supersede_reason" value="Superseded from loyalty controls internal-transfer panel before Sage posting." /><button type="submit" className="w-full rounded-2xl border border-rose-200 bg-rose-50 px-3 py-2 text-xs font-bold text-rose-700 hover:bg-rose-100">Supersede</button></form> : null}</div></div></details>;
              })}
            </div>
          </div>
        </div>
      ) : null}

      {visibleBatches.length > 0 ? <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="font-bold text-slate-950">CLITB Sage batches</h3><p className="mt-1 text-xs leading-5 text-slate-500">A CLITB batch wraps one or more CLIT groups. Open it to approve, post, review Sage responses, or retry failed journal steps.</p></div><StatusBadge value={`${visibleBatches.length}_batch_rows`} /></div><div className="mt-4 grid gap-2 md:grid-cols-2 xl:grid-cols-3">{visibleBatches.map((batch) => <Link key={text(batch.batch_id)} href={batchLink(batch.batch_id)} className="rounded-2xl border border-slate-200 bg-white p-4 text-sm shadow-sm hover:border-cyan-300 hover:bg-cyan-50"><div className="flex items-start justify-between gap-3"><div><p className="font-bold text-slate-950">{text(batch.batch_ref)}</p><div className="mt-2 flex flex-wrap gap-2"><StatusBadge value={batch.status} /><StatusBadge value={batch.approval_status} />{batchReadyToApprove(batch) ? <StatusBadge value="ready_to_approve" /> : null}{batchReadyToPost(batch) ? <StatusBadge value="ready_to_post" /> : null}</div></div><p className="text-right font-extrabold text-slate-950">{gbp(batch.total_amount_gbp)}</p></div><p className="mt-3 text-xs text-slate-500">Rows: {text(batch.row_count)} · Posted: {text(batch.posted_count)} · Failed: {text(batch.failed_count)}</p></Link>)}</div></div> : batches.length > 0 && !showSourceSections ? <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-500">No internal-transfer batches match this status filter.</div> : null}
    </section>
  );
}
