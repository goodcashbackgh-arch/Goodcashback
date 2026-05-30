import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { generateNextSageVatDraftRunAction } from "./actions";
import { runVatReconstructionForRunAction } from "./reconstructFormAction";
import VatWorkflowPreview from "./VatWorkflowPreview";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
type TabKey = "overview" | "runs" | "blockers" | "journals" | "source" | "sage";
type DataSet = { rows: Row[]; error: string | null; count: number };
type Col = { label: string; render: (row: Row) => unknown };

const money = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const tabs: Array<{ key: TabKey; label: string; hint: string }> = [
  { key: "overview", label: "Overview", hint: "Control view" },
  { key: "runs", label: "VAT Runs", hint: "Return packs" },
  { key: "blockers", label: "Blockers", hint: "Stops/risks" },
  { key: "journals", label: "Journals", hint: "Adjustment queue" },
  { key: "source", label: "Source Facts", hint: "Invoice/funding" },
  { key: "sage", label: "Sage Coverage", hint: "Natural extraction" },
];

function s(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function n(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value.replace(/,/g, ""));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(value: unknown): string {
  return money.format(n(value));
}

function pretty(value: unknown): string {
  const raw = s(value).trim();
  return raw ? raw.replaceAll("_", " ") : "—";
}

function cut(value: unknown, max = 36): string {
  const raw = s(value).trim();
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function date(value: unknown): string {
  const raw = s(value).trim();
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(parsed);
}

function tone(t: "ok" | "warn" | "block" | "info" | "muted"): string {
  if (t === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (t === "warn") return "border-amber-200 bg-amber-50 text-amber-900";
  if (t === "block") return "border-rose-200 bg-rose-50 text-rose-900";
  if (t === "info") return "border-sky-200 bg-sky-50 text-sky-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function one(value: unknown): string {
  return Array.isArray(value) ? s(value[0]) : s(value);
}

function tabFrom(value: unknown): TabKey {
  const key = one(value) as TabKey;
  return tabs.some((tab) => tab.key === key) ? key : "overview";
}

function pageFrom(value: unknown): number {
  const parsed = Number(one(value));
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : 1;
}

function sizeFrom(value: unknown): number {
  const parsed = Number(one(value));
  return [10, 25, 50, 100].includes(parsed) ? parsed : 25;
}

function href(active: TabKey, patch: Record<string, string | number | null | undefined>, current: Record<string, string>): string {
  const params = new URLSearchParams(current);
  params.set("tab", active);
  Object.entries(patch).forEach(([key, value]) => {
    if (value === null || value === undefined || value === "") params.delete(key);
    else params.set(key, String(value));
  });
  return `/internal/accounting-vat?${params.toString()}`;
}

function Card({ label, value, detail, state = "muted" }: { label: string; value: string; detail: string; state?: "ok" | "warn" | "block" | "info" | "muted" }) {
  return (
    <div className={`rounded-2xl border p-4 shadow-sm ${tone(state)}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-2 text-xs leading-5 opacity-90">{detail}</p>
    </div>
  );
}

function Tabs({ active, current }: { active: TabKey; current: Record<string, string> }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
      <div className="flex gap-2 overflow-x-auto pb-1">
        {tabs.map((tab) => (
          <Link
            key={tab.key}
            href={href(tab.key, { page: 1 }, current)}
            className={`min-w-fit rounded-2xl border px-4 py-3 text-sm ${tab.key === active ? "border-sky-300 bg-sky-50 text-sky-900" : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"}`}
          >
            <span className="block font-bold">{tab.label}</span>
            <span className="mt-1 block text-xs opacity-75">{tab.hint}</span>
          </Link>
        ))}
      </div>
    </section>
  );
}

function FilterBar({ active, current, q, status, severity, pageSize }: { active: TabKey; current: Record<string, string>; q: string; status: string; severity: string; pageSize: number }) {
  return (
    <form method="get" action="/internal/accounting-vat" className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
      <input type="hidden" name="tab" value={active} />
      <input type="hidden" name="page" value="1" />
      <div className="grid gap-3 md:grid-cols-5">
        <label className="text-xs font-bold uppercase tracking-wide text-slate-500 md:col-span-2">
          Search
          <input name="q" defaultValue={q} placeholder="Ref, status, code, source..." className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2 text-sm font-medium normal-case tracking-normal text-slate-900" />
        </label>
        <label className="text-xs font-bold uppercase tracking-wide text-slate-500">
          Status
          <select name="status" defaultValue={status} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2 text-sm font-medium normal-case tracking-normal text-slate-900">
            <option value="">All</option>
            <option value="open">Open</option>
            <option value="draft">Draft</option>
            <option value="posted">Posted</option>
            <option value="platform_calculated">Platform calculated</option>
            <option value="admin_approved">Admin approved</option>
            <option value="matched_to_sage_locked">Locked</option>
            <option value="reconstructed">Reconstructed</option>
          </select>
        </label>
        <label className="text-xs font-bold uppercase tracking-wide text-slate-500">
          Severity
          <select name="severity" defaultValue={severity} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2 text-sm font-medium normal-case tracking-normal text-slate-900">
            <option value="">All</option>
            <option value="blocker">Blocker</option>
            <option value="warning">Warning</option>
            <option value="info">Info</option>
          </select>
        </label>
        <label className="text-xs font-bold uppercase tracking-wide text-slate-500">
          Rows
          <select name="pageSize" defaultValue={String(pageSize)} className="mt-1 w-full rounded-xl border border-slate-200 px-3 py-2 text-sm font-medium normal-case tracking-normal text-slate-900">
            <option value="10">10</option>
            <option value="25">25</option>
            <option value="50">50</option>
            <option value="100">100</option>
          </select>
        </label>
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Apply filters</button>
        <Link href={href(active, { q: null, status: null, severity: null, page: 1, pageSize }, current)} className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700">Clear</Link>
      </div>
    </form>
  );
}

function GenerateDraftRunPanel({ foundationReady }: { foundationReady: boolean }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold tracking-tight">Generate platform VAT draft pack</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Admin-only platform calculation. This verifies the Sage Accounting connection/settings, derives the next monthly VAT period from platform return history, and creates a draft source-line snapshot. It does not pull HMRC obligations, approve journals, post to Sage, submit to HMRC, or lock a return.
          </p>
        </div>
        {!foundationReady ? <span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-bold text-amber-800">Foundation migration required</span> : null}
      </div>
      <form action={generateNextSageVatDraftRunAction} className="mt-4">
        <button disabled={!foundationReady} className={`w-full rounded-xl px-4 py-3 text-sm font-semibold md:w-auto ${foundationReady ? "bg-slate-950 text-white" : "cursor-not-allowed bg-slate-200 text-slate-500"}`}>
          Generate next platform VAT draft pack
        </button>
      </form>
    </section>
  );
}

function Pager({ active, current, total, page, pageSize }: { active: TabKey; current: Record<string, string>; total: number; page: number; pageSize: number }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const from = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const to = Math.min(page * pageSize, total);
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-white p-3 text-sm text-slate-600">
      <span>Showing {from}-{to} of {total}</span>
      <div className="flex gap-2">
        <Link aria-disabled={page <= 1} className={`rounded-xl border px-3 py-2 font-semibold ${page <= 1 ? "pointer-events-none border-slate-100 text-slate-300" : "border-slate-200 text-slate-700"}`} href={href(active, { page: Math.max(1, page - 1), pageSize }, current)}>Previous</Link>
        <span className="rounded-xl bg-slate-100 px-3 py-2 font-semibold text-slate-700">Page {page} / {pages}</span>
        <Link aria-disabled={page >= pages} className={`rounded-xl border px-3 py-2 font-semibold ${page >= pages ? "pointer-events-none border-slate-100 text-slate-300" : "border-slate-200 text-slate-700"}`} href={href(active, { page: Math.min(pages, page + 1), pageSize }, current)}>Next</Link>
      </div>
    </div>
  );
}

async function countRows(db: any, table: string, configure?: (q: any) => any) {
  let query = db.from(table).select("*", { count: "exact", head: true });
  if (configure) query = configure(query);
  const { count, error } = await query;
  return { count: count ?? 0, error: error?.message ? String(error.message) : null };
}

async function listRows(db: any, table: string, cols: string, page: number, pageSize: number, configure?: (q: any) => any): Promise<DataSet> {
  let query = db.from(table).select(cols, { count: "exact" });
  if (configure) query = configure(query);
  const from = (page - 1) * pageSize;
  const to = from + pageSize - 1;
  const { data, error, count } = await query.range(from, to);
  return { rows: (data ?? []) as Row[], error: error?.message ? String(error.message) : null, count: count ?? 0 };
}

function Table({ title, data, columns }: { title: string; data: DataSet; columns: Col[] }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
          {data.error ? <p className="mt-1 text-xs font-semibold text-rose-700">Read error: {data.error}</p> : null}
        </div>
        <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{data.rows.length} shown</span>
      </div>
      <div className="mt-4 overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
          <thead className="text-xs uppercase tracking-wide text-slate-500">
            <tr>{columns.map((column) => <th key={column.label} className="whitespace-nowrap px-3 py-2 font-bold">{column.label}</th>)}</tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {data.rows.length === 0 ? <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={columns.length}>No rows to show yet.</td></tr> : data.rows.map((row, index) => (
              <tr key={`${title}-${index}`}>{columns.map((column) => <td key={column.label} className="whitespace-nowrap px-3 py-2 text-slate-700">{column.render(row) as any}</td>)}</tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}

export default async function InternalAccountingVatPage({ searchParams }: any = {}) {
  const params = searchParams ? await searchParams : {};
  const activeTab = tabFrom(params?.tab);
  const page = pageFrom(params?.page);
  const pageSize = sizeFrom(params?.pageSize);
  const q = one(params?.q).trim();
  const status = one(params?.status).trim();
  const severity = one(params?.severity).trim();
  const vatError = one(params?.vatError).trim();
  const vatGenerated = one(params?.vatGenerated).trim();
  const vatReconstructed = one(params?.vatReconstructed).trim();
  const current: Record<string, string> = { tab: activeTab, page: String(page), pageSize: String(pageSize) };
  if (q) current.q = q;
  if (status) current.status = status;
  if (severity) current.severity = severity;

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!staff) redirect("/auth/check");

  if (s((staff as Row).role_type) !== "admin") {
    return (
      <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
        <div className="mx-auto max-w-4xl rounded-3xl border border-rose-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-rose-500">Admin-only VAT control</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">VAT Return Workbench</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">Live VAT return controls are restricted to admin users.</p>
        </div>
      </main>
    );
  }

  const [salesInvoices, draftSalesInvoices, postedSalesInvoices, fundingEvents, receiptSnapshots, postedReceiptSnapshots, customerSalesSnapshots, postedCustomerSalesSnapshots, vatReturnRuns, vatReturnRunLines, vatAdjustmentJournals, vatAdjustmentJournalLines, vatMatchEvidence, vatBlockers, openVatBlockers, reconCount] = await Promise.all([
    countRows(db, "sales_invoices"),
    countRows(db, "sales_invoices", (x) => x.eq("sage_status", "draft")),
    countRows(db, "sales_invoices", (x) => x.eq("sage_status", "posted")),
    countRows(db, "order_funding_events"),
    countRows(db, "cash_posting_snapshots", (x) => x.eq("posting_category", "customer_receipt_on_account")),
    countRows(db, "cash_posting_snapshots", (x) => x.eq("posting_category", "customer_receipt_on_account").in("sage_posting_status", ["posted", "posted_needs_review"])),
    countRows(db, "sage_posting_snapshots", (x) => x.eq("document_lane", "customer_sales").eq("active", true)),
    countRows(db, "sage_posting_snapshots", (x) => x.eq("document_lane", "customer_sales").eq("active", true).eq("sage_posting_status", "posted")),
    countRows(db, "vat_return_runs"),
    countRows(db, "vat_return_run_lines"),
    countRows(db, "vat_return_adjustment_journals"),
    countRows(db, "vat_return_adjustment_journal_lines"),
    countRows(db, "vat_return_sage_match_evidence"),
    countRows(db, "vat_return_blockers"),
    countRows(db, "vat_return_blockers", (x) => x.eq("status", "open")),
    countRows(db, "vat_return_sage_reconstruction_snapshots"),
  ]);

  const runFilter = (x: any) => { let row = x.order("created_at", { ascending: false }); if (status) row = row.eq("status", status); if (q) row = row.or(`run_ref.ilike.%${q}%,return_period_label.ilike.%${q}%,status.ilike.%${q}%`); return row; };
  const blockerFilter = (x: any) => { let row = x.order("created_at", { ascending: false }); if (status) row = row.eq("status", status); if (severity) row = row.eq("severity", severity); if (q) row = row.or(`blocker_code.ilike.%${q}%,source_table.ilike.%${q}%,source_ref.ilike.%${q}%,message.ilike.%${q}%,required_action.ilike.%${q}%`); return row; };
  const journalFilter = (x: any) => { let row = x.order("created_at", { ascending: false }); if (status) row = row.eq("status", status); if (q) row = row.or(`adjustment_type.ilike.%${q}%,direction.ilike.%${q}%,status.ilike.%${q}%,sage_journal_ref.ilike.%${q}%`); return row; };
  const invoiceFilter = (x: any) => { let row = x.order("created_at", { ascending: false }); if (status) row = row.eq("sage_status", status); if (q) row = row.or(`invoice_type.ilike.%${q}%,sage_status.ilike.%${q}%,zero_rating_status.ilike.%${q}%,sage_invoice_id.ilike.%${q}%`); return row; };
  const fundingFilter = (x: any) => { let row = x.order("created_at", { ascending: false }); if (q) row = row.or(`event_type.ilike.%${q}%,source_ref.ilike.%${q}%,source_entity_type.ilike.%${q}%`); return row; };
  const receiptFilter = (x: any) => { let row = x.eq("posting_category", "customer_receipt_on_account").order("created_at", { ascending: false }); if (status) row = row.eq("sage_posting_status", status); if (q) row = row.or(`order_ref.ilike.%${q}%,sage_posting_status.ilike.%${q}%,sage_payment_on_account_id.ilike.%${q}%`); return row; };
  const sageFilter = (x: any) => { let row = x.eq("document_lane", "customer_sales").eq("active", true).order("created_at", { ascending: false }); if (status) row = row.eq("sage_posting_status", status); if (q) row = row.or(`document_type.ilike.%${q}%,order_ref.ilike.%${q}%,sage_posting_status.ilike.%${q}%,sage_invoice_id.ilike.%${q}%`); return row; };
  const reconFilter = (x: any) => { let row = x.order("created_at", { ascending: false }); if (status) row = row.eq("status", status); if (q) row = row.or(`status.ilike.%${q}%,source_basis.ilike.%${q}%,warning_notes.ilike.%${q}%`); return row; };

  const [runs, blockers, journals, invoices, funds, receipts, sageRows, reconRows] = await Promise.all([
    listRows(db, "vat_return_runs", "id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box4_gbp, expected_box6_gbp, expected_box7_gbp, locked_at, created_at", page, pageSize, runFilter),
    listRows(db, "vat_return_blockers", "id, blocker_code, severity, status, source_table, source_ref, message, required_action, created_at", page, pageSize, blockerFilter),
    listRows(db, "vat_return_adjustment_journals", "id, adjustment_type, target_box, direction, amount_gbp, status, sage_journal_ref, posted_at, created_at", page, pageSize, journalFilter),
    listRows(db, "sales_invoices", "id, invoice_type, amount_gbp, sage_status, consideration_received_date, sage_invoice_date, zero_rating_deadline_date, zero_rating_status, sage_invoice_id, sage_posted_at, created_at", page, pageSize, invoiceFilter),
    listRows(db, "order_funding_events", "id, event_type, amount_gbp, source_ref, source_entity_type, created_at", page, pageSize, fundingFilter),
    listRows(db, "cash_posting_snapshots", "id, order_ref, amount_gbp, posting_date, sage_posting_status, sage_payment_on_account_id, created_at", page, pageSize, receiptFilter),
    listRows(db, "sage_posting_snapshots", "id, document_type, order_ref, amount_gbp, sage_posting_status, sage_invoice_id, sage_posted_at, created_at", page, pageSize, sageFilter),
    listRows(db, "vat_return_sage_reconstruction_snapshots", "id, vat_return_run_id, period_start_date, period_end_date, status, source_basis, box1_gbp, box2_gbp, box3_gbp, box4_gbp, box5_gbp, box6_gbp, box7_gbp, box8_gbp, box9_gbp, sales_invoice_count, sales_credit_note_count, purchase_invoice_count, purchase_credit_note_count, warning_notes, created_at", page, pageSize, reconFilter),
  ]);

  const foundationReady = [vatReturnRuns, vatReturnRunLines, vatAdjustmentJournals, vatAdjustmentJournalLines, vatMatchEvidence, vatBlockers].every((item) => !item.error);
  const reconAction = (row: Row) => (
    <form action={runVatReconstructionForRunAction}>
      <input type="hidden" name="vat_return_run_id" value={s(row.id)} />
      <button className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-bold text-sky-800">Reconstruct Sage VAT</button>
    </form>
  );

  const runCols: Col[] = [
    { label: "Run", render: (row) => cut(row.run_ref) },
    { label: "Period", render: (row) => cut(row.return_period_label) },
    { label: "Start", render: (row) => date(row.period_start_date) },
    { label: "End", render: (row) => date(row.period_end_date) },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Box 1", render: (row) => gbp(row.expected_box1_gbp) },
    { label: "Box 4", render: (row) => gbp(row.expected_box4_gbp) },
    { label: "Box 6", render: (row) => gbp(row.expected_box6_gbp) },
    { label: "Box 7", render: (row) => gbp(row.expected_box7_gbp) },
    { label: "Sage", render: reconAction },
  ];
  const blockerCols: Col[] = [
    { label: "Severity", render: (row) => pretty(row.severity) },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Code", render: (row) => cut(row.blocker_code, 42) },
    { label: "Source", render: (row) => cut(row.source_table) },
    { label: "Message", render: (row) => cut(row.message, 72) },
    { label: "Required action", render: (row) => cut(row.required_action, 72) },
  ];
  const journalCols: Col[] = [
    { label: "Type", render: (row) => pretty(row.adjustment_type) },
    { label: "Box", render: (row) => cut(row.target_box) },
    { label: "Direction", render: (row) => pretty(row.direction) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Sage ref", render: (row) => cut(row.sage_journal_ref) },
    { label: "Posted", render: (row) => date(row.posted_at) },
  ];
  const invoiceCols: Col[] = [
    { label: "Type", render: (row) => pretty(row.invoice_type) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Sage", render: (row) => pretty(row.sage_status) },
    { label: "Payment/tax point", render: (row) => date(row.consideration_received_date) },
    { label: "Invoice date", render: (row) => date(row.sage_invoice_date) },
    { label: "Evidence deadline", render: (row) => date(row.zero_rating_deadline_date) },
    { label: "Zero-rate", render: (row) => pretty(row.zero_rating_status) },
  ];
  const fundingCols: Col[] = [
    { label: "Event", render: (row) => pretty(row.event_type) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Source", render: (row) => pretty(row.source_entity_type) },
    { label: "Reference", render: (row) => cut(row.source_ref, 42) },
    { label: "Created", render: (row) => date(row.created_at) },
  ];
  const receiptCols: Col[] = [
    { label: "Order", render: (row) => cut(row.order_ref) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Receipt date", render: (row) => date(row.posting_date) },
    { label: "Sage receipt", render: (row) => pretty(row.sage_posting_status) },
    { label: "POA id", render: (row) => cut(row.sage_payment_on_account_id) },
  ];
  const sageCols: Col[] = [
    { label: "Document", render: (row) => pretty(row.document_type) },
    { label: "Order", render: (row) => cut(row.order_ref) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Sage", render: (row) => pretty(row.sage_posting_status) },
    { label: "Sage invoice", render: (row) => cut(row.sage_invoice_id) },
    { label: "Posted", render: (row) => date(row.sage_posted_at) },
  ];
  const reconCols: Col[] = [
    { label: "Created", render: (row) => date(row.created_at) },
    { label: "Period", render: (row) => `${date(row.period_start_date)}-${date(row.period_end_date)}` },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Box 1", render: (row) => gbp(row.box1_gbp) },
    { label: "Box 4", render: (row) => gbp(row.box4_gbp) },
    { label: "Box 6", render: (row) => gbp(row.box6_gbp) },
    { label: "Box 7", render: (row) => gbp(row.box7_gbp) },
    { label: "Docs", render: (row) => `${s(row.sales_invoice_count)} SI / ${s(row.purchase_invoice_count)} PI` },
    { label: "Warning", render: (row) => cut(row.warning_notes, 60) },
  ];

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Admin-only VAT Return Workbench</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">VAT return control dashboard</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Platform VAT draft pack, Sage natural extraction, and statutory VAT overlay controls. Sage journals and HMRC/MTD submission remain locked until the platform and Sage positions agree.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{s((staff as Row).full_name) || "Admin"}</div>
              <div>{s((staff as Row).role_type)}</div>
            </div>
          </div>
        </section>

        {vatError ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">VAT action failed: {vatError}</div> : null}
        {vatGenerated ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">Draft VAT return run generated: {vatGenerated}</div> : null}
        {vatReconstructed ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">Sage VAT reconstruction saved: {vatReconstructed}</div> : null}

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <Card label="Foundation layer" value={foundationReady ? "Present" : "Missing"} detail={foundationReady ? "Run, line, blocker, journal and match tables visible." : "Apply the VAT foundation migration first."} state={foundationReady ? "ok" : "warn"} />
          <Card label="Open blockers" value={String(openVatBlockers.count)} detail={vatBlockers.error ?? `${vatBlockers.count} blocker records total.`} state={openVatBlockers.count > 0 ? "warn" : vatBlockers.error ? "block" : "ok"} />
          <Card label="Return runs" value={String(vatReturnRuns.count)} detail={vatReturnRuns.error ?? `${vatReturnRunLines.count} source-line rows.`} state={vatReturnRuns.error || vatReturnRunLines.error ? "block" : "info"} />
          <Card label="Sage reconstruction" value={reconCount.error ? "Missing" : String(reconCount.count)} detail={reconCount.error ?? "Read-only Sage VAT snapshots."} state={reconCount.error ? "warn" : "info"} />
          <Card label="Adjustment journals" value={String(vatAdjustmentJournals.count)} detail={vatAdjustmentJournals.error ?? `${vatAdjustmentJournalLines.count} journal lines.`} state={vatAdjustmentJournals.error || vatAdjustmentJournalLines.error ? "block" : "info"} />
          <Card label="Sales invoices" value={String(salesInvoices.count)} detail={`${draftSalesInvoices.count} draft, ${postedSalesInvoices.count} posted.`} state={salesInvoices.error ? "block" : "info"} />
          <Card label="Funding events" value={String(fundingEvents.count)} detail={fundingEvents.error ?? "Box 6 prepayment source spine."} state={fundingEvents.error ? "block" : "info"} />
          <Card label="Sage coverage" value={String(customerSalesSnapshots.count)} detail={`${postedCustomerSalesSnapshots.count} customer sales posted. ${postedReceiptSnapshots.count} receipts posted/review.`} state={customerSalesSnapshots.error || receiptSnapshots.error ? "block" : "info"} />
        </section>

        <GenerateDraftRunPanel foundationReady={foundationReady} />
        <VatWorkflowPreview />
        <Tabs active={activeTab} current={current} />
        <FilterBar active={activeTab} current={current} q={q} status={status} severity={severity} pageSize={pageSize} />

        {activeTab === "overview" ? (
          <div className="grid gap-4">
            <section className="grid gap-4 md:grid-cols-2">
              <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm leading-6 text-emerald-900">
                <h2 className="font-semibold">What matters first</h2>
                <p className="mt-2">Generate the platform pack, reconstruct Sage natural VAT, then review the platform statutory overlay before any adjustment work.</p>
              </div>
              <div className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
                <h2 className="font-semibold">No submission route</h2>
                <p className="mt-2">This workbench does not post journals, pay VAT, submit to HMRC, or lock a return. Sage/MTD submission stays manual and locked until the comparison ties.</p>
              </div>
            </section>
            <Table title="VAT blockers" data={blockers} columns={blockerCols} />
            <Pager active={activeTab} current={current} total={blockers.count} page={page} pageSize={pageSize} />
            <Table title="VAT return runs" data={runs} columns={runCols} />
          </div>
        ) : null}

        {activeTab === "runs" ? <><Table title="VAT return runs" data={runs} columns={runCols} /><Pager active={activeTab} current={current} total={runs.count} page={page} pageSize={pageSize} /></> : null}
        {activeTab === "blockers" ? <><Table title="VAT blockers" data={blockers} columns={blockerCols} /><Pager active={activeTab} current={current} total={blockers.count} page={page} pageSize={pageSize} /></> : null}
        {activeTab === "journals" ? <><Table title="VAT adjustment journals" data={journals} columns={journalCols} /><Pager active={activeTab} current={current} total={journals.count} page={page} pageSize={pageSize} /></> : null}
        {activeTab === "source" ? <div className="grid gap-4"><Table title="Sales invoices" data={invoices} columns={invoiceCols} /><Pager active={activeTab} current={current} total={invoices.count} page={page} pageSize={pageSize} /><Table title="Funding events" data={funds} columns={fundingCols} /></div> : null}
        {activeTab === "sage" ? <div className="grid gap-4"><Table title="Sage VAT reconstructions" data={reconRows} columns={reconCols} /><Pager active={activeTab} current={current} total={reconRows.count} page={page} pageSize={pageSize} /><Table title="Customer receipt-on-account snapshots" data={receipts} columns={receiptCols} /><Table title="Sage customer sales snapshots" data={sageRows} columns={sageCols} /></div> : null}
      </div>
    </main>
  );
}
