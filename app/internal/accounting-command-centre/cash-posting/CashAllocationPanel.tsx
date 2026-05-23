import SelectionControls from "../SelectionControls";
import { createClient } from "@/utils/supabase/server";
import { postSelectedCashAllocationsAction } from "./actions";

type Row = Record<string, unknown>;

type Candidate = {
  id: string;
  status: string;
  blocker: string;
  orderRef: string;
  counterparty: string;
  receiptAmount: number;
  targetAmount: number;
  allocationAmount: number;
  residualAmount: number;
  contactId: string;
  receiptId: string;
  paymentOnAccountId: string;
  targetInvoiceId: string;
  targetReference: string;
  authRef: string;
  shortReference: string;
  trace: Row;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

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

function money(value: unknown) {
  return gbpFormatter.format(num(value));
}

function short(value: unknown, max = 48) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function getPath(value: unknown, path: Array<string | number>): unknown {
  let current = value;
  for (const part of path) {
    if (typeof part === "number") {
      if (!Array.isArray(current)) return undefined;
      current = current[part];
    } else {
      if (!current || typeof current !== "object" || Array.isArray(current)) return undefined;
      current = (current as Row)[part];
    }
  }
  return current;
}

function firstText(value: unknown, paths: Array<Array<string | number>>) {
  for (const path of paths) {
    const found = text(getPath(value, path));
    if (found) return found;
  }
  return "";
}

function statusClass(status: string) {
  if (status === "ready") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (status === "allocated") return "border-sky-200 bg-sky-50 text-sky-900";
  if (status === "failed") return "border-rose-200 bg-rose-50 text-rose-900";
  return "border-amber-200 bg-amber-50 text-amber-900";
}

function buildCandidate(row: Row, cashSnapshot: Row | undefined, cashBatch: Row | undefined, targets: Row[]): Candidate {
  const snap = cashSnapshot ?? {};
  const amount = num(row.amount_gbp);
  const alreadyAllocated = num(row.sage_allocation_amount_gbp) || num(snap.sage_allocation_amount_gbp);
  const existingAllocationStatus = text(row.sage_allocation_status) || text(snap.sage_allocation_status) || "not_allocated";
  const orderId = text(snap.order_id);
  const matchingTargets = targets.filter((target) => text(target.order_id) === orderId);
  const target = matchingTargets[0] ?? {};
  const targetAmount = num(target.amount_gbp);
  const targetContactId = firstText(target.resolved_payload, [["sage_header", "contact_id"], ["customer_target", "sage_contact_id"]]);
  const contactId = text(snap.sage_contact_id);
  const receiptId = text(row.sage_object_id) || text(snap.sage_object_id);
  const paymentOnAccountId = text(row.sage_payment_on_account_id) || text(snap.sage_payment_on_account_id);
  const targetInvoiceId = text(target.sage_invoice_id);
  const allocationAmount = Math.round(Math.min(Math.max(amount - alreadyAllocated, 0), Math.max(targetAmount, 0)) * 100) / 100;
  const residualAmount = Math.round((amount - allocationAmount) * 100) / 100;

  let status = "ready";
  let blocker = "";

  if (existingAllocationStatus === "allocated") {
    status = "allocated";
    blocker = "already allocated";
  } else if (existingAllocationStatus.startsWith("failed")) {
    status = "failed";
    blocker = text(row.sage_allocation_error_message) || text(snap.sage_allocation_error_message) || "allocation previously failed";
  } else if (!["posted", "posted_needs_review"].includes(text(row.posting_status))) {
    status = "blocked";
    blocker = "receipt has not been posted to Sage";
  } else if (!receiptId) {
    status = "blocked";
    blocker = "receipt Sage contact_payment id missing";
  } else if (!paymentOnAccountId) {
    status = "blocked";
    blocker = "receipt payment_on_account id missing";
  } else if (matchingTargets.length === 0) {
    status = "blocked";
    blocker = "matched sales invoice has not been posted to Sage";
  } else if (matchingTargets.length > 1) {
    status = "blocked";
    blocker = "multiple posted sales invoices found for this order";
  } else if (!targetInvoiceId) {
    status = "blocked";
    blocker = "target Sage sales invoice id missing";
  } else if (!targetContactId) {
    status = "blocked";
    blocker = "target Sage contact id missing";
  } else if (targetContactId !== contactId) {
    status = "blocked";
    blocker = "receipt/contact mismatch";
  } else if (allocationAmount <= 0) {
    status = "blocked";
    blocker = "no positive amount available to allocate";
  }

  return {
    id: text(row.id),
    status,
    blocker,
    orderRef: text(snap.order_ref),
    counterparty: text(snap.counterparty_name),
    receiptAmount: amount,
    targetAmount,
    allocationAmount,
    residualAmount,
    contactId,
    receiptId,
    paymentOnAccountId,
    targetInvoiceId,
    targetReference: text(target.reference_text) || text(target.order_ref) || targetInvoiceId,
    authRef: text(asObject(snap.internal_reference_json).auth_ref) || text(asObject(snap.internal_reference_json).reference_raw),
    shortReference: text(snap.short_reference) || text(row.sage_reference),
    trace: {
      cash_batch_ref: text(cashBatch?.batch_ref),
      cash_batch_row_id: text(row.id),
      cash_snapshot_id: text(row.snapshot_id),
      order_id: orderId,
      order_ref: text(snap.order_ref),
      receipt_sage_object_id: receiptId,
      payment_on_account_id: paymentOnAccountId,
      target_sage_invoice_id: targetInvoiceId,
      target_snapshot_id: text(target.id),
      receipt_amount_gbp: amount,
      target_invoice_amount_gbp: targetAmount,
      allocation_amount_gbp: allocationAmount,
      residual_gbp: residualAmount,
    },
  };
}

export default async function CashAllocationPanel() {
  const supabase = await createClient();

  const { data: rowsRaw, error: rowsError } = await (supabase as any)
    .from("cash_posting_batch_rows")
    .select("*")
    .eq("active", true)
    .eq("posting_category", "customer_receipt_on_account")
    .in("posting_status", ["posted", "posted_needs_review"])
    .order("created_at", { ascending: false })
    .limit(100);

  const rows = (rowsRaw ?? []) as Row[];
  const snapshotIds = Array.from(new Set(rows.map((row) => text(row.snapshot_id)).filter(Boolean)));
  const batchIds = Array.from(new Set(rows.map((row) => text(row.batch_id)).filter(Boolean)));

  const { data: snapshotsRaw } = snapshotIds.length > 0
    ? await (supabase as any).from("cash_posting_snapshots").select("*").in("id", snapshotIds)
    : { data: [] };
  const snapshots = (snapshotsRaw ?? []) as Row[];
  const snapshotById = new Map(snapshots.map((row) => [text(row.id), row]));
  const orderIds = Array.from(new Set(snapshots.map((row) => text(row.order_id)).filter(Boolean)));

  const { data: batchesRaw } = batchIds.length > 0
    ? await (supabase as any).from("cash_posting_batches").select("id, batch_ref").in("id", batchIds)
    : { data: [] };
  const batchById = new Map(((batchesRaw ?? []) as Row[]).map((row) => [text(row.id), row]));

  const { data: targetsRaw } = orderIds.length > 0
    ? await (supabase as any)
      .from("sage_posting_snapshots")
      .select("id, source_id, order_id, order_ref, reference_text, amount_gbp, sage_invoice_id, resolved_payload, sage_posted_at, created_at")
      .eq("active", true)
      .eq("document_lane", "customer_sales")
      .eq("sage_posting_status", "posted")
      .in("order_id", orderIds)
    : { data: [] };
  const targets = (targetsRaw ?? []) as Row[];

  const candidates = rows.map((row) => buildCandidate(row, snapshotById.get(text(row.snapshot_id)), batchById.get(text(row.batch_id)), targets));
  const ready = candidates.filter((row) => row.status === "ready");
  const blocked = candidates.filter((row) => row.status === "blocked");
  const allocated = candidates.filter((row) => row.status === "allocated");
  const failed = candidates.filter((row) => row.status === "failed");
  const totalReadyValue = ready.reduce((sum, row) => sum + row.allocationAmount, 0);
  const liveEnabled = process.env.SAGE_LIVE_CASH_ALLOCATION_ENABLED === "true";

  return (
    <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="border-b border-slate-100 px-4 py-3">
        <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Unified cash allocation</p>
            <h2 className="mt-1 text-xl font-semibold">Allocation rows</h2>
            <p className="mt-1 text-sm text-slate-500">One workbench for cash allocations. Phase 1 allocates customer receipt/payment-on-account rows to matched posted sales invoices.</p>
          </div>
          <div className="grid gap-2 text-xs sm:grid-cols-4">
            <span className="rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 font-bold text-emerald-900">Ready {ready.length}<br />{money(totalReadyValue)}</span>
            <span className="rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 font-bold text-amber-900">Blocked {blocked.length}</span>
            <span className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 font-bold text-sky-900">Allocated {allocated.length}</span>
            <span className="rounded-xl border border-rose-200 bg-rose-50 px-3 py-2 font-bold text-rose-900">Failed {failed.length}</span>
          </div>
        </div>
        <form action={postSelectedCashAllocationsAction} className="mt-3 space-y-3">
          <input type="hidden" name="cash_direction" value="all" />
          <input type="hidden" name="cash_category" value="all" />
          <input type="hidden" name="cash_status" value="all" />
          <input type="hidden" name="cash_page_size" value="100" />
          <div className="flex flex-wrap items-center gap-2">
            <SelectionControls />
            <button
              type="submit"
              disabled={!liveEnabled || ready.length === 0}
              className="rounded-lg bg-emerald-700 px-3 py-1.5 text-[11px] font-bold text-white disabled:bg-slate-200 disabled:text-slate-500"
            >
              Allocate selected ready rows
            </button>
            <span className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-1.5 text-[11px] font-bold text-slate-600">
              {liveEnabled ? "Live Sage allocation flag enabled" : "Live Sage allocation flag disabled"}
            </span>
          </div>
          {!liveEnabled ? <p className="text-xs font-semibold text-amber-700">Set SAGE_LIVE_CASH_ALLOCATION_ENABLED=true before live Sage allocation.</p> : null}

          <div className="overflow-x-auto rounded-2xl border border-slate-100">
            <table className="min-w-[1320px] divide-y divide-slate-200 text-xs">
              <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Select</th>
                  <th className="px-3 py-2 text-left">Status</th>
                  <th className="px-3 py-2 text-left">Order</th>
                  <th className="px-3 py-2 text-left">Counterparty</th>
                  <th className="px-3 py-2 text-left">Receipt</th>
                  <th className="px-3 py-2 text-left">Target invoice</th>
                  <th className="px-3 py-2 text-right">Receipt</th>
                  <th className="px-3 py-2 text-right">Allocate</th>
                  <th className="px-3 py-2 text-right">Residual</th>
                  <th className="px-3 py-2 text-left">Trace</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {candidates.length === 0 ? (
                  <tr><td colSpan={10} className="px-3 py-6 text-center text-sm text-slate-500">No posted customer receipt rows are waiting for allocation.</td></tr>
                ) : candidates.map((row) => (
                  <tr key={row.id} className="align-top hover:bg-slate-50">
                    <td className="px-3 py-3">
                      {row.status === "ready" ? <input type="checkbox" name="cash_allocation_row_id" value={row.id} defaultChecked data-accounting-row-select="true" className="h-4 w-4 rounded border-slate-300" /> : <span className="text-slate-400">—</span>}
                    </td>
                    <td className="px-3 py-3"><span className={`inline-flex rounded-full border px-2 py-0.5 text-[10px] font-bold ${statusClass(row.status)}`}>{row.status}</span>{row.blocker ? <p className="mt-1 max-w-[220px] text-[11px] leading-4 text-rose-700">{short(row.blocker, 90)}</p> : null}</td>
                    <td className="px-3 py-3 font-mono text-[11px] font-bold">{short(row.orderRef, 30)}</td>
                    <td className="px-3 py-3"><p className="font-bold">{short(row.counterparty, 34)}</p><p className="text-[11px] text-slate-500">{short(row.contactId, 30)}</p></td>
                    <td className="px-3 py-3"><p className="font-mono text-[11px]">{short(row.shortReference, 34)}</p><p className="text-[11px] text-slate-500">POA {short(row.paymentOnAccountId, 28)}</p></td>
                    <td className="px-3 py-3"><p className="font-mono text-[11px]">{short(row.targetReference, 34)}</p><p className="text-[11px] text-slate-500">{short(row.targetInvoiceId, 28)}</p></td>
                    <td className="px-3 py-3 text-right font-bold">{money(row.receiptAmount)}</td>
                    <td className="px-3 py-3 text-right font-bold text-emerald-900">{money(row.allocationAmount)}</td>
                    <td className="px-3 py-3 text-right font-bold text-slate-700">{money(row.residualAmount)}</td>
                    <td className="px-3 py-3">
                      <details className="rounded-xl border border-slate-200 bg-slate-50 p-2 text-[11px]">
                        <summary className="cursor-pointer font-bold">Allocation trace</summary>
                        <pre className="mt-2 max-h-44 overflow-auto rounded-lg bg-white p-2 text-[10px] text-slate-600">{JSON.stringify(row.trace, null, 2)}</pre>
                      </details>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </form>
      </div>
    </section>
  );
}
