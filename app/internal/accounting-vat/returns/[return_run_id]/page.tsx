import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { runVatReconstructionForRunAction } from "../../reconstructFormAction";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
type TabKey = "summary" | "source" | "box6" | "box1" | "purchases" | "journals" | "submission";
type DataSet = { rows: Row[]; error: string | null; count: number };
type Col = { label: string; render: (row: Row) => unknown };

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });
const tabs: Array<{ key: TabKey; label: string; hint: string }> = [
  { key: "summary", label: "Summary", hint: "Pack control" },
  { key: "source", label: "Source Lines", hint: "Lineage" },
  { key: "box6", label: "Box 6 Timing", hint: "Prepayment" },
  { key: "box1", label: "Export Evidence / Box 1", hint: "Breach/reinstate" },
  { key: "purchases", label: "Box 4 / Box 7 Purchases", hint: "AP/refunds" },
  { key: "journals", label: "Sage Adjustment Journals", hint: "Gap only" },
  { key: "submission", label: "Submission Evidence", hint: "Sage/MTD lock" },
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
function gbp(value: unknown): string { return money.format(n(value)); }
function pretty(value: unknown): string { const raw = s(value).trim(); return raw ? raw.replaceAll("_", " ") : "—"; }
function cut(value: unknown, max = 42): string { const raw = s(value).trim(); return raw ? (raw.length > max ? `${raw.slice(0, max - 1)}…` : raw) : "—"; }
function date(value: unknown): string { const raw = s(value).trim(); if (!raw) return "—"; const parsed = new Date(raw); if (Number.isNaN(parsed.getTime())) return raw; return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed); }
function one(value: unknown): string { return Array.isArray(value) ? s(value[0]) : s(value); }
function tabFrom(value: unknown): TabKey { const key = one(value) as TabKey; return tabs.some((tab) => tab.key === key) ? key : "summary"; }
function href(runId: string, tab: TabKey): string { return `/internal/accounting-vat/returns/${runId}?tab=${tab}`; }
function boxLabel(value: unknown): string { const raw = s(value).trim(); return raw ? `Box ${raw}` : "No box"; }
function tone(t: "ok" | "warn" | "block" | "info" | "muted"): string { if (t === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900"; if (t === "warn") return "border-amber-200 bg-amber-50 text-amber-900"; if (t === "block") return "border-rose-200 bg-rose-50 text-rose-900"; if (t === "info") return "border-sky-200 bg-sky-50 text-sky-900"; return "border-slate-200 bg-slate-50 text-slate-700"; }

function Card({ label, value, detail, state = "muted" }: { label: string; value: string; detail: string; state?: "ok" | "warn" | "block" | "info" | "muted" }) {
  return <div className={`rounded-2xl border p-4 shadow-sm ${tone(state)}`}><p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p><p className="mt-1 text-2xl font-extrabold">{value}</p><p className="mt-2 text-xs leading-5 opacity-90">{detail}</p></div>;
}
function Tabs({ runId, active }: { runId: string; active: TabKey }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><div className="flex gap-2 overflow-x-auto pb-1">{tabs.map((tab) => <Link key={tab.key} href={href(runId, tab.key)} className={`min-w-fit rounded-2xl border px-4 py-3 text-sm ${tab.key === active ? "border-sky-300 bg-sky-50 text-sky-900" : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"}`}><span className="block font-bold">{tab.label}</span><span className="mt-1 block text-xs opacity-75">{tab.hint}</span></Link>)}</div></section>;
}
function Workflow() {
  const steps = ["Generate", "Review", "Approve journals", "Post journals", "Submit in Sage", "Match and lock"];
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold tracking-tight">Return workflow</h2><p className="mt-2 text-sm leading-6 text-slate-600">Posting, Sage submission and lock stay unavailable until blockers are clear and the required Sage-gap adjustment pack is approved.</p><div className="mt-5 grid gap-3 md:grid-cols-3 xl:grid-cols-6">{steps.map((step, index) => <div key={step} className={`rounded-2xl border p-4 ${index < 2 ? tone("info") : tone("muted")}`}><div className="flex items-center gap-2"><span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-white px-2 text-xs font-extrabold ring-1 ring-slate-200">{index + 1}</span><h3 className="font-semibold">{step}</h3></div><p className="mt-2 text-xs leading-5 opacity-90">{index < 2 ? "Current read-only build." : "Locked until prior gates tie."}</p></div>)}</div></section>;
}

