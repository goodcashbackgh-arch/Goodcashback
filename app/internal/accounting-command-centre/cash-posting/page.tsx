import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import SelectionControls from "../SelectionControls";
import CashPostingBatchHistoryPanel from "./CashPostingBatchHistoryPanel";
import {
  createCustomerReceiptCashBatchAction,
  freezeSelectedCustomerReceiptCashRowsAction,
} from "./actions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";

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

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 46) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function statusTone(status: unknown): Tone {
  const raw = text(status).toLowerCase();
  if (["ready_to_freeze", "ready", "frozen_validated", "batched_validated", "posted"].includes(raw)) return "complete";
  if (raw.includes("endpoint_prove") || raw.includes("requires_decision") || raw === "frozen") return "review";
  if (raw.startsWith("blocked") || raw.includes("failed")) return "blocked";
  return "muted";
}

function Pill({ value }: { value: unknown }) {
  return <span className={`inline-flex max-w-[190px] truncate rounded-full border px-2 py-0.5 text-[10px] font-bold leading-4 ${toneClass(statusTone(value))}`}>{pretty(value)}</span>;
}

function TabLink({ title, detail, href, active = false }: { title: string; detail: string; href: string; active?: boolean }) {
  return (
    <Link href={href} className={`rounded-2xl border p-3 shadow-sm transition hover:bg-white ${toneClass(active ? "action" : "muted")}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{title}</p>
      <p className="mt-1 text-xs leading-5 opacity-90">{detail}</p>
    </Link>
  );
}

function SummaryCard({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: Tone }) {
  return (
    <div className={`rounded-2xl border p-3 shadow-sm ${toneClass(tone)}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-1 text-xs leading-4 opacity-90">{detail}</p>
    </div>
  );
}

function pageHref(params: Record<string, string | number | undefined>) {
  const qp = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === "") continue;
    qp.set(key, String(value));
  }
  const query = qp.toString();
  return query ? `/internal/accounting-command-centre/cash-posting?${query}` : "/internal/accounting-command-centre/cash-posting";
}

function DetailTrace({ row }: { row: Row }) {
  const detail = asObject(row.detail_json);
  return (
    <details className="rounded-xl border border-slate-200 bg-slate-50 p-2 text-[11px] leading-5 text-slate-700">
      <summary className="cursor-pointer font-bold text-slate-900">Posting trace</summary>
      <div className="mt-2 grid gap-2 md:grid-cols-3">
        <div>
          <p className="font-extrabold uppercase tracking-wide text-slate-500">Statement</p>
          <p>Line: {short(row.statement_line_id, 30)}</p>
          <p>Auth/ref: {short(row.auth_ref || row.reference_raw, 34)}</p>
          <p>Date: {short(row.statement_date_text, 20)}</p>
        </div>
        <div>
          <p className="font-extrabold uppercase tracking-wide text-slate-500">Match</p>
          <p>Source: {pretty(row.source_type)}</p>
          <p>Target: {short(row.matched_target_ref, 34)}</p>
          <p>Order: {short(row.order_ref, 28)}</p>
        </div>
        <div>
          <p className="font-extrabold uppercase tracking-wide text-slate-500">Sage target</p>
          <p>Contact: {short(row.sage_contact_name || row.sage_contact_id, 34)}</p>
          <p>Bank: {short(row.sage_bank_account_id, 34)}</p>
          <p>Batch/object: {short(row.batch_ref || row.target_sage_object_id || row.snapshot_id, 34)}</p>
        </div>
      </div>
      <pre className="mt-2 max-h-48 overflow-auto rounded-lg bg-white p-2 text-[10px] text-slate-600">{JSON.stringify(detail, null, 2)}</pre>
    </details>
  );
}

