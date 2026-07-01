import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

type Props = {
  searchQuery?: string;
  statusFilter?: string;
};

type QueueRow = {
  key: string;
  lane: "applied_settlement" | "internal_transfer";
  status: "ready_to_materialise" | "ready_to_batch" | "ready_to_post" | "blocked" | "batched_or_posted";
  title: string;
  detail: string;
  amount: number;
  nextAction: string;
  href: string;
  blocker?: string;
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
  return raw ? raw.replaceAll("_", " ") : "-";
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function visibleBlocker(value: unknown) {
  const raw = text(value);
  const lower = raw.toLowerCase();
  if (!raw) return "";
  if (lower.startsWith("ready")) return "";
  if (lower.includes("mapping endpoint idempotency logging and reversal contract not locked")) return "";
  if (lower.includes("preview only mapping not confirmed")) return "";
  return raw;
}

function laneLabel(lane: QueueRow["lane"]) {
  if (lane === "internal_transfer") return "Bank internal transfer";
  return "Applied loyalty settlement";
}

function statusLabel(status: QueueRow["status"]) {
  if (status === "ready_to_materialise") return "Ready to materialise";
  if (status === "ready_to_batch") return "Ready to batch";
  if (status === "ready_to_post") return "Ready to post";
  if (status === "blocked") return "Blocked";
  return "Batched / posted";
}

function statusTone(status: QueueRow["status"]) {
  if (status === "blocked") return "border-amber-200 bg-amber-50 text-amber-900";
  if (status === "ready_to_batch" || status === "ready_to_materialise" || status === "ready_to_post") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function statusMatches(row: QueueRow, filter: string) {
  if (!filter || filter === "all") return true;
  if (filter === "needs_action") return row.status !== "batched_or_posted" || row.nextAction.toLowerCase().includes("review");
  return row.status === filter;
}

function groupReadyForBatch(group: Row, activeBatchedGroupIds: Set<string>) {
  const status = text(group.status);
  const validationStatus = text(group.validation_status);
  return ["locally_validated", "admin_approved"].includes(status)
    && ["ok_to_post", "warning_only"].includes(validationStatus)
    && !text(group.blocker)
    && num(group.posted_step_count) === 0
    && !activeBatchedGroupIds.has(text(group.posting_group_id));
}

function batchReadyToPost(batch: Row) {
  const status = text(batch.status);
  const approvalStatus = text(batch.approval_status);
  return approvalStatus === "approved"
    && ["approved", "failed_retryable", "partially_posted_needs_review"].includes(status)
    && num(batch.row_count) > 0;
}

function batchNeedsReview(batch: Row) {
  const status = text(batch.status);
  return ["blocked", "failed_terminal"].includes(status)
    || num(batch.failed_count) > 0;
}

function rowSearch(...values: unknown[]) {
  for (const value of values) {
    const raw = text(value).trim();
    if (raw) return raw;
  }
  return "";
}

function laneHref(lane: "applied_settlement" | "internal_transfer", searchQuery: string, anchor: string, focusedSearch?: string) {
  const params = new URLSearchParams();
  const cleanSearch = (focusedSearch ?? searchQuery).trim();
  if (cleanSearch) params.set("q", cleanSearch);
  params.set("lane", lane);
  return `/internal/accounting-command-centre/loyalty-controls?${params.toString()}#${anchor}`;
}

export default async function CompletionLoyaltyActionQueuePanel({ searchQuery = "", statusFilter = "needs_action" }: Props) {
  const supabase = await createClient();
  const cleanSearch = searchQuery.trim() || null;

  const [
    { data: appliedPreviewData, error: appliedPreviewError },
    { data: transferCandidateData, error: transferCandidateError },
    { data: groupData, error: groupError },
    { data: batchData, error: batchError },
  ] = await Promise.all([
    (supabase as any).rpc("internal_completion_loyalty_applied_accounting_preview_v1", {
      p_search: cleanSearch,
      p_limit: 300,
      p_offset: 0,
    }),
    (supabase as any).rpc("internal_completion_loyalty_internal_transfer_candidates_v1", {
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

  const allGroups = ((groupData ?? []) as Row[]);
  const appliedGroups = allGroups.filter((row) => text(row.posting_group_type) === "completion_loyalty_applied_settlement");
  const transferGroups = allGroups.filter((row) => text(row.posting_group_type) === "completion_loyalty_internal_transfer_journal");
  const allBatches = ((batchData ?? []) as Row[]);
  const appliedBatches = allBatches.filter((row) => text(row.batch_type) === "completion_loyalty_applied_settlement");
  const transferBatches = allBatches.filter((row) => text(row.batch_type) === "completion_loyalty_internal_transfer_journal");

  const activeBatchedGroupIds = new Set(
    allBatches
      .filter((row) => activeBatchStatuses.has(text(row.status)))
      .flatMap((row) => asArray(row.posting_group_ids).map(text))
      .filter(Boolean),
  );
  const activeAppliedEventIds = new Set(
    appliedGroups
      .filter((row) => !["cancelled", "superseded", "reversed"].includes(text(row.status)))
      .map((row) => text(row.order_funding_event_id))
      .filter(Boolean),
  );

  const queueRows: QueueRow[] = [];

  for (const row of ((appliedPreviewData ?? []) as Row[])) {
    if (activeAppliedEventIds.has(text(row.order_funding_event_id))) continue;
    const blocker = visibleBlocker(row.blocker) || visibleBlocker(row.readiness_status);
    const focus = rowSearch(row.order_funding_event_id, row.order_ref, row.source_id);
    queueRows.push({
      key: `applied-preview-${text(row.order_funding_event_id) || text(row.source_id)}`,
      lane: "applied_settlement",
      status: blocker ? "blocked" : "ready_to_materialise",
      title: text(row.order_ref) || "Applied loyalty settlement",
      detail: text(row.importer_name) || "Importer/customer",
      amount: num(row.amount_gbp),
      nextAction: blocker ? "Open applied blocker" : "Open applied lane",
      href: laneHref("applied_settlement", searchQuery, "step-3-lifecycle", focus),
      blocker,
    });
  }

  for (const row of ((transferCandidateData ?? []) as Row[])) {
    const blocker = text(row.blocker);
    const alreadyMaterialised = Boolean(text(row.existing_posting_group_id));
    if (alreadyMaterialised) continue;
    const focus = rowSearch(row.source_out_reference, row.destination_in_reference, row.importer_name);
    queueRows.push({
      key: `transfer-candidate-${text(row.source_out_statement_line_id)}-${text(row.destination_in_statement_line_id)}`,
      lane: "internal_transfer",
      status: blocker ? "blocked" : "ready_to_materialise",
      title: text(row.importer_name) || "Internal bank transfer",
      detail: `Dr ${pretty(row.destination_wallet_code)}; Cr Main GBP bank`,
      amount: num(row.transfer_amount_gbp),
      nextAction: blocker ? "Open transfer blocker" : "Open transfer lane",
      href: laneHref("internal_transfer", searchQuery, "step-3-internal-transfer", focus),
      blocker,
    });
  }

  for (const group of [...appliedGroups, ...transferGroups]) {
    const isTransfer = text(group.posting_group_type) === "completion_loyalty_internal_transfer_journal";
    const groupFocus = rowSearch(group.posting_group_ref, group.order_ref, group.posting_group_id);
    if (groupReadyForBatch(group, activeBatchedGroupIds)) {
      queueRows.push({
        key: `group-ready-${text(group.posting_group_id)}`,
        lane: isTransfer ? "internal_transfer" : "applied_settlement",
        status: "ready_to_batch",
        title: text(group.posting_group_ref) || "Posting group",
        detail: isTransfer ? "Validated internal-transfer journal group" : text(group.order_ref) || "Validated applied-loyalty settlement group",
        amount: num(group.amount_gbp),
        nextAction: isTransfer ? "Open transfer batching lane" : "Open applied batching lane",
        href: isTransfer
          ? laneHref("internal_transfer", searchQuery, "step-3-internal-transfer", groupFocus)
          : laneHref("applied_settlement", searchQuery, "step-3-lifecycle", groupFocus),
      });
    } else if (text(group.blocker)) {
      queueRows.push({
        key: `group-blocked-${text(group.posting_group_id)}`,
        lane: isTransfer ? "internal_transfer" : "applied_settlement",
        status: "blocked",
        title: text(group.posting_group_ref) || "Blocked posting group",
        detail: isTransfer ? "Internal-transfer journal group" : text(group.order_ref) || "Applied-loyalty settlement group",
        amount: num(group.amount_gbp),
        nextAction: "Open group / revalidate",
        href: isTransfer
          ? laneHref("internal_transfer", searchQuery, "step-3-internal-transfer", groupFocus)
          : laneHref("applied_settlement", searchQuery, "step-3-lifecycle", groupFocus),
        blocker: text(group.blocker),
      });
    }
  }

  for (const batch of [...appliedBatches, ...transferBatches]) {
    const isTransfer = text(batch.batch_type) === "completion_loyalty_internal_transfer_journal";
    const batchPath = `/internal/accounting-command-centre/loyalty-controls/batches/${text(batch.batch_id)}`;
    if (batchReadyToPost(batch)) {
      queueRows.push({
        key: `batch-ready-post-${text(batch.batch_id)}`,
        lane: isTransfer ? "internal_transfer" : "applied_settlement",
        status: "ready_to_post",
        title: text(batch.batch_ref) || "Sage batch",
        detail: `${text(batch.status) || "approved"} · ${text(batch.row_count) || "0"} row(s)`,
        amount: num(batch.total_amount_gbp),
        nextAction: "Open batch to post",
        href: batchPath,
        blocker: text(batch.last_posting_error),
      });
      continue;
    }

    if (!batchNeedsReview(batch)) continue;
    queueRows.push({
      key: `batch-review-${text(batch.batch_id)}`,
      lane: isTransfer ? "internal_transfer" : "applied_settlement",
      status: "batched_or_posted",
      title: text(batch.batch_ref) || "Sage batch",
      detail: `${text(batch.status) || "batch"} · ${text(batch.row_count) || "0"} row(s)`,
      amount: num(batch.total_amount_gbp),
      nextAction: "Open batch review / retry page",
      href: batchPath,
      blocker: text(batch.last_posting_error),
    });
  }

  const filteredRows = queueRows
    .filter((row) => statusMatches(row, statusFilter))
    .sort((a, b) => {
      const order = { blocked: 0, ready_to_materialise: 1, ready_to_batch: 2, ready_to_post: 3, batched_or_posted: 4 } as const;
      return order[a.status] - order[b.status] || b.amount - a.amount;
    });

  const appliedCount = queueRows.filter((row) => row.lane === "applied_settlement").length;
  const transferCount = queueRows.filter((row) => row.lane === "internal_transfer").length;
  const blockedCount = queueRows.filter((row) => row.status === "blocked").length;
  const postCount = queueRows.filter((row) => row.status === "ready_to_post").length;
  const readyCount = queueRows.filter((row) => row.status === "ready_to_materialise" || row.status === "ready_to_batch").length;
  const reviewCount = queueRows.filter((row) => row.status === "batched_or_posted").length;
  const totalAmount = filteredRows.reduce((sum, row) => sum + row.amount, 0);

  return (
    <section id="action-queue" className="max-w-full overflow-hidden rounded-3xl border border-slate-200 bg-white p-4 shadow-sm scroll-mt-6 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-slate-500">Action queue</p>
          <h2 className="mt-2 text-xl font-semibold text-slate-950">Items needing accounting attention</h2>
          <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
            Operational view across both loyalty Sage lanes. Queue links open the relevant lane and filter to the row where possible; real materialise, batch, approve and post actions stay inside the existing lane/batch controls.
          </p>
        </div>
        <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm font-semibold text-slate-800 ring-1 ring-slate-200">
          {filteredRows.length} shown · {gbp(totalAmount)}<br />
          {readyCount} ready · {postCount} post · {blockedCount} blocked · {reviewCount} review
        </div>
      </div>

      {(appliedPreviewError || transferCandidateError || groupError || batchError) ? (
        <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">
          Queue partially unavailable: {[appliedPreviewError?.message, transferCandidateError?.message, groupError?.message, batchError?.message].filter(Boolean).join(" | ")}
        </div>
      ) : null}

      <div className="mt-4 grid gap-3 sm:grid-cols-5">
        <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Ready</p>
          <p className="mt-1 text-xl font-extrabold">{readyCount}</p>
        </div>
        <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Ready to post</p>
          <p className="mt-1 text-xl font-extrabold">{postCount}</p>
        </div>
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Blocked</p>
          <p className="mt-1 text-xl font-extrabold">{blockedCount}</p>
        </div>
        <div className="rounded-2xl border border-sky-200 bg-sky-50 p-3 text-sm text-sky-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Applied settlement</p>
          <p className="mt-1 text-xl font-extrabold">{appliedCount}</p>
        </div>
        <div className="rounded-2xl border border-cyan-200 bg-cyan-50 p-3 text-sm text-cyan-950">
          <p className="text-xs font-bold uppercase tracking-wide opacity-70">Internal transfer</p>
          <p className="mt-1 text-xl font-extrabold">{transferCount}</p>
        </div>
      </div>

      <div className="mt-4 grid gap-3 md:hidden">
        {filteredRows.length === 0 ? (
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-center text-sm text-slate-500">
            No queue rows match the current filters.
          </div>
        ) : filteredRows.map((row) => (
          <article key={row.key} className="min-w-0 rounded-2xl border border-slate-200 bg-white p-3 shadow-sm">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">{laneLabel(row.lane)}</p>
                <p className="mt-1 break-words text-sm font-extrabold text-slate-950">{row.title}</p>
                <p className="mt-1 break-words text-xs text-slate-500">{row.detail}</p>
              </div>
              <p className="shrink-0 text-right text-sm font-extrabold text-slate-950">{gbp(row.amount)}</p>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-2">
              <span className={`inline-flex rounded-full border px-2.5 py-1 text-[11px] font-bold ${statusTone(row.status)}`}>{statusLabel(row.status)}</span>
              <Link href={row.href} className="text-xs font-bold text-sky-700 hover:text-sky-900">
                {row.nextAction}
              </Link>
            </div>
            {row.blocker ? <p className="mt-2 break-words rounded-xl border border-amber-200 bg-amber-50 p-2 text-xs font-semibold text-amber-800">{pretty(row.blocker)}</p> : null}
          </article>
        ))}
      </div>

      <div className="mt-4 hidden overflow-x-auto rounded-2xl border border-slate-200 md:block">
        <table className="min-w-[980px] divide-y divide-slate-200 text-sm">
          <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2 text-left">Lane</th>
              <th className="px-3 py-2 text-left">Item</th>
              <th className="px-3 py-2 text-left">Status</th>
              <th className="px-3 py-2 text-right">Amount</th>
              <th className="px-3 py-2 text-left">Next action</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {filteredRows.length === 0 ? (
              <tr>
                <td colSpan={5} className="px-3 py-6 text-center text-sm text-slate-500">
                  No queue rows match the current filters.
                </td>
              </tr>
            ) : filteredRows.map((row) => (
              <tr key={row.key} className="align-top hover:bg-slate-50">
                <td className="px-3 py-3 text-xs font-bold text-slate-600">{laneLabel(row.lane)}</td>
                <td className="px-3 py-3">
                  <p className="font-bold text-slate-950">{row.title}</p>
                  <p className="mt-1 text-xs text-slate-500">{row.detail}</p>
                  {row.blocker ? <p className="mt-1 text-xs font-semibold text-amber-800">{pretty(row.blocker)}</p> : null}
                </td>
                <td className="px-3 py-3">
                  <span className={`inline-flex rounded-full border px-2.5 py-1 text-[11px] font-bold ${statusTone(row.status)}`}>{statusLabel(row.status)}</span>
                </td>
                <td className="px-3 py-3 text-right font-bold text-slate-950">{gbp(row.amount)}</td>
                <td className="px-3 py-3">
                  <Link href={row.href} className="text-xs font-bold text-sky-700 hover:text-sky-900">
                    {row.nextAction}
                  </Link>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