async function listRows(db: any, table: string, cols: string, configure?: (q: any) => any): Promise<DataSet> {
  let query = db.from(table).select(cols, { count: "exact" });
  if (configure) query = configure(query);
  const { data, error, count } = await query.limit(100);
  return { rows: (data ?? []) as Row[], error: error?.message ? String(error.message) : null, count: count ?? 0 };
}
function Table({ title, data, columns, empty = "No rows to show yet." }: { title: string; data: DataSet; columns: Col[]; empty?: string }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="text-lg font-semibold tracking-tight">{title}</h2>{data.error ? <p className="mt-1 text-xs font-semibold text-rose-700">Read error: {data.error}</p> : null}</div><span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{data.rows.length} shown</span></div><div className="mt-4 overflow-x-auto"><table className="min-w-full divide-y divide-slate-200 text-left text-sm"><thead className="text-xs uppercase tracking-wide text-slate-500"><tr>{columns.map((column) => <th key={column.label} className="whitespace-nowrap px-3 py-2 font-bold">{column.label}</th>)}</tr></thead><tbody className="divide-y divide-slate-100">{data.rows.length === 0 ? <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={columns.length}>{empty}</td></tr> : data.rows.map((row, index) => <tr key={`${title}-${index}`}>{columns.map((column) => <td key={column.label} className="whitespace-nowrap px-3 py-2 text-slate-700">{column.render(row) as any}</td>)}</tr>)}</tbody></table></div></section>;
}

