import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import SelectionControls from "./SelectionControls";
import {
  approveCompletionLoyaltySageGroupAction,
  createCompletionLoyaltySageBatchAction,
  materialiseAppliedLoyaltySettlementAction,
  supersedeCompletionLoyaltySageGroupAction,
  validateCompletionLoyaltySageGroupAction,
} from "./loyalty-controls/actions";

type Row = Record<string, unknown>;

type Props = {
  searchQuery?: string;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const activeBatchStatuses = new Set([
  "draft",
  "validated",
  "blocked",
  "approved",
  "posting_to_sage",
  "partially_posted_needs_review",
  "failed_retryable",
  "failed_terminal",
]);

const stepOrder = new Map([
  ["loyalty_customer_receipt", 1],
  ["loyalty_customer_allocation", 2],
  ["loyalty_clearing_offset", 3],
]);

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

function asObject(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function rowKey(row: Row) {
  return text(row.order_funding_event_id) || text(row.source_id) || `${text(row.order_ref)}-${text(row.amount_gbp)}`;
}

function groupKey(row: Row) {
  return text(row.posting_group_id) || text(row.posting_group_ref) || `${text(row.order_ref)}-${text(row.amount_gbp)}`;
}

function orderedSteps(value: unknown) {
  return asArray(value).slice().sort((a, b) => {
    const left = asObject(a);
    const right = asObject(b);
    return (stepOrder.get(text(left.step_type)) ?? 99) - (stepOrder.get(text(right.step_type)) ?? 99);
  });
}

function stepLabel(value: unknown) {
  const raw = text(value);
  if (raw === "loyalty_customer_receipt") return "Create loyalty receipt";
  if (raw === "loyalty_customer_allocation") return "Allocate receipt to invoice";
  if (raw === "loyalty_clearing_offset") return "Clear loyalty bank to expense";
  return pretty(raw);
}

function stepPlainMeaning(value: unknown) {
  const raw = text(value);
  if (raw === "loyalty_customer_receipt") return "Creates the non-cash loyalty receipt on the customer account.";
  if (raw === "loyalty_customer_allocation") return "Matches that receipt against the posted Sage customer invoice.";
  if (raw === "loyalty_clearing_offset") return "Moves the clearing balance to loyalty reward expense.";
  return "Controlled Sage posting step.";
}

function badgeTone(status: string) {
  if (["blocked", "failed_terminal", "stale_reapproval_required", "invalidated"].includes(status)) return "border-rose-200 bg-rose-50 text-rose-700";
  if (["admin_approved", "approved", "posted_to_sage", "ok_to_post"].includes(status)) return "border-emerald-200 bg-emerald-50 text-emerald-700";
  if (["partially_posted_needs_review", "warning_only"].includes(status)) return "border-amber-200 bg-amber-50 text-amber-700";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function StatusBadge({ value }: { value: unknown }) {
  const raw = text(value) || "unknown";
  return <span className={`inline-flex rounded-full border px-2.5 py-1 text-[11px] font-bold ${badgeTone(raw)}`}>{pretty(raw)}</span>;
}

function HiddenGroupId({ group }: { group: Row }) {
  return <input type="hidden" name="posting_group_id" value={text(group.posting_group_id)} />;
}

function batchLink(batchId: unknown) {
  return `/internal/accounting-command-centre/loyalty-controls/batches/${text(batchId)}`;
}

export default async function CompletionLoyaltySagePostingMaterialisationPanel({ searchQuery = "" }: Props) {
  const supabase = await createClient();
  const cleanSearch = searchQuery.trim() || null;

  const [
    { data: previewData, error: previewError },
    { data: groupData, error: groupError },
    { data: batchData, error: batchError },
  ] = await Promise.all([
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
    (supabase as any).rpc("internal_completion_loyalty_sage_batches_v1", {
      p_search: cleanSearch,
      p_status: "all",
      p_limit: 100,
      p_offset: 0,
    }),
  ]);

  const groups = ((groupData ?? []) as Row[]).filter((row) => text(row.posting_group_type) === "completion_loyalty_applied_settlement");
  const batches = ((batchData ?? []) as Row[]).filter((row) => text(row.batch_type) === "completion_loyalty_applied_settlement");
  const activeBatchedGroupIds = new Set(
    batches
      .filter((row) => activeBatchStatuses.has(text(row.status)))
      .flatMap((row) => asArray(row.posting_group_ids).map(text))
      .filter(Boolean),
  );
  const activeGroupedEventIds = new Set(
    groups
      .filter((row) => !["cancelled", "superseded", "reversed"].includes(text(row.status)))
      .map((row) => text(row.order_funding_event_id))
      .filter(Boolean),
  );
  const previews = ((previewData ?? []) as Row[]).filter((row) => !activeGroupedEventIds.has(text(row.order_funding_event_id)));
  const totalPreviewAmount = previews.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const totalGroupAmount = groups.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const batchReadyGroups = groups.filter((group) => {
    const status = text(group.status);
    const validationStatus = text(group.validation_status);
    return ["locally_validated", "admin_approved"].includes(status)
      && ["ok_to_post", "warning_only"].includes(validationStatus)
      && !text(group.blocker)
      && num(group.posted_step_count) === 0
      && !activeBatchedGroupIds.has(text(group.posting_group_id));
  });
  const batchReadyAmount = batchReadyGroups.reduce((sum, group) => sum + num(group.amount_gbp), 0);

  return (
    <section id="step-3-lifecycle" className="rounded-3xl border border-emerald-200 bg-white p-5 shadow-sm scroll-mt-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-emerald-600">Step 3 · Sage posting lifecycle actions</p>
          <h2 className="mt-2 text-xl font-semibold text-slate-950">Freeze, batch, approve and post</h2>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            This is the action lane. Step 2 eligible applied-loyalty rows are materialised into local Sage groups first. Locally validated groups are batched, approved, then posted through the controlled loyalty Sage adapter. VAT rows are not created here.
          </p>
        </div>
        <div className="rounded-2xl bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-950 ring-1 ring-emerald-200">
          {previews.length} new candidates · {gbp(totalPreviewAmount)}<br />
          {groups.length} lifecycle groups · {gbp(totalGroupAmount)}<br />
          {batches.length} batch(es) · {batchReadyGroups.length} group(s) ready to batch
        </div>
      </div>

      {previewError ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Applied-loyalty preview RPC unavailable: {previewError.message}
        </div>
      ) : null}
      {groupError ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Posting lifecycle RPC unavailable: {groupError.message}. Run the lifecycle controls migration before using this section.
        </div>
      ) : null}
      {batchError ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Loyalty Sage batch RPC unavailable: {batchError.message}. Run the batch controls migration before using batch creation.
        </div>
      ) : null}

      <div className="mt-5 grid gap-4 xl:grid-cols-2">
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <h3 className="font-bold text-slate-950">Candidates not yet materialised</h3>
          <p className="mt-1 text-xs leading-5 text-slate-500">Safe first action only. This freezes a local lifecycle group and payload steps; it does not approve, batch or post.</p>
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
                    Materialise / freeze
                  </button>
                </form>
              </div>
            ))}
          </div>
        </div>

        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 className="font-bold text-slate-950">Lifecycle posting groups</h3>
              <p className="mt-1 text-xs leading-5 text-slate-500">Local groups only. Select locally validated groups and create a loyalty Sage batch before approval/posting.</p>
            </div>
            <div className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-right text-xs font-bold text-emerald-900">
              {batchReadyGroups.length} ready<br />{gbp(batchReadyAmount)}
            </div>
          </div>

          <form id="create-loyalty-sage-batch-form" action={createCompletionLoyaltySageBatchAction} className="mt-3 rounded-2xl border border-emerald-200 bg-white p-3">
            <div className="grid gap-2 sm:grid-cols-[1fr_auto] sm:items-end">
              <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
                Batch note
                <input name="batch_notes" placeholder="Optional batch note" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" />
              </label>
              <button type="submit" className="rounded-xl bg-emerald-700 px-4 py-2 text-xs font-bold text-white hover:bg-emerald-800 disabled:bg-slate-200 disabled:text-slate-500">
                Create loyalty Sage batch
              </button>
            </div>
            <div className="mt-3">
              <SelectionControls />
            </div>
          </form>

          <div className="mt-4 space-y-2">
            {groups.length === 0 ? (
              <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-500">No materialised applied-loyalty posting groups yet.</div>
            ) : groups.map((group) => {
              const targets = asArray(group.target_allocation_json);
              const steps = orderedSteps(group.steps_json);
              const status = text(group.status);
              const validationStatus = text(group.validation_status);
              const approvalStatus = text(group.approval_status);
              const groupId = text(group.posting_group_id);
              const alreadyBatched = activeBatchedGroupIds.has(groupId);
              const canValidate = !["posted_to_sage", "posting_to_sage", "cancelled", "superseded", "reversed"].includes(status);
              const canApprove = status === "locally_validated" && ["ok_to_post", "warning_only"].includes(validationStatus) && !text(group.blocker);
              const canSupersede = !["posted_to_sage", "posting_to_sage", "cancelled", "superseded", "reversed"].includes(status) && num(group.posted_step_count) === 0 && !alreadyBatched;
              const canBatch = ["locally_validated", "admin_approved"].includes(status) && ["ok_to_post", "warning_only"].includes(validationStatus) && !text(group.blocker) && num(group.posted_step_count) === 0 && !alreadyBatched;
              return (
                <details key={groupKey(group)} className="group rounded-2xl border border-slate-200 bg-white p-4 shadow-sm open:bg-slate-50">
                  <summary className="flex cursor-pointer list-none items-start justify-between gap-3">
                    <div className="flex items-start gap-3">
                      {canBatch ? (
                        <input
                          type="checkbox"
                          name="posting_group_id"
                          value={groupId}
                          form="create-loyalty-sage-batch-form"
                          defaultChecked
                          data-accounting-row-select="true"
                          className="mt-1 h-4 w-4 rounded border-slate-300"
                          aria-label={`Select ${text(group.posting_group_ref)} for loyalty Sage batch`}
                        />
                      ) : <span className="mt-1 text-xs text-slate-300">—</span>}
                      <div>
                        <p className="font-bold text-slate-950">{text(group.posting_group_ref) || "—"}</p>
                        <p className="mt-1 text-sm text-slate-500">{text(group.order_ref) || "—"} · {text(group.importer_name) || "Importer/customer"}</p>
                        <div className="mt-2 flex flex-wrap gap-2">
                          <StatusBadge value={status} />
                          <StatusBadge value={validationStatus} />
                          <StatusBadge value={approvalStatus} />
                          {alreadyBatched ? <StatusBadge value="already_batched" /> : null}
                        </div>
                      </div>
                    </div>
                    <div className="text-right">
                      <p className="text-lg font-extrabold text-slate-950">{gbp(group.amount_gbp)}</p>
                      <p className="mt-1 text-[11px] font-semibold text-slate-500">{text(group.step_count)} step(s) · {text(group.posted_step_count)} posted</p>
                    </div>
                  </summary>
                  <div className="mt-3 border-t border-slate-200 pt-3 text-sm text-slate-700">
                    {text(group.blocker) ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 font-semibold text-rose-700">Blocker: {pretty(group.blocker)}</p> : null}
                    <p className="mt-2 text-xs text-slate-500">Posting date: {text(group.posting_date) || "—"}</p>
                    <p className="mt-2 text-xs font-semibold text-slate-600">Target customer invoice allocation(s):</p>
                    <ul className="mt-1 space-y-1 text-xs text-slate-500">
                      {targets.length === 0 ? <li>—</li> : targets.map((target, index) => {
                        const targetObj = asObject(target);
                        return (
                          <li key={`${text(targetObj.target_sage_invoice_id)}-${index}`}>
                            {text(targetObj.target_order_ref) || "Customer invoice"}: {gbp(targetObj.allocation_amount_gbp)}
                          </li>
                        );
                      })}
                    </ul>

                    <p className="mt-4 text-xs font-semibold text-slate-600">Sage posting steps:</p>
                    <div className="mt-2 space-y-2">
                      {steps.length === 0 ? <p className="text-xs text-slate-500">No steps were created because the group is blocked.</p> : steps.map((step, index) => {
                        const stepObj = asObject(step);
                        return (
                          <div key={`${text(stepObj.step_type)}-${index}`} className="rounded-2xl border border-slate-200 bg-white p-3 text-xs">
                            <div className="flex flex-wrap items-center justify-between gap-2">
                              <span className="font-bold text-slate-800">{stepLabel(stepObj.step_type)}</span>
                              <StatusBadge value={stepObj.status} />
                            </div>
                            <p className="mt-1 text-slate-500">{stepPlainMeaning(stepObj.step_type)}</p>
                            {text(stepObj.last_error) ? <p className="mt-1 font-semibold text-rose-700">{text(stepObj.last_error)}</p> : null}
                          </div>
                        );
                      })}
                    </div>

                    <div className="mt-4 grid gap-2 sm:grid-cols-3">
                      {canValidate ? (
                        <form action={validateCompletionLoyaltySageGroupAction}>
                          <HiddenGroupId group={group} />
                          <button type="submit" className="w-full rounded-2xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-bold text-sky-800 hover:bg-sky-100">
                            Revalidate
                          </button>
                        </form>
                      ) : null}
                      {canApprove ? (
                        <form action={approveCompletionLoyaltySageGroupAction}>
                          <HiddenGroupId group={group} />
                          <input type="hidden" name="approval_notes" value="Approved from loyalty controls lifecycle panel." />
                          <button type="submit" className="w-full rounded-2xl bg-emerald-700 px-3 py-2 text-xs font-bold text-white hover:bg-emerald-800">
                            Admin approve group
                          </button>
                        </form>
                      ) : null}
                      {canSupersede ? (
                        <form action={supersedeCompletionLoyaltySageGroupAction} className="sm:col-span-1">
                          <HiddenGroupId group={group} />
                          <input type="hidden" name="supersede_reason" value="Superseded from loyalty controls lifecycle panel before Sage posting." />
                          <button type="submit" className="w-full rounded-2xl border border-rose-200 bg-rose-50 px-3 py-2 text-xs font-bold text-rose-700 hover:bg-rose-100">
                            Supersede
                          </button>
                        </form>
                      ) : null}
                    </div>
                  </div>
                </details>
              );
            })}
          </div>
        </div>
      </div>

      <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 className="font-bold text-slate-950">Loyalty Sage batch history</h3>
            <p className="mt-1 text-xs leading-5 text-slate-500">Open a batch to approve, post, review Sage responses, or retry failed steps only.</p>
          </div>
          <StatusBadge value={batchError ? "batch_rpc_unavailable" : `${batches.length}_batch_rows`} />
        </div>
        <div className="mt-4 grid gap-2 md:grid-cols-2 xl:grid-cols-3">
          {batches.length === 0 ? (
            <div className="rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-500 md:col-span-2 xl:col-span-3">No loyalty Sage batches yet.</div>
          ) : batches.map((batch) => (
            <Link key={text(batch.batch_id)} href={batchLink(batch.batch_id)} className="rounded-2xl border border-slate-200 bg-white p-4 text-sm shadow-sm hover:border-emerald-300 hover:bg-emerald-50">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="font-bold text-slate-950">{text(batch.batch_ref)}</p>
                  <div className="mt-2 flex flex-wrap gap-2">
                    <StatusBadge value={batch.status} />
                    <StatusBadge value={batch.approval_status} />
                  </div>
                </div>
                <p className="text-right font-extrabold text-slate-950">{gbp(batch.total_amount_gbp)}</p>
              </div>
              <p className="mt-3 text-xs text-slate-500">Rows: {text(batch.row_count)} · Posted: {text(batch.posted_count)} · Failed: {text(batch.failed_count)}</p>
            </Link>
          ))}
        </div>
      </div>
    </section>
  );
}