function CashRowCheckbox({ row }: { row: Row }) {
  const id = text(row.source_id);
  const queueRowId = text(row.queue_row_id) || `cash:${text(row.category)}:${id}`;
  const status = text(row.posting_status);
  const category = text(row.category);
  const enabledCategories = new Set([
  "customer_receipt_on_account",
  "supplier_invoice_payment",
  "shipper_invoice_payment",
  "retailer_refund_received",
  "bank_fee",
  "fx_card_difference",
  "unmatched_hold",
]);
  const selectableStatuses = new Set([
  "ready_to_freeze",
  "frozen_validated",
  "blocked_endpoint_prove_required",
]);
    const controlSelectable =
    ["retailer_refund_received", "bank_fee", "fx_card_difference", "unmatched_hold"].includes(category)
    && status === "blocked_endpoint_prove_required";

  if ((!bool(row.selectable) && !controlSelectable) || !id || !enabledCategories.has(category) || !selectableStatuses.has(status)) {
    return <span className="text-xs text-slate-400">—</span>;
  }
  return (
    <input
      type="checkbox"
      name="cash_queue_row_id"
      value={queueRowId}
      defaultChecked
      data-accounting-row-select="true"
      className="h-4 w-4 rounded border-slate-300"
      aria-label={`Select cash row ${queueRowId}`}
    />
  );
}