export default async function VatReturnPackDetailPage({ params, searchParams }: any) {
  const routeParams = params ? await params : {};
  const queryParams = searchParams ? await searchParams : {};
  const runId = s(routeParams?.return_run_id).trim();
  const activeTab = tabFrom(queryParams?.tab);
  if (!runId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: staff } = await supabase.from("staff").select("id, full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (s((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data: runData, error: runError } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box2_gbp, expected_box3_gbp, expected_box4_gbp, expected_box5_gbp, expected_box6_gbp, expected_box7_gbp, expected_box8_gbp, expected_box9_gbp, source_counts_json, blockers_summary_json, locked_at, created_at")
    .eq("id", runId)
    .maybeSingle();
  const run = (runData ?? {}) as Row;
  if (!runData && !runError) redirect("/internal/accounting-vat");

  const [lines, blockers, journals, journalLines, recon, salesInvoices, purchaseInvoices, matchEvidence] = await Promise.all([
    listRows(db, "vat_return_run_lines", "id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json, box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label, natural_sage_covered, adjustment_required, adjustment_reason, status, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "vat_return_blockers", "id, blocker_code, severity, status, owner_role, source_table, source_id, source_ref, message, required_action, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "vat_return_adjustment_journals", "id, vat_return_run_line_id, adjustment_type, target_box, direction, amount_gbp, status, sage_journal_id, sage_journal_ref, posted_at, approved_at, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "vat_return_adjustment_journal_lines", "id, vat_return_adjustment_journal_id, line_no, line_role, account_role, sage_ledger_account_id, sage_ledger_account_display, debit_amount_gbp, credit_amount_gbp, include_on_tax_return, target_box, created_at", (x) => x.order("line_no", { ascending: true })),
    listRows(db, "vat_return_sage_reconstruction_snapshots", "id, created_at, status, source_basis, box1_gbp, box4_gbp, box6_gbp, box7_gbp, sales_invoice_count, sales_credit_note_count, purchase_invoice_count, purchase_credit_note_count, warning_notes", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "sales_invoices", "id, invoice_type, amount_gbp, sage_status, consideration_received_date, sage_invoice_date, zero_rating_deadline_date, zero_rating_status, sage_invoice_id, created_at", (x) => x.order("created_at", { ascending: false })),
    listRows(db, "supplier_invoices", "id, supplier_invoice_ref, status, invoice_date, total_gbp, net_gbp, vat_gbp, sage_posting_status, sage_invoice_id, created_at", (x) => x.order("created_at", { ascending: false })),
    listRows(db, "vat_return_sage_match_evidence", "id, vat_return_run_id, sage_return_reference, sage_submitted_box1_gbp, sage_submitted_box4_gbp, sage_submitted_box6_gbp, sage_submitted_box7_gbp, match_status, matched_at, locked_at, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
  ]);

  const sourceCols: Col[] = [
    { label: "Type", render: (row) => pretty(row.line_kind) },
    { label: "Source", render: (row) => `${cut(row.source_table, 22)} / ${cut(row.source_ref, 28)}` },
    { label: "Box", render: (row) => boxLabel(row.box_number) },
    { label: "Direction", render: (row) => pretty(row.direction) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "VAT", render: (row) => gbp(row.vat_amount_gbp) },
    { label: "Tax point", render: (row) => date(row.tax_point_date) },
    { label: "Sage covered", render: (row) => pretty(row.natural_sage_covered) },
    { label: "Adjustment", render: (row) => row.adjustment_required ? cut(row.adjustment_reason, 48) : "No" },
  ];
  const blockerCols: Col[] = [
    { label: "Severity", render: (row) => pretty(row.severity) },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Code", render: (row) => cut(row.blocker_code, 42) },
    { label: "Owner", render: (row) => pretty(row.owner_role) },
    { label: "Message", render: (row) => cut(row.message, 80) },
    { label: "Required action", render: (row) => cut(row.required_action, 80) },
  ];
  const invoiceCols: Col[] = [
    { label: "Invoice", render: (row) => cut(row.sage_invoice_id) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Sage", render: (row) => pretty(row.sage_status) },
    { label: "Payment/tax point", render: (row) => date(row.consideration_received_date) },
    { label: "Invoice date", render: (row) => date(row.sage_invoice_date) },
  ];
  const evidenceCols: Col[] = [
    { label: "Invoice", render: (row) => cut(row.sage_invoice_id) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Deadline", render: (row) => date(row.zero_rating_deadline_date) },
    { label: "Zero-rate", render: (row) => pretty(row.zero_rating_status) },
  ];
  const purchaseCols: Col[] = [
    { label: "Ref", render: (row) => cut(row.supplier_invoice_ref) },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Date", render: (row) => date(row.invoice_date) },
    { label: "Net", render: (row) => gbp(row.net_gbp) },
    { label: "VAT", render: (row) => gbp(row.vat_gbp) },
    { label: "Total", render: (row) => gbp(row.total_gbp) },
    { label: "Sage", render: (row) => pretty(row.sage_posting_status) },
  ];
  const journalCols: Col[] = [
    { label: "Type", render: (row) => pretty(row.adjustment_type) },
    { label: "Box", render: (row) => boxLabel(row.target_box) },
    { label: "Direction", render: (row) => pretty(row.direction) },
    { label: "Amount", render: (row) => gbp(row.amount_gbp) },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Sage ref", render: (row) => cut(row.sage_journal_ref ?? row.sage_journal_id) },
  ];
  const journalLineCols: Col[] = [
    { label: "Journal", render: (row) => cut(row.vat_return_adjustment_journal_id, 18) },
    { label: "No", render: (row) => cut(row.line_no) },
    { label: "Role", render: (row) => pretty(row.line_role) },
    { label: "Account", render: (row) => cut(row.sage_ledger_account_display ?? row.account_role, 40) },
    { label: "Debit", render: (row) => gbp(row.debit_amount_gbp) },
    { label: "Credit", render: (row) => gbp(row.credit_amount_gbp) },
    { label: "Tax return", render: (row) => pretty(row.include_on_tax_return) },
    { label: "Box", render: (row) => boxLabel(row.target_box) },
  ];
  const reconCols: Col[] = [
    { label: "Created", render: (row) => date(row.created_at) },
    { label: "Status", render: (row) => pretty(row.status) },
    { label: "Box 1", render: (row) => gbp(row.box1_gbp) },
    { label: "Box 4", render: (row) => gbp(row.box4_gbp) },
    { label: "Box 6", render: (row) => gbp(row.box6_gbp) },
    { label: "Box 7", render: (row) => gbp(row.box7_gbp) },
    { label: "Docs", render: (row) => `${s(row.sales_invoice_count)} SI / ${s(row.purchase_invoice_count)} PI` },
  ];
  const evidenceMatchCols: Col[] = [
    { label: "Sage ref", render: (row) => cut(row.sage_return_reference) },
    { label: "Box 1", render: (row) => gbp(row.sage_submitted_box1_gbp) },
    { label: "Box 4", render: (row) => gbp(row.sage_submitted_box4_gbp) },
    { label: "Box 6", render: (row) => gbp(row.sage_submitted_box6_gbp) },
    { label: "Box 7", render: (row) => gbp(row.sage_submitted_box7_gbp) },
    { label: "Status", render: (row) => pretty(row.match_status) },
    { label: "Matched", render: (row) => date(row.matched_at) },
  ];

  const sourceBox6 = lines.rows.filter((row) => n(row.box_number) === 6);
  const sourceBox1 = lines.rows.filter((row) => n(row.box_number) === 1);
  const sourcePurchases = lines.rows.filter((row) => [4, 7].includes(n(row.box_number)));
  const openBlockers = blockers.rows.filter((row) => s(row.status) === "open").length;

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto flex max-w-7xl flex-col gap-6">
    <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"><Link href="/internal/accounting-vat" className="text-sm font-semibold text-sky-600">← Back to VAT dashboard</Link><p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT return pack detail</p><div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between"><div><h1 className="text-3xl font-semibold tracking-tight">{cut(run.return_period_label || run.run_ref || run.id, 80)}</h1><p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Detailed working area for source lines, Box 6 timing, export evidence, purchases, adjustment journals and submission evidence.</p></div><div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{s((staff as Row).full_name) || "Admin"}</div><div>{s((staff as Row).role_type)}</div></div></div></section>
    {runError ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">VAT run read error: {runError.message}</div> : null}
    <Workflow />
    <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4"><Card label="Run status" value={pretty(run.status)} detail={`${date(run.period_start_date)} to ${date(run.period_end_date)}`} state="info" /><Card label="Expected Box 1" value={gbp(run.expected_box1_gbp)} detail="Platform expected output VAT." state="info" /><Card label="Expected Box 4" value={gbp(run.expected_box4_gbp)} detail="Platform expected input VAT." state="info" /><Card label="Expected Box 6" value={gbp(run.expected_box6_gbp)} detail="Platform expected sales net." state="info" /><Card label="Expected Box 7" value={gbp(run.expected_box7_gbp)} detail="Platform expected purchase net." state="info" /><Card label="Open blockers" value={String(openBlockers)} detail={`${blockers.count} blocker rows found.`} state={openBlockers > 0 ? "warn" : "ok"} /><Card label="Source lines" value={String(lines.count)} detail="Generated platform facts for this run." state="info" /><Card label="Locked" value={run.locked_at ? "Yes" : "No"} detail={run.locked_at ? date(run.locked_at) : "Return is not locked."} state={run.locked_at ? "ok" : "muted"} /></section>
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-wrap gap-3"><form action={runVatReconstructionForRunAction}><input type="hidden" name="vat_return_run_id" value={runId} /><button className="rounded-xl border border-sky-200 bg-sky-50 px-4 py-2 text-sm font-bold text-sky-800">Run read-only Sage reconstruction</button></form><Link href="/internal/accounting-vat/sage-diagnostics" className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-bold text-slate-700">Open Sage diagnostics</Link><Link href="/internal/accounting-vat/platform-overlay" className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-bold text-slate-700">Open platform overlay preview</Link></div><p className="mt-3 text-xs leading-5 text-slate-600">No Sage posting button is exposed here. Posting remains locked until detailed return pack, blockers and adjustment journals are clean and approved.</p></section>
    <Tabs runId={runId} active={activeTab} />
    {activeTab === "summary" ? <div className="grid gap-4"><Table title="Sage natural VAT reconstructions" data={recon} columns={reconCols} /><Table title="VAT blockers" data={blockers} columns={blockerCols} /></div> : null}
    {activeTab === "source" ? <Table title="VAT return source lines" data={lines} columns={sourceCols} empty="No source lines exist yet. Generate the platform VAT pack before review." /> : null}
    {activeTab === "box6" ? <div className="grid gap-4"><section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 text-sm leading-6 text-sky-900"><h2 className="font-semibold">Box 6 timing rule</h2><p className="mt-2">Qualifying known-goods prepayments drive Box 6 in the prepayment period. Later Sage invoices must not duplicate values already reported.</p></section><Table title="Box 6 source lines" data={{ ...lines, rows: sourceBox6 }} columns={sourceCols} /><Table title="Sales invoices / tax-point evidence" data={salesInvoices} columns={invoiceCols} /></div> : null}
    {activeTab === "box1" ? <div className="grid gap-4"><section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900"><h2 className="font-semibold">Export evidence / Box 1 rule</h2><p className="mt-2">If export evidence is missing by the deadline, Box 1 treatment belongs in the period the deadline expires. Later reinstatement must link back to the original breach.</p></section><Table title="Box 1 source lines" data={{ ...lines, rows: sourceBox1 }} columns={sourceCols} /><Table title="Export evidence status" data={salesInvoices} columns={evidenceCols} /></div> : null}
    {activeTab === "purchases" ? <div className="grid gap-4"><section className="rounded-3xl border border-slate-200 bg-white p-5 text-sm leading-6 text-slate-700"><h2 className="font-semibold text-slate-950">Box 4 / Box 7 purchase rule</h2><p className="mt-2">Sage should naturally drive supplier AP and credit notes where valid VAT evidence exists. Statement/card spend alone must not create input VAT recovery.</p></section><Table title="Box 4 / Box 7 source lines" data={{ ...lines, rows: sourcePurchases }} columns={sourceCols} /><Table title="Supplier invoices" data={purchaseInvoices} columns={purchaseCols} /></div> : null}
    {activeTab === "journals" ? <div className="grid gap-4"><section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm leading-6 text-rose-900"><h2 className="font-semibold">Journal rule</h2><p className="mt-2">Journal only the Sage gap. Every journal must balance. VAT-box line has <code>include_on_tax_return = true</code>; balancing line must be excluded unless a later tested rule says otherwise.</p></section><Table title="Sage adjustment journals" data={journals} columns={journalCols} /><Table title="Sage adjustment journal lines" data={journalLines} columns={journalLineCols} /></div> : null}
    {activeTab === "submission" ? <div className="grid gap-4"><section className="rounded-3xl border border-slate-200 bg-white p-5 text-sm leading-6 text-slate-700"><h2 className="font-semibold text-slate-950">Submission evidence and lock</h2><p className="mt-2">Admin submits in Sage after platform journals have posted. The platform records submitted Sage boxes/reference/evidence and locks only when Sage submitted values match the platform expected values.</p></section><Table title="Sage submitted return match evidence" data={matchEvidence} columns={evidenceMatchCols} /></div> : null}
  </div></main>;
}
