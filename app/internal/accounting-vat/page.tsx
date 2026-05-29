import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type TabKey = "overview" | "runs" | "blockers" | "journals" | "source" | "sage";

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });
const tabs: Array<{ key: TabKey; label: string; hint: string }> = [
  { key: "overview", label: "Overview", hint: "Control view" },
  { key: "runs", label: "VAT Runs", hint: "Return packs" },
  { key: "blockers", label: "Blockers", hint: "Stops/risks" },
  { key: "journals", label: "Journals", hint: "Adjustment queue" },
  { key: "source", label: "Source Facts", hint: "Invoice/funding" },
  { key: "sage", label: "Sage Coverage", hint: "Posted coverage" },
];

function s(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}
function n(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}
function gbp(value: unknown) { return money.format(n(value)); }
function pretty(value: unknown) { const raw = s(value).trim(); return raw ? raw.replaceAll("_", " ") : "—"; }
function cut(value: unknown, max = 36) { const raw = s(value).trim(); return raw ? (raw.length > max ? `${raw.slice(0, max - 1)}…` : raw) : "—"; }
function date(value: unknown) {
  const raw = s(value).trim();
  if (!raw) return "—";
  const d = new Date(raw);
  if (Number.isNaN(d.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(d);
}
function tone(t: "ok" | "warn" | "block" | "info" | "muted") {
  if (t === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (t === "warn") return "border-amber-200 bg-amber-50 text-amber-900";
  if (t === "block") return "border-rose-200 bg-rose-50 text-rose-900";
  if (t === "info") return "border-sky-200 bg-sky-50 text-sky-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}
function tabFrom(value: unknown): TabKey {
  const raw = Array.isArray(value) ? value[0] : value;
  const key = s(raw) as TabKey;
  return tabs.some((tab) => tab.key === key) ? key : "overview";
}

function Card({ label, value, detail, state = "muted" }: { label: string; value: string; detail: string; state?: "ok" | "warn" | "block" | "info" | "muted" }) {
  return <div className={`rounded-2xl border p-4 shadow-sm ${tone(state)}`}><p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p><p className="mt-1 text-2xl font-extrabold">{value}</p><p className="mt-2 text-xs leading-5 opacity-90">{detail}</p></div>;
}
function Step({ no, title, detail, active = false }: { no: string; title: string; detail: string; active?: boolean }) {
  return <div className={`rounded-2xl border p-4 ${active ? tone("info") : tone("muted")}`}><div className="flex items-center gap-2"><span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-white px-2 text-xs font-extrabold ring-1 ring-slate-200">{no}</span><h3 className="font-semibold">{title}</h3></div><p className="mt-2 text-xs leading-5 opacity-90">{detail}</p></div>;
}
function Tabs({ active }: { active: TabKey }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><div className="flex gap-2 overflow-x-auto pb-1">{tabs.map((tab) => <Link key={tab.key} href={`/internal/accounting-vat?tab=${tab.key}`} className={`min-w-fit rounded-2xl border px-4 py-3 text-sm ${tab.key === active ? "border-sky-300 bg-sky-50 text-sky-900" : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"}`}><span className="block font-bold">{tab.label}</span><span className="mt-1 block text-xs opacity-75">{tab.hint}</span></Link>)}</div></section>;
}
async function count(db: any, table: string, configure?: (q: any) => any) {
  let q = db.from(table).select("*", { count: "exact", head: true });
  if (configure) q = configure(q);
  const { count, error } = await q;
  return { count: count ?? 0, error: error?.message ? String(error.message) : null };
}
async function rows(db: any, table: string, cols: string, configure?: (q: any) => any) {
  let q = db.from(table).select(cols);
  if (configure) q = configure(q);
  const { data, error } = await q;
  return { rows: (data ?? []) as Row[], error: error?.message ? String(error.message) : null };
}
function Table({ title, rows, error, columns }: { title: string; rows: Row[]; error: string | null; columns: Array<{ label: string; render: (row: Row) => string }> }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="text-lg font-semibold tracking-tight">{title}</h2>{error ? <p className="mt-1 text-xs font-semibold text-rose-700">Read error: {error}</p> : null}</div><span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{rows.length} shown</span></div><div className="mt-4 overflow-x-auto"><table className="min-w-full divide-y divide-slate-200 text-left text-sm"><thead className="text-xs uppercase tracking-wide text-slate-500"><tr>{columns.map((c) => <th key={c.label} className="whitespace-nowrap px-3 py-2 font-bold">{c.label}</th>)}</tr></thead><tbody className="divide-y divide-slate-100">{rows.length === 0 ? <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={columns.length}>No rows to show yet.</td></tr> : rows.map((row, i) => <tr key={`${title}-${i}`}>{columns.map((c) => <td key={c.label} className="whitespace-nowrap px-3 py-2 text-slate-700">{c.render(row)}</td>)}</tr>)}</tbody></table></div></section>;
}

export default async function InternalAccountingVatPage({ searchParams }: any = {}) {
  const params = searchParams ? await searchParams : {};
  const activeTab = tabFrom(params?.tab);
  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: staff } = await supabase.from("staff").select("id, full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (s((staff as Row).role_type) !== "admin") return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto max-w-4xl rounded-3xl border border-rose-200 bg-white p-6 shadow-sm"><Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link><p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-rose-500">Admin-only VAT control</p><h1 className="mt-2 text-3xl font-semibold tracking-tight">VAT Return Workbench</h1><p className="mt-3 text-sm leading-6 text-slate-600">Live VAT return controls are restricted to admin users.</p></div></main>;

  const [salesInvoices, draftSalesInvoices, postedSalesInvoices, fundingEvents, receiptSnapshots, postedReceiptSnapshots, customerSalesSnapshots, postedCustomerSalesSnapshots, vatReturnRuns, vatReturnRunLines, vatAdjustmentJournals, vatAdjustmentJournalLines, vatMatchEvidence, vatBlockers, openVatBlockers, recentVatRuns, recentVatBlockers, recentVatJournals, recentSalesInvoices, recentFundingEvents, recentReceipts, recentSageSales] = await Promise.all([
    count(db, "sales_invoices"),
    count(db, "sales_invoices", (q) => q.eq("sage_status", "draft")),
    count(db, "sales_invoices", (q) => q.eq("sage_status", "posted")),
    count(db, "order_funding_events"),
    count(db, "cash_posting_snapshots", (q) => q.eq("posting_category", "customer_receipt_on_account")),
    count(db, "cash_posting_snapshots", (q) => q.eq("posting_category", "customer_receipt_on_account").in("sage_posting_status", ["posted", "posted_needs_review"])),
    count(db, "sage_posting_snapshots", (q) => q.eq("document_lane", "customer_sales").eq("active", true)),
    count(db, "sage_posting_snapshots", (q) => q.eq("document_lane", "customer_sales").eq("active", true).eq("sage_posting_status", "posted")),
    count(db, "vat_return_runs"), count(db, "vat_return_run_lines"), count(db, "vat_return_adjustment_journals"), count(db, "vat_return_adjustment_journal_lines"), count(db, "vat_return_sage_match_evidence"), count(db, "vat_return_blockers"), count(db, "vat_return_blockers", (q) => q.eq("status", "open")),
    rows(db, "vat_return_runs", "id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box4_gbp, expected_box6_gbp, expected_box7_gbp, locked_at, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    rows(db, "vat_return_blockers", "id, blocker_code, severity, status, source_table, source_ref, message, required_action, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    rows(db, "vat_return_adjustment_journals", "id, adjustment_type, target_box, direction, amount_gbp, status, sage_journal_ref, posted_at, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    rows(db, "sales_invoices", "id, invoice_type, amount_gbp, sage_status, consideration_received_date, sage_invoice_date, zero_rating_deadline_date, zero_rating_status, sage_invoice_id, sage_posted_at, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    rows(db, "order_funding_events", "id, event_type, amount_gbp, source_ref, source_entity_type, created_at", (q) => q.order("created_at", { ascending: false }).limit(8)),
    rows(db, "cash_posting_snapshots", "id, order_ref, amount_gbp, posting_date, sage_posting_status, sage_payment_on_account_id, created_at", (q) => q.eq("posting_category", "customer_receipt_on_account").order("created_at", { ascending: false }).limit(8)),
    rows(db, "sage_posting_snapshots", "id, document_type, order_ref, amount_gbp, sage_posting_status, sage_invoice_id, sage_posted_at, created_at", (q) => q.eq("document_lane", "customer_sales").eq("active", true).order("created_at", { ascending: false }).limit(8)),
  ]);

  const foundationObjects = [vatReturnRuns, vatReturnRunLines, vatAdjustmentJournals, vatAdjustmentJournalLines, vatMatchEvidence, vatBlockers];
  const foundationReady = foundationObjects.every((item) => !item.error);

  const runCols = [{ label: "Run", render: (r: Row) => cut(r.run_ref) }, { label: "Period", render: (r: Row) => cut(r.return_period_label) }, { label: "Start", render: (r: Row) => date(r.period_start_date) }, { label: "End", render: (r: Row) => date(r.period_end_date) }, { label: "Status", render: (r: Row) => pretty(r.status) }, { label: "Box 1", render: (r: Row) => gbp(r.expected_box1_gbp) }, { label: "Box 4", render: (r: Row) => gbp(r.expected_box4_gbp) }, { label: "Box 6", render: (r: Row) => gbp(r.expected_box6_gbp) }, { label: "Box 7", render: (r: Row) => gbp(r.expected_box7_gbp) }];
  const blockerCols = [{ label: "Severity", render: (r: Row) => pretty(r.severity) }, { label: "Status", render: (r: Row) => pretty(r.status) }, { label: "Code", render: (r: Row) => cut(r.blocker_code, 42) }, { label: "Source", render: (r: Row) => cut(r.source_table) }, { label: "Message", render: (r: Row) => cut(r.message, 72) }, { label: "Required action", render: (r: Row) => cut(r.required_action, 72) }];
  const journalCols = [{ label: "Type", render: (r: Row) => pretty(r.adjustment_type) }, { label: "Box", render: (r: Row) => cut(r.target_box) }, { label: "Direction", render: (r: Row) => pretty(r.direction) }, { label: "Amount", render: (r: Row) => gbp(r.amount_gbp) }, { label: "Status", render: (r: Row) => pretty(r.status) }, { label: "Sage ref", render: (r: Row) => cut(r.sage_journal_ref) }, { label: "Posted", render: (r: Row) => date(r.posted_at) }];
  const invoiceCols = [{ label: "Type", render: (r: Row) => pretty(r.invoice_type) }, { label: "Amount", render: (r: Row) => gbp(r.amount_gbp) }, { label: "Sage", render: (r: Row) => pretty(r.sage_status) }, { label: "Payment/tax point", render: (r: Row) => date(r.consideration_received_date) }, { label: "Invoice date", render: (r: Row) => date(r.sage_invoice_date) }, { label: "Evidence deadline", render: (r: Row) => date(r.zero_rating_deadline_date) }, { label: "Zero-rate", render: (r: Row) => pretty(r.zero_rating_status) }];
  const fundingCols = [{ label: "Event", render: (r: Row) => pretty(r.event_type) }, { label: "Amount", render: (r: Row) => gbp(r.amount_gbp) }, { label: "Source", render: (r: Row) => pretty(r.source_entity_type) }, { label: "Reference", render: (r: Row) => cut(r.source_ref, 42) }, { label: "Created", render: (r: Row) => date(r.created_at) }];
  const receiptCols = [{ label: "Order", render: (r: Row) => cut(r.order_ref) }, { label: "Amount", render: (r: Row) => gbp(r.amount_gbp) }, { label: "Receipt date", render: (r: Row) => date(r.posting_date) }, { label: "Sage receipt", render: (r: Row) => pretty(r.sage_posting_status) }, { label: "POA id", render: (r: Row) => cut(r.sage_payment_on_account_id) }];
  const sageCols = [{ label: "Document", render: (r: Row) => pretty(r.document_type) }, { label: "Order", render: (r: Row) => cut(r.order_ref) }, { label: "Amount", render: (r: Row) => gbp(r.amount_gbp) }, { label: "Sage", render: (r: Row) => pretty(r.sage_posting_status) }, { label: "Sage invoice", render: (r: Row) => cut(r.sage_invoice_id) }, { label: "Posted", render: (r: Row) => date(r.sage_posted_at) }];

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto flex max-w-7xl flex-col gap-6">
    <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"><Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link><p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Admin-only VAT Return Workbench</p><div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between"><div><h1 className="text-3xl font-semibold tracking-tight">VAT return control dashboard</h1><p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Compressed read-only workbench. Cards show control status; tabs separate blockers, runs, journals, source facts and Sage coverage so high-volume rows do not bury the decision.</p></div><div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{s((staff as Row).full_name) || "Admin"}</div><div>{s((staff as Row).role_type)}</div></div></div></section>
    <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4"><Card label="Foundation layer" value={foundationReady ? "Present" : "Missing"} detail={foundationReady ? "Run, line, blocker, journal and match tables visible." : "Apply the VAT foundation migration first."} state={foundationReady ? "ok" : "warn"} /><Card label="Open blockers" value={String(openVatBlockers.count)} detail={vatBlockers.error ?? `${vatBlockers.count} blocker records total.`} state={openVatBlockers.count > 0 ? "warn" : vatBlockers.error ? "block" : "ok"} /><Card label="Return runs" value={String(vatReturnRuns.count)} detail={vatReturnRuns.error ?? `${vatReturnRunLines.count} source-line rows.`} state={vatReturnRuns.error || vatReturnRunLines.error ? "block" : "info"} /><Card label="Adjustment journals" value={String(vatAdjustmentJournals.count)} detail={vatAdjustmentJournals.error ?? `${vatAdjustmentJournalLines.count} journal lines.`} state={vatAdjustmentJournals.error || vatAdjustmentJournalLines.error ? "block" : "info"} /><Card label="Match evidence" value={String(vatMatchEvidence.count)} detail={vatMatchEvidence.error ?? "Sage submitted box evidence records."} state={vatMatchEvidence.error ? "block" : "info"} /><Card label="Sales invoices" value={String(salesInvoices.count)} detail={`${draftSalesInvoices.count} draft, ${postedSalesInvoices.count} posted.`} state={salesInvoices.error ? "block" : "info"} /><Card label="Funding events" value={String(fundingEvents.count)} detail={fundingEvents.error ?? "Box 6 prepayment source spine."} state={fundingEvents.error ? "block" : "info"} /><Card label="Sage coverage" value={String(customerSalesSnapshots.count)} detail={`${postedCustomerSalesSnapshots.count} customer sales posted. ${postedReceiptSnapshots.count} receipts posted/review.`} state={customerSalesSnapshots.error || receiptSnapshots.error ? "block" : "info"} /></section>
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="text-xl font-semibold tracking-tight">Workflow preview</h2><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">Current stage is read-only. Next step is a controlled generator RPC that creates a draft run and source-line snapshot.</p></div><button disabled className="rounded-xl bg-slate-200 px-4 py-2 text-sm font-semibold text-slate-500">Generate VAT Return Pack — disabled until RPC exists</button></div><div className="mt-5 grid gap-3 md:grid-cols-3 xl:grid-cols-6"><Step no="1" title="Generate" detail="Draft pack." active /><Step no="2" title="Review" detail="Boxes and blockers." /><Step no="3" title="Approve journals" detail="Calculated only." /><Step no="4" title="Post journals" detail="After approval." /><Step no="5" title="Submit in Sage" detail="Admin submits." /><Step no="6" title="Match and lock" detail="Compare and lock." /></div></section>
    <Tabs active={activeTab} />
    {activeTab === "overview" ? <div className="grid gap-4"><section className="grid gap-4 md:grid-cols-2"><div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm leading-6 text-emerald-900"><h2 className="font-semibold">What matters first</h2><p className="mt-2">Check open blockers, latest run status and journal queue. Source facts sit behind tabs so hundreds of rows do not bury the control decision.</p></div><div className="rounded-3xl border border-sky-200 bg-sky-50 p-5 text-sm leading-6 text-sky-900"><h2 className="font-semibold">Volume handling</h2><p className="mt-2">Next UI layer should add period filters, search, status filters and pagination before high-volume operations go live.</p></div></section><Table title="Recent VAT blockers" rows={recentVatBlockers.rows} error={recentVatBlockers.error} columns={blockerCols} /><Table title="Recent VAT return runs" rows={recentVatRuns.rows} error={recentVatRuns.error} columns={runCols} /></div> : null}
    {activeTab === "runs" ? <Table title="Recent VAT return runs" rows={recentVatRuns.rows} error={recentVatRuns.error} columns={runCols} /> : null}
    {activeTab === "blockers" ? <Table title="Recent VAT blockers" rows={recentVatBlockers.rows} error={recentVatBlockers.error} columns={blockerCols} /> : null}
    {activeTab === "journals" ? <Table title="Recent VAT adjustment journals" rows={recentVatJournals.rows} error={recentVatJournals.error} columns={journalCols} /> : null}
    {activeTab === "source" ? <div className="grid gap-4"><Table title="Recent sales invoices" rows={recentSalesInvoices.rows} error={recentSalesInvoices.error} columns={invoiceCols} /><Table title="Recent funding events" rows={recentFundingEvents.rows} error={recentFundingEvents.error} columns={fundingCols} /></div> : null}
    {activeTab === "sage" ? <div className="grid gap-4"><Table title="Recent customer receipt-on-account snapshots" rows={recentReceipts.rows} error={recentReceipts.error} columns={receiptCols} /><Table title="Recent Sage customer sales snapshots" rows={recentSageSales.rows} error={recentSageSales.error} columns={sageCols} /></div> : null}
  </div></main>;
}