export default async function CashPostingWorkbenchPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const qp = searchParams ? await Promise.resolve(searchParams) : {};
  const direction = firstParam(qp.direction) || "all";
  const category = firstParam(qp.category) || "all";
  const status = firstParam(qp.status) || "all";
  const search = firstParam(qp.q);
  const success = firstParam(qp.success);
  const pageError = firstParam(qp.error);
  const pageSize = Math.min(Math.max(Number(firstParam(qp.page_size) || 100), 25), 300);
  const page = Math.max(Number(firstParam(qp.page) || 1), 1);
  const offset = (page - 1) * pageSize;

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);

  if (!canAccess) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-4xl space-y-5">
          <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
            <h1 className="mt-5 text-3xl font-bold tracking-tight">Cash Posting Workbench</h1>
            <p className="mt-3 text-sm leading-6 text-slate-600">This page is admin-accounting controlled. Your current staff role is {pretty(staff.role_type)}.</p>
          </section>
        </div>
      </main>
    );
  }

  const { data, error } = await (supabase as any).rpc("internal_cash_posting_workbench_rows_v1", {
    p_direction: direction,
    p_category: category,
    p_status: status,
    p_search: search || null,
    p_limit: pageSize,
    p_offset: offset,
  });

  const baseRows = ((data ?? []) as Row[]);
  const sourceIds = Array.from(new Set(baseRows.map((row) => text(row.source_id)).filter(Boolean)));
  const { data: snapshotData } = sourceIds.length > 0
    ? await (supabase as any).rpc("internal_cash_posting_snapshot_status_by_source_v1", { p_source_ids: sourceIds })
    : { data: [] };
  const { data: batchData } = sourceIds.length > 0
    ? await (supabase as any).rpc("internal_cash_posting_batch_status_by_source_v1", { p_source_ids: sourceIds })
    : { data: [] };

  const snapshotBySourceCategory = new Map<string, Row>();
  ((snapshotData ?? []) as Row[]).forEach((row) => snapshotBySourceCategory.set(`${text(row.source_id)}:${text(row.posting_category)}`, row));
  const batchBySourceCategory = new Map<string, Row>();
  ((batchData ?? []) as Row[]).forEach((row) => batchBySourceCategory.set(`${text(row.source_id)}:${text(row.posting_category)}`, row));

  const rows = baseRows.map((row) => {
    const lookupKey = `${text(row.source_id)}:${text(row.category)}`;
    const snapshot = snapshotBySourceCategory.get(lookupKey);
    const batch = batchBySourceCategory.get(lookupKey);
    const detail = asObject(row.detail_json);
    let merged: Row = row;

    if (snapshot) {
      merged = {
        ...merged,
        snapshot_id: snapshot.snapshot_id,
        posting_status: snapshot.workbench_status || merged.posting_status,
        blocker: snapshot.blocker || merged.blocker,
        selectable: snapshot.workbench_status === "frozen_validated" || snapshot.workbench_status === "ready_to_freeze" ? true : snapshot.selectable,
        detail_json: {
          ...detail,
          frozen_snapshot: {
            snapshot_id: snapshot.snapshot_id,
            validation_status: snapshot.validation_status,
            sage_posting_status: snapshot.sage_posting_status,
            short_reference: snapshot.short_reference,
          },
        },
      };
    }

    if (batch) {
      merged = {
        ...merged,
        batch_id: batch.batch_id,
        batch_ref: batch.batch_ref,
        posting_status: batch.batch_status === "posted" ? "posted" : "batched_validated",
        blocker: `batch ${text(batch.batch_ref)} created; Sage post is next phase`,
        selectable: false,
        detail_json: {
          ...asObject(merged.detail_json),
          cash_batch: {
            batch_id: batch.batch_id,
            batch_ref: batch.batch_ref,
            batch_status: batch.batch_status,
            batch_row_status: batch.batch_row_status,
          },
        },
      };
    }

    return merged;
  });

  const totalCount = rows.length > 0 ? Number(rows[0].total_count ?? 0) : 0;
  const enabledCategories = new Set([
  "customer_receipt_on_account",
  "supplier_invoice_payment",
  "shipper_invoice_payment",
  "retailer_refund_received",
  "bank_fee",
  "fx_card_difference",
  "unmatched_hold",
]);
  const readyRows = rows.filter((row) => text(row.posting_status) === "ready_to_freeze" && enabledCategories.has(text(row.category)));
  const frozenRows = rows.filter((row) => text(row.posting_status) === "frozen_validated");
  const batchedRows = rows.filter((row) => text(row.posting_status) === "batched_validated");
  const blockedRows = rows.filter((row) => text(row.posting_status).startsWith("blocked"));
  const selectedValue = readyRows.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const frozenValue = frozenRows.reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const hasPrev = page > 1;
  const hasNext = offset + rows.length < totalCount;

  const baseParams = {
    direction,
    category,
    status,
    q: search || undefined,
    page_size: pageSize,
  };

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1600px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Accounting cockpit · cash layer</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Cash Posting Workbench</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
                One controlled cash workbench for DVA/card/bank IN and OUT movements. Customer IN and supplier/shipper OUT can use the same freeze, validate and batch flow. Posting remains controlled by category-specific Sage adapters.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name)}</div>
              <div>{text(staff.role_type)}{accessFromPermissions((staff as Row).permissions_json) ? " · accounting admin testing" : ""}</div>
            </div>
          </div>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1 text-emerald-900">Shared cash freeze + batch wired</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">Customer IN · Supplier OUT · Shipper OUT</span>
            <span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">References: order ref · auth/ref · statement line · frozen payload · batch ref</span>
          </div>
          {success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{success}</p> : null}
          {pageError ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{pageError}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Cash RPC unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-7">
          <TabLink title="All" detail="All cash categories" href={pageHref({ ...baseParams, category: "all", page: 1 })} active={category === "all"} />
          <TabLink title="IN — customer" detail="Receipt/payment-on-account" href={pageHref({ ...baseParams, direction: "in", category: "customer_receipt_on_account", page: 1 })} active={category === "customer_receipt_on_account"} />
          <TabLink title="OUT — supplier" detail="Retailer AP payments" href={pageHref({ ...baseParams, direction: "out", category: "supplier_invoice_payment", page: 1 })} active={category === "supplier_invoice_payment"} />
          <TabLink title="OUT — shipper" detail="Shipper AP payments" href={pageHref({ ...baseParams, direction: "out", category: "shipper_invoice_payment", page: 1 })} active={category === "shipper_invoice_payment"} />
          <TabLink title="IN — refunds" detail="Endpoint prove required" href={pageHref({ ...baseParams, direction: "in", category: "retailer_refund_received", page: 1 })} active={category === "retailer_refund_received"} />
          <TabLink title="Residuals" detail="FX/card, bank fees, holds" href={pageHref({ ...baseParams, category: "fx_card_difference", page: 1 })} active={category === "fx_card_difference" || category === "bank_fee"} />
          <TabLink title="Blocked" detail="Missing mapping/target/proof" href={pageHref({ ...baseParams, status: "blocked", page: 1 })} active={status === "blocked"} />
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <SummaryCard label="Visible rows" value={String(rows.length)} detail={`${totalCount} matching row(s)`} tone="review" />
          <SummaryCard label="Ready enabled rows" value={String(readyRows.length)} detail={gbp(selectedValue)} tone={readyRows.length > 0 ? "complete" : "muted"} />
          <SummaryCard label="Frozen validated" value={String(frozenRows.length)} detail={`${gbp(frozenValue)} ready for batch`} tone={frozenRows.length > 0 ? "complete" : "muted"} />
          <SummaryCard label="Batched" value={String(batchedRows.length)} detail="Ready for Sage post phase" tone={batchedRows.length > 0 ? "complete" : "muted"} />
          <SummaryCard label="Blocked visible" value={String(blockedRows.length)} detail="Mapping, Sage target or endpoint proof" tone={blockedRows.length > 0 ? "blocked" : "complete"} />
        </section>

        <CashPostingBatchHistoryPanel />

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form action="/internal/accounting-command-centre/cash-posting" className="grid gap-3 md:grid-cols-2 xl:grid-cols-[minmax(220px,1fr)_150px_230px_150px_120px_auto] xl:items-end">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500 md:col-span-2 xl:col-span-1">
              Search
              <input name="q" defaultValue={search} placeholder="Order ref, auth/ref, counterparty, invoice, blocker" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" />
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Direction
              <select name="direction" defaultValue={direction} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All</option>
                <option value="in">IN</option>
                <option value="out">OUT</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Category
              <select name="category" defaultValue={category} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All categories</option>
                <option value="customer_receipt_on_account">Customer receipt on account</option>
                <option value="supplier_invoice_payment">Supplier invoice payment</option>
                <option value="shipper_invoice_payment">Shipper invoice payment</option>
                <option value="retailer_refund_received">Retailer refund received</option>
                <option value="fx_card_difference">FX/card difference</option>
                <option value="bank_fee">Bank fee</option>
                <option value="unmatched_hold">Unmatched/hold</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Status
              <select name="status" defaultValue={status} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All</option>
                <option value="ready">Ready</option>
                <option value="blocked">Blocked</option>
                <option value="blocked_endpoint_prove_required">Endpoint prove required</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Page size
              <select name="page_size" defaultValue={String(pageSize)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="50">50</option>
                <option value="100">100</option>
                <option value="200">200</option>
                <option value="300">300</option>
              </select>
            </label>
            <div className="flex gap-2">
              <button type="submit" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Apply</button>
              <Link href="/internal/accounting-command-centre/cash-posting" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Reset</Link>
            </div>
          </form>
        </section>

        <form className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <input type="hidden" name="cash_direction" value={direction} />
          <input type="hidden" name="cash_category" value={category} />
          <input type="hidden" name="cash_status" value={status} />
          <input type="hidden" name="cash_q" value={search} />
          <input type="hidden" name="cash_page_size" value={String(pageSize)} />
          <div className="border-b border-slate-100 px-4 py-3">
            <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
              <div>
                <h2 className="text-xl font-semibold">Cash posting rows</h2>
                <p className="mt-1 text-sm text-slate-500">Freeze selected applies to ready enabled cash rows. Create batch applies to frozen validated enabled rows. Neither action calls Sage.</p>
              </div>
              <div className="flex flex-wrap gap-2">
                <span className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-1.5 text-[11px] font-bold text-amber-900">No Sage API call</span>
                <button formAction={freezeSelectedCustomerReceiptCashRowsAction} className="rounded-lg bg-slate-950 px-3 py-1.5 text-[11px] font-bold text-white disabled:bg-slate-200 disabled:text-slate-500">Freeze + validate selected</button>
                <button formAction={createCustomerReceiptCashBatchAction} className="rounded-lg bg-emerald-700 px-3 py-1.5 text-[11px] font-bold text-white disabled:bg-slate-200 disabled:text-slate-500">Create validated cash batch</button>
                <button disabled className="rounded-lg bg-slate-200 px-3 py-1.5 text-[11px] font-bold text-slate-500">Post selected</button>
              </div>
            </div>
            <div className="mt-3">
              <SelectionControls />
            </div>
          </div>

          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1240px] divide-y divide-slate-200 text-xs">
              <thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Select</th>
                  <th className="px-3 py-2 text-left">Direction</th>
                  <th className="px-3 py-2 text-left">Category</th>
                  <th className="px-3 py-2 text-left">Date</th>
                  <th className="px-3 py-2 text-left">Counterparty</th>
                  <th className="px-3 py-2 text-left">Order ref</th>
                  <th className="px-3 py-2 text-left">Auth/ref</th>
                  <th className="px-3 py-2 text-right">GBP</th>
                  <th className="px-3 py-2 text-left">Matched target</th>
                  <th className="px-3 py-2 text-left">Status</th>
                  <th className="px-3 py-2 text-left">Details</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? (
                  <tr>
                    <td colSpan={11} className="px-3 py-8 text-center text-sm text-slate-500">
                      No cash rows match this filter. If the RPC warning is shown above, run the Supabase migration first.
                    </td>
                  </tr>
                ) : rows.map((row) => (
                  <tr key={text(row.queue_row_id)} className="align-top hover:bg-slate-50">
                    <td className="px-3 py-3"><CashRowCheckbox row={row} /></td>
                    <td className="px-3 py-3 font-bold uppercase text-slate-900">{text(row.direction) || "—"}</td>
                    <td className="px-3 py-3"><p className="max-w-[170px] truncate font-bold text-slate-950" title={text(row.category)}>{pretty(row.category)}</p><p className="mt-1 text-[11px] text-slate-500">{pretty(row.source_type)}</p></td>
                    <td className="px-3 py-3 text-slate-700">{short(row.statement_date_text, 20)}</td>
                    <td className="px-3 py-3"><p className="max-w-[170px] truncate font-semibold text-slate-900" title={text(row.counterparty_name)}>{text(row.counterparty_name) || "—"}</p><p className="mt-1 text-[11px] text-slate-500">{pretty(row.counterparty_type)}</p></td>
                    <td className="px-3 py-3 font-mono text-[11px] font-bold text-slate-900">{short(row.order_ref, 28)}</td>
                    <td className="px-3 py-3 font-mono text-[11px] text-slate-700" title={text(row.auth_ref) || text(row.reference_raw)}>{short(row.auth_ref || row.reference_raw, 28)}</td>
                    <td className="px-3 py-3 text-right font-bold text-slate-950">{gbp(row.amount_gbp)}</td>
                    <td className="px-3 py-3"><p className="max-w-[190px] truncate font-semibold text-slate-900" title={text(row.matched_target_ref)}>{short(row.matched_target_ref, 34)}</p><p className="mt-1 text-[11px] text-slate-500">{pretty(row.matched_target_type)}</p></td>
                    <td className="px-3 py-3"><Pill value={row.posting_status} />{text(row.blocker) ? <p className="mt-1 max-w-[220px] text-[11px] leading-4 text-rose-700" title={text(row.blocker)}>{short(row.blocker, 90)}</p> : null}</td>
                    <td className="px-3 py-3"><DetailTrace row={row} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="flex flex-col gap-3 border-t border-slate-100 px-4 py-3 text-sm text-slate-600 lg:flex-row lg:items-center lg:justify-between">
            <p>Page {page} · {rows.length} visible · {totalCount} matching</p>
            <div className="flex gap-2">
              {hasPrev ? <Link href={pageHref({ ...baseParams, page: page - 1 })} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Previous</Link> : <span className="rounded-xl border border-slate-200 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-400">Previous</span>}
              {hasNext ? <Link href={pageHref({ ...baseParams, page: page + 1 })} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Next</Link> : <span className="rounded-xl border border-slate-200 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-400">Next</span>}
            </div>
          </div>
        </form>

        <section className="rounded-3xl border border-violet-200 bg-violet-50 p-5 text-sm leading-6 text-violet-900">
          <h2 className="font-bold">Control position</h2>
          <p className="mt-2">This is one cash bench, not separate category screens. Supplier/shipper OUT now follows the same freeze and batch path as customer IN. Live Sage OUT payment posting is the next adapter after these rows are frozen and batched.</p>
        </section>
      </div>
    </main>
  );
}
