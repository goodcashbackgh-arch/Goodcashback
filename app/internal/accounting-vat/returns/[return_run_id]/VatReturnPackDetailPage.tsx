import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { runVatReconstructionForRunAction } from "../../reconstructFormAction";
import { refreshVatPurchaseSourceLinesAction as refreshVatSourceSnapshotAction } from "./purchaseRefreshAction";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
type TabKey = "summary" | "source" | "box6" | "box1" | "purchases" | "journals" | "submission";
type DataSet = { rows: Row[]; error: string | null; count: number };
type Col = { label: string; render: (row: Row) => unknown };

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });
const tabs: Array<{ key: TabKey; label: string; hint: string }> = [
  { key: "summary", label: "Summary", hint: "VAT draft" },
  { key: "source", label: "Source Lines", hint: "Audit trail" },
  { key: "box6", label: "Box 6 Timing", hint: "Exceptions" },
  { key: "box1", label: "Export Evidence / Box 1", hint: "Breaches" },
  { key: "purchases", label: "Box 4 / Box 7 Purchases", hint: "AP/refunds" },
  { key: "journals", label: "Sage Adjustment Journals", hint: "Gap only" },
  { key: "submission", label: "Submission Evidence", hint: "Sage/MTD lock" },
];

const SOURCE_REFRESH_BLOCKED_STATUSES = new Set([
  "admin_approved",
  "sage_adjustment_journals_pending",
  "sage_adjustment_journals_posted",
  "sage_return_review_required",
  "sage_return_submitted",
  "matched_to_sage_locked",
  "mismatch_needs_admin_review",
  "superseded",
]);

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}
function num(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = Number(text(value).replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}
function obj(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Row) : {};
}
function yes(value: unknown): boolean {
  return value === true || text(value).toLowerCase() === "true";
}
function gbp(value: unknown): string {
  return money.format(num(value));
}
function pretty(value: unknown): string {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}
function clean(value: unknown): string {
  return pretty(value).replaceAll("([object Object])", "").replaceAll("[object Object]", "").trim();
}
function cut(value: unknown, max = 52): string {
  const raw = clean(value);
  return raw ? (raw.length > max ? `${raw.slice(0, max - 1)}…` : raw) : "—";
}
function shortId(value: unknown): string {
  const raw = text(value);
  return raw.length > 12 ? `…${raw.slice(-8)}` : raw || "—";
}
function date(value: unknown): string {
  const raw = text(value);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed);
}
function first(value: unknown): string {
  return Array.isArray(value) ? text(value[0]) : text(value);
}
function tabFrom(value: unknown): TabKey {
  const key = first(value) as TabKey;
  return tabs.some((tab) => tab.key === key) ? key : "summary";
}
function href(runId: string, tab: TabKey): string {
  return `/internal/accounting-vat/returns/${runId}?tab=${tab}`;
}
function boxLabel(value: unknown): string {
  const raw = text(value);
  return raw ? `Box ${raw}` : "No box";
}
function direction(row: Row): string {
  return text(row.direction).toLowerCase();
}
function isDecrease(row: Row): boolean {
  return direction(row) === "decrease";
}
function signedAmount(row: Row): number {
  const value = num(row.amount_gbp);
  return isDecrease(row) ? -Math.abs(value) : value;
}
function signedVat(row: Row): number {
  const value = num(row.vat_amount_gbp);
  return isDecrease(row) ? -Math.abs(value) : value;
}
function signedTotal(rows: Row[]): number {
  return rows.reduce((sum, row) => sum + signedAmount(row), 0);
}
function active(row: Row): boolean {
  return text(row.status).toLowerCase() === "active";
}
function directionLabel(row: Row): string {
  const raw = direction(row);
  if (raw === "no_box") return "Not a VAT-box line";
  if (raw === "decrease") return "Decrease";
  if (raw === "increase") return "Increase";
  if (raw === "natural") return "Natural";
  return pretty(raw);
}

async function listRows(db: any, table: string, cols: string, configure?: (query: any) => any): Promise<DataSet> {
  let query = db.from(table).select(cols, { count: "exact" });
  if (configure) query = configure(query);
  const { data, error, count } = await query.limit(100);
  return { rows: (data ?? []) as Row[], error: error?.message ? String(error.message) : null, count: count ?? 0 };
}
function sourceName(row: Row): string {
  const kind = text(row.line_kind);
  if (kind === "sales_invoice_box6_candidate" && isDecrease(row)) return "Sales credit note";
  if (kind === "sales_invoice_box6_candidate") return "Sales invoice";
  if (kind === "funding_event_source_fact") return "Funding event";
  if (kind === "sage_customer_receipt_source_fact") return "Sage receipt";
  if (kind === "sage_customer_sales_coverage_source_fact") return "Sage sales coverage";
  if (kind === "supplier_purchase_invoice_box4_vat") return "Supplier purchase VAT";
  if (kind === "supplier_purchase_invoice_box7_net") return "Supplier purchase net";
  if (kind === "supplier_credit_note_box4_decrease") return "Supplier credit note VAT";
  if (kind === "supplier_credit_note_box7_decrease") return "Supplier credit note net";
  if (kind === "shipper_ap_box7_net") return "Shipper AP net";
  return pretty(row.source_table || kind);
}
function sourceReference(row: Row): string {
  const source = obj(row.source_json);
  const lineage = obj(row.source_lineage_json);
  const chosen = [source.order_ref, lineage.order_ref, source.sage_invoice_id, lineage.sage_invoice_id, source.sage_payment_on_account_id, lineage.sage_payment_on_account_id, source.source_ref, lineage.source_ref, row.source_ref, row.source_id].map(text).find(Boolean);
  if (!chosen) return "—";
  if (/^[0-9a-f-]{30,}$/i.test(chosen)) return `ref ${shortId(chosen)}`;
  return clean(chosen);
}
function invoiceRef(row: Row): string {
  return cut(row.ocr_invoice_ref || row.invoice_ref || row.reference_text || row.sage_invoice_id || row.id, 42);
}
function sourceDisplay(row: Row): string {
  return `${sourceName(row)} · ${sourceReference(row)}`;
}
function boxEffect(row: Row): string {
  return text(row.box_number) ? `${boxLabel(row.box_number)} · ${directionLabel(row)}` : "No VAT-box effect";
}
function platformBox(run: Row, box: number): number {
  if (box === 3) return platformBox(run, 1) + platformBox(run, 2);
  if (box === 5) return platformBox(run, 3) - platformBox(run, 4);
  return num(run[`expected_box${box}_gbp`]);
}
function sageBox(recon: Row, box: number): number {
  if (box === 3) return sageBox(recon, 1) + sageBox(recon, 2);
  if (box === 5) return sageBox(recon, 3) - sageBox(recon, 4);
  return num(recon[`box${box}_gbp`]);
}

function Metric({ label, value, note, warn = false }: { label: string; value: string; note: string; warn?: boolean }) {
  return (
    <div className={`rounded-2xl border p-4 ${warn ? "border-amber-200 bg-amber-50 text-amber-900" : "border-slate-200 bg-slate-50 text-slate-800"}`}>
      <p className="text-xs font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-2 text-xs leading-5 opacity-90">{note}</p>
    </div>
  );
}

function VatWorkspace({ run, recon }: { run: Row; recon: Row }) {
  const hasRecon = Boolean(text(recon.id));
  const rows: Array<[number, string]> = [[1, "VAT due on sales/outputs"], [2, "VAT due on acquisitions"], [3, "Total VAT due: Box 1 + Box 2"], [4, "VAT reclaimed on purchases/inputs"], [5, "Net VAT to pay or reclaim"], [6, "Net sales/outputs"], [7, "Net purchases/inputs"], [8, "EU dispatches"], [9, "EU acquisitions"]];
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold tracking-tight">VAT return workspace</h2>
          <p className="mt-1 text-sm leading-6 text-slate-600">Platform draft is compared with Sage natural VAT. Difference shows the possible Sage-gap adjustment still to be reviewed.</p>
        </div>
        <span className={`rounded-full px-3 py-1 text-xs font-bold ${hasRecon ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{hasRecon ? "Sage reconstruction available" : "Run Sage reconstruction"}</span>
      </div>
      <div className="mt-5 overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
          <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Box</th><th className="px-3 py-2">What it means</th><th className="px-3 py-2">Platform draft</th><th className="px-3 py-2">Sage natural</th><th className="px-3 py-2">Difference</th></tr></thead>
          <tbody className="divide-y divide-slate-100">
            {rows.map(([box, meaning]) => {
              const platform = platformBox(run, box);
              const sage = hasRecon ? sageBox(recon, box) : 0;
              const gap = platform - sage;
              return <tr key={box}><td className="whitespace-nowrap px-3 py-2 font-bold text-slate-950">Box {box}</td><td className="whitespace-nowrap px-3 py-2 text-slate-600">{meaning}</td><td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-800">{gbp(platform)}</td><td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-800">{hasRecon ? gbp(sage) : "—"}</td><td className={`whitespace-nowrap px-3 py-2 font-bold ${Math.abs(gap) > 0.005 ? "text-amber-700" : "text-emerald-700"}`}>{hasRecon ? gbp(gap) : "—"}</td></tr>;
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function Tabs({ runId, activeTab }: { runId: string; activeTab: TabKey }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><div className="flex gap-2 overflow-x-auto pb-1">{tabs.map((tab) => <Link key={tab.key} href={href(runId, tab.key)} className={`min-w-fit rounded-2xl border px-4 py-3 text-sm ${tab.key === activeTab ? "border-sky-300 bg-sky-50 text-sky-900" : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"}`}><span className="block font-bold">{tab.label}</span><span className="mt-1 block text-xs opacity-75">{tab.hint}</span></Link>)}</div></section>;
}

function Workflow({ run, recon, blockers, journals, matchEvidence }: { run: Row; recon: Row; blockers: DataSet; journals: DataSet; matchEvidence: DataSet }) {
  const runStatus = text(run.status);
  const locked = Boolean(text(run.locked_at)) || runStatus === "matched_to_sage_locked";
  const hasRecon = Boolean(text(recon.id));
  const openBlockers = blockers.rows.filter((row) => text(row.status) === "open" && text(row.severity) === "blocker").length;
  const boxes = [1, 2, 3, 4, 5, 6, 7, 8, 9];
  const gapBoxes = hasRecon ? boxes.filter((box) => Math.abs(platformBox(run, box) - sageBox(recon, box)) > 0.005) : [];
  const activeJournals = journals.rows.filter((row) => text(row.status) !== "reversed");
  const hasJournals = activeJournals.length > 0;
  const hasSageGap = gapBoxes.length > 0;
  const journalsApproved = hasJournals && activeJournals.every((row) => ["admin_approved", "posting_to_sage", "posted_to_sage", "included_in_sage_return"].includes(text(row.status)));
  const journalsPosted = hasJournals && activeJournals.every((row) => ["posted_to_sage", "included_in_sage_return"].includes(text(row.status)));
  const submissionRecorded = matchEvidence.rows.length > 0;
  const noJournalRequired = hasRecon && openBlockers === 0 && !hasSageGap && !hasJournals;
  const steps = [
    { label: "Generate", status: "Complete", tone: "complete" },
    { label: "Review", status: locked || (hasRecon && openBlockers === 0) ? "Complete" : hasRecon ? `${openBlockers} blocker(s)` : "Run Sage reconstruction", tone: locked || (hasRecon && openBlockers === 0) ? "complete" : openBlockers > 0 ? "blocked" : "pending" },
    { label: "Approve journals", status: noJournalRequired ? "Not required — no Sage gap" : journalsApproved ? "Complete" : hasSageGap ? "Pending" : "Not ready", tone: noJournalRequired ? "notRequired" : journalsApproved ? "complete" : hasSageGap ? "pending" : "muted" },
    { label: "Post journals", status: noJournalRequired ? "Not required — no Sage gap" : journalsPosted ? "Complete" : journalsApproved ? "Pending post" : "Not ready", tone: noJournalRequired ? "notRequired" : journalsPosted ? "complete" : journalsApproved ? "pending" : "muted" },
    { label: "Submit in Sage", status: locked || submissionRecorded ? "Recorded" : journalsPosted || noJournalRequired ? "Ready" : "Not ready", tone: locked || submissionRecorded ? "complete" : journalsPosted || noJournalRequired ? "pending" : "muted" },
    { label: "Match and lock", status: locked ? "Locked" : submissionRecorded ? "Ready to match" : "Not ready", tone: locked ? "locked" : submissionRecorded ? "pending" : "muted" },
  ];
  const toneClass: Record<string, string> = { complete: "border-emerald-200 bg-emerald-50 text-emerald-800", notRequired: "border-sky-200 bg-sky-50 text-sky-800", pending: "border-amber-200 bg-amber-50 text-amber-900", blocked: "border-rose-200 bg-rose-50 text-rose-800", locked: "border-slate-300 bg-slate-950 text-white", muted: "border-slate-200 bg-slate-50 text-slate-600" };
  const message = locked ? "Return locked to Sage submission. Source refresh and VAT posting are disabled. Future changes must use correction/reopen flow." : noJournalRequired ? "No Sage-gap adjustment journal is required. Admin should submit in Sage, record evidence, then match and lock." : hasSageGap ? `Sage-gap adjustment required for ${gapBoxes.map((box) => `Box ${box}`).join(", ")}. Journal only the gap.` : "Posting, Sage submission and lock stay unavailable until the pack, blockers and required Sage-gap adjustments are clean.";
  return <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><div className="flex flex-wrap items-center gap-2">{steps.map((step, index) => <span key={step.label} className={`rounded-full border px-3 py-2 text-xs font-bold ${toneClass[step.tone]}`}>{index + 1}. {step.label}<span className="ml-2 font-semibold opacity-80">{step.status}</span></span>)}</div><p className="mt-3 text-xs leading-5 text-slate-600">{message}</p></section>;
}

function Table({ title, data, columns, empty = "No rows to show yet." }: { title: string; data: DataSet; columns: Col[]; empty?: string }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="text-lg font-semibold tracking-tight">{title}</h2>{data.error ? <p className="mt-1 text-xs font-semibold text-rose-700">Read error: {data.error}</p> : null}</div><span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{data.rows.length} shown</span></div><div className="mt-4 overflow-x-auto"><table className="min-w-full divide-y divide-slate-200 text-left text-sm"><thead className="text-xs uppercase tracking-wide text-slate-500"><tr>{columns.map((column) => <th key={column.label} className="whitespace-nowrap px-3 py-2 font-bold">{column.label}</th>)}</tr></thead><tbody className="divide-y divide-slate-100">{data.rows.length === 0 ? <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={columns.length}>{empty}</td></tr> : data.rows.map((row, index) => <tr key={`${title}-${text(row.id) || index}`}>{columns.map((column) => <td key={column.label} className="whitespace-nowrap px-3 py-2 text-slate-700">{column.render(row) as any}</td>)}</tr>)}</tbody></table></div></section>;
}

function ExceptionCard({ row }: { row: Row }) {
  return <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="font-semibold text-slate-950">{sourceDisplay(row)}</p><p className="mt-1 text-xs font-bold uppercase tracking-wide text-amber-700">{boxEffect(row)} · {gbp(signedAmount(row))}</p></div><span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-bold text-amber-800">Review</span></div><p className="mt-3 text-sm leading-6 text-slate-700">{cut(row.adjustment_reason || "Sage does not appear to naturally cover this VAT line.", 140)}</p></div>;
}

function Box6Control({ activeRows, allRows, expectedBox6Gbp }: { activeRows: Row[]; allRows: Row[]; expectedBox6Gbp: number }) {
  const activeTotal = signedTotal(activeRows);
  const covered = signedTotal(activeRows.filter((row) => yes(row.natural_sage_covered)));
  const exceptions = activeRows.filter((row) => yes(row.adjustment_required) || !yes(row.natural_sage_covered));
  const reviewTotal = signedTotal(exceptions);
  const variance = activeTotal - expectedBox6Gbp;
  const supersededCount = allRows.filter((row) => text(row.status) === "superseded").length;
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="text-lg font-semibold tracking-tight">Box 6 review</h2><p className="mt-1 text-sm leading-6 text-slate-600">Summary uses active Box 6 rows only. Superseded rows stay in the audit trail below. Decrease rows are shown as negative values.</p></div><span className={`rounded-full px-3 py-1 text-xs font-bold ${exceptions.length ? "bg-amber-100 text-amber-800" : "bg-emerald-100 text-emerald-800"}`}>{exceptions.length} active exception(s)</span></div><div className="mt-4 grid gap-3 md:grid-cols-4"><Metric label="Active signed Box 6" value={gbp(activeTotal)} note={`${activeRows.length} active row(s); ${supersededCount} superseded audit row(s)`} /><Metric label="Expected Box 6" value={gbp(expectedBox6Gbp)} note="vat_return_runs.expected_box6_gbp" /><Metric label="Variance" value={gbp(variance)} note="Active signed total minus expected Box 6" warn={Math.abs(variance) > 0.005} /><Metric label="Needs review" value={gbp(reviewTotal)} note="Possible Sage gap from active rows only" warn={exceptions.length > 0} /></div>{exceptions.length ? <div className="mt-4 grid gap-3">{exceptions.map((row, index) => <ExceptionCard key={`${text(row.id)}-${index}`} row={row} />)}</div> : <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">No active Box 6 timing exceptions found. Matched active lines and superseded rows are kept in the audit trail below.</p>}</section>;
}

export default async function VatReturnPackDetailPage({ params, searchParams }: any) {
  const routeParams = params ? await params : {};
  const queryParams = searchParams ? await searchParams : {};
  const runId = text(routeParams?.return_run_id);
  const activeTab = tabFrom(queryParams?.tab);
  if (!runId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: staff } = await supabase.from("staff").select("id, full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data: runData, error: runError } = await db.from("vat_return_runs").select("id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box2_gbp, expected_box3_gbp, expected_box4_gbp, expected_box5_gbp, expected_box6_gbp, expected_box7_gbp, expected_box8_gbp, expected_box9_gbp, locked_at, created_at").eq("id", runId).maybeSingle();
  const run = (runData ?? {}) as Row;
  if (!runData && !runError) redirect("/internal/accounting-vat");

  const [lines, blockers, journals, journalLines, recon, salesInvoices, supplierEvidence, matchEvidence] = await Promise.all([
    listRows(db, "vat_return_run_lines", "id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json, box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label, natural_sage_covered, adjustment_required, adjustment_reason, status, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "vat_return_blockers", "id, blocker_code, severity, status, owner_role, source_table, source_id, source_ref, message, required_action, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "vat_return_adjustment_journals", "id, vat_return_run_line_id, adjustment_type, target_box, direction, amount_gbp, status, sage_journal_id, sage_journal_ref, posted_at, approved_at, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "vat_return_adjustment_journal_lines", "id, vat_return_adjustment_journal_id, line_no, line_role, account_role, sage_ledger_account_id, sage_ledger_account_display, debit_amount_gbp, credit_amount_gbp, include_on_tax_return, target_box, created_at", (x) => x.order("line_no", { ascending: true })),
    listRows(db, "vat_return_sage_reconstruction_snapshots", "id, created_at, status, source_basis, box1_gbp, box2_gbp, box3_gbp, box4_gbp, box5_gbp, box6_gbp, box7_gbp, box8_gbp, box9_gbp, sales_invoice_count, sales_credit_note_count, purchase_invoice_count, purchase_credit_note_count, warning_notes", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
    listRows(db, "sales_invoices", "id, invoice_type, amount_gbp, sage_status, consideration_received_date, sage_invoice_date, zero_rating_deadline_date, zero_rating_status, sage_invoice_id, created_at", (x) => x.order("created_at", { ascending: false })),
    listRows(db, "supplier_invoices", "id, invoice_ref, ocr_invoice_ref, ocr_invoice_date, ocr_invoice_total_gbp, review_status, blocked_from_sage_yn, mindee_ocr_status, uploaded_at", (x) => x.order("uploaded_at", { ascending: false })),
    listRows(db, "vat_return_sage_match_evidence", "id, vat_return_run_id, sage_return_reference, sage_submitted_box1_gbp, sage_submitted_box2_gbp, sage_submitted_box3_gbp, sage_submitted_box4_gbp, sage_submitted_box5_gbp, sage_submitted_box6_gbp, sage_submitted_box7_gbp, sage_submitted_box8_gbp, sage_submitted_box9_gbp, match_status, matched_at, locked_at, created_at", (x) => x.eq("vat_return_run_id", runId).order("created_at", { ascending: false })),
  ]);

  const latestRecon = recon.rows[0] ?? {};
  const sourceCols: Col[] = [{ label: "Source", render: (row) => sourceDisplay(row) }, { label: "Status", render: (row) => pretty(row.status) }, { label: "Box effect", render: (row) => boxEffect(row) }, { label: "Signed amount", render: (row) => gbp(signedAmount(row)) }, { label: "Signed VAT", render: (row) => gbp(signedVat(row)) }, { label: "Tax point", render: (row) => date(row.tax_point_date) }, { label: "Sage", render: (row) => yes(row.natural_sage_covered) ? "Covered" : "Not covered" }, { label: "Review", render: (row) => yes(row.adjustment_required) ? "Needs review" : "No" }];
  const blockerCols: Col[] = [{ label: "Severity", render: (row) => pretty(row.severity) }, { label: "Status", render: (row) => pretty(row.status) }, { label: "Code", render: (row) => cut(row.blocker_code, 42) }, { label: "Message", render: (row) => cut(row.message, 90) }, { label: "Required action", render: (row) => cut(row.required_action, 90) }];
  const invoiceCols: Col[] = [{ label: "Invoice", render: (row) => cut(row.sage_invoice_id) }, { label: "Type", render: (row) => pretty(row.invoice_type) }, { label: "Amount", render: (row) => gbp(row.amount_gbp) }, { label: "Sage", render: (row) => pretty(row.sage_status) }, { label: "Payment/tax point", render: (row) => date(row.consideration_received_date) }, { label: "Invoice date", render: (row) => date(row.sage_invoice_date) }];
  const purchaseCols: Col[] = [{ label: "Ref", render: (row) => invoiceRef(row) }, { label: "Review status", render: (row) => pretty(row.review_status) }, { label: "OCR date", render: (row) => date(row.ocr_invoice_date || row.uploaded_at) }, { label: "OCR total", render: (row) => gbp(row.ocr_invoice_total_gbp) }, { label: "OCR", render: (row) => pretty(row.mindee_ocr_status) }, { label: "Blocked", render: (row) => yes(row.blocked_from_sage_yn) ? "Yes" : "No" }];
  const journalCols: Col[] = [{ label: "Type", render: (row) => pretty(row.adjustment_type) }, { label: "Box", render: (row) => boxLabel(row.target_box) }, { label: "Direction", render: (row) => pretty(row.direction) }, { label: "Amount", render: (row) => gbp(row.amount_gbp) }, { label: "Status", render: (row) => pretty(row.status) }, { label: "Sage ref", render: (row) => cut(row.sage_journal_ref ?? row.sage_journal_id) }];
  const journalLineCols: Col[] = [{ label: "Journal", render: (row) => cut(row.vat_return_adjustment_journal_id, 18) }, { label: "No", render: (row) => cut(row.line_no) }, { label: "Role", render: (row) => pretty(row.line_role) }, { label: "Account", render: (row) => cut(row.sage_ledger_account_display ?? row.account_role, 40) }, { label: "Debit", render: (row) => gbp(row.debit_amount_gbp) }, { label: "Credit", render: (row) => gbp(row.credit_amount_gbp) }, { label: "Tax return", render: (row) => pretty(row.include_on_tax_return) }, { label: "Box", render: (row) => boxLabel(row.target_box) }];
  const reconCols: Col[] = [{ label: "Created", render: (row) => date(row.created_at) }, { label: "Status", render: (row) => pretty(row.status) }, { label: "Box 1", render: (row) => gbp(row.box1_gbp) }, { label: "Box 4", render: (row) => gbp(row.box4_gbp) }, { label: "Box 6", render: (row) => gbp(row.box6_gbp) }, { label: "Box 7", render: (row) => gbp(row.box7_gbp) }, { label: "Docs", render: (row) => `${text(row.sales_invoice_count)} SI / ${text(row.purchase_invoice_count)} PI` }];
  const matchCols: Col[] = [{ label: "Sage ref", render: (row) => cut(row.sage_return_reference) }, { label: "Box 1", render: (row) => gbp(row.sage_submitted_box1_gbp) }, { label: "Box 2", render: (row) => gbp(row.sage_submitted_box2_gbp) }, { label: "Box 3", render: (row) => gbp(row.sage_submitted_box3_gbp) }, { label: "Box 4", render: (row) => gbp(row.sage_submitted_box4_gbp) }, { label: "Box 5", render: (row) => gbp(row.sage_submitted_box5_gbp) }, { label: "Box 6", render: (row) => gbp(row.sage_submitted_box6_gbp) }, { label: "Box 7", render: (row) => gbp(row.sage_submitted_box7_gbp) }, { label: "Box 8", render: (row) => gbp(row.sage_submitted_box8_gbp) }, { label: "Box 9", render: (row) => gbp(row.sage_submitted_box9_gbp) }, { label: "Status", render: (row) => pretty(row.match_status) }, { label: "Matched", render: (row) => date(row.matched_at) }];

  const allBox6Rows = lines.rows.filter((row) => num(row.box_number) === 6);
  const activeBox6Rows = allBox6Rows.filter(active);
  const box1Rows = lines.rows.filter((row) => num(row.box_number) === 1);
  const purchaseRows = lines.rows.filter((row) => [4, 7].includes(num(row.box_number)));
  const openBlockers = blockers.rows.filter((row) => text(row.status) === "open").length;
  const runStatus = text(run.status);
  const sourceRefreshBlocked = Boolean(run.locked_at) || SOURCE_REFRESH_BLOCKED_STATUSES.has(runStatus);

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto flex max-w-7xl flex-col gap-6"><section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"><Link href="/internal/accounting-vat" className="text-sm font-semibold text-sky-600">← Back to VAT dashboard</Link><p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT return pack</p><div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between"><div><h1 className="text-3xl font-semibold tracking-tight">{cut(run.return_period_label || run.run_ref || run.id, 80)}</h1><p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Review the VAT draft, compare Sage natural VAT, then investigate exceptions and blockers.</p></div><div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{text((staff as Row).full_name) || "Admin"}</div><div>{text((staff as Row).role_type)}</div></div></div></section>{runError ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">VAT run read error: {runError.message}</div> : null}<Workflow run={run} recon={latestRecon} blockers={blockers} journals={journals} matchEvidence={matchEvidence} /><VatWorkspace run={run} recon={latestRecon} /><section className="grid gap-4 md:grid-cols-3"><Metric label="Open blockers" value={String(openBlockers)} note={`${blockers.count} blocker row(s)`} warn={openBlockers > 0} /><Metric label="Source lines" value={String(lines.count)} note="Audit trail rows" /><Metric label="Locked" value={run.locked_at ? "Yes" : "No"} note={run.locked_at ? date(run.locked_at) : "Return is not locked"} /></section><section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-wrap gap-3"><form action={refreshVatSourceSnapshotAction}><input type="hidden" name="vat_return_run_id" value={runId} /><button disabled={sourceRefreshBlocked} className={`rounded-xl px-4 py-2 text-sm font-bold ${sourceRefreshBlocked ? "cursor-not-allowed border border-slate-200 bg-slate-100 text-slate-400" : "border border-slate-300 bg-slate-950 text-white hover:bg-slate-800"}`}>Refresh platform source snapshot</button></form><form action={runVatReconstructionForRunAction}><input type="hidden" name="vat_return_run_id" value={runId} /><button className="rounded-xl border border-sky-200 bg-sky-50 px-4 py-2 text-sm font-bold text-sky-800">Run read-only Sage reconstruction</button></form></div><p className="mt-3 text-xs leading-5 text-slate-600">Refresh platform source snapshot recalculates platform boxes from active platform source lines for this existing period. Sage reconstruction refreshes the read-only Sage natural comparison. No posting is exposed here.</p>{sourceRefreshBlocked ? <p className={`mt-2 text-xs font-semibold ${run.locked_at ? "text-emerald-700" : "text-amber-700"}`}>{run.locked_at ? "Platform source refresh is blocked because this return is locked to Sage submission. Future changes must use correction/reopen flow." : "Platform source refresh is blocked because this return has moved into approval, journal, submission, mismatch or superseded status."}</p> : null}</section><Tabs runId={runId} activeTab={activeTab} />{activeTab === "summary" ? <div className="grid gap-4"><Table title="Sage natural VAT reconstruction history" data={recon} columns={reconCols} /><Table title="Submission evidence" data={matchEvidence} columns={matchCols} empty="No Sage submission evidence captured yet." /><Table title="Exceptions / blockers" data={blockers} columns={blockerCols} empty="No blockers found." /></div> : null}{activeTab === "source" ? <Table title="Source audit trail" data={lines} columns={sourceCols} empty="No source lines exist yet." /> : null}{activeTab === "box6" ? <div className="grid gap-4"><Box6Control activeRows={activeBox6Rows} allRows={allBox6Rows} expectedBox6Gbp={num(run.expected_box6_gbp)} /><Table title="Box 6 audit trail — active and superseded" data={{ ...lines, rows: allBox6Rows }} columns={sourceCols} empty="No Box 6 source lines captured." /><Table title="Sales invoice tax-point evidence" data={salesInvoices} columns={invoiceCols} /></div> : null}{activeTab === "box1" ? <div className="grid gap-4"><section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900"><h2 className="font-semibold">Export evidence / Box 1</h2><p className="mt-2">Review only evidence deadline breaches or reinstatements. Normal lines stay in the audit trail.</p></section><Table title="Box 1 exceptions" data={{ ...lines, rows: box1Rows }} columns={sourceCols} empty="No Box 1 source lines or exceptions captured." /></div> : null}{activeTab === "purchases" ? <div className="grid gap-4"><section className="rounded-3xl border border-slate-200 bg-white p-5 text-sm leading-6 text-slate-700"><h2 className="font-semibold text-slate-950">Box 4 / Box 7 Purchases</h2><p className="mt-2">Platform Box 4 and Box 7 source lines are created from posted supplier AP, shipper AP and supplier credit-note evidence when the platform source snapshot is refreshed.</p></section><Table title="Box 4 / Box 7 source lines" data={{ ...lines, rows: purchaseRows }} columns={sourceCols} empty="No platform Box 4 or Box 7 source lines captured yet." /><Table title="Supplier invoice header evidence" data={supplierEvidence} columns={purchaseCols} /></div> : null}{activeTab === "journals" ? <div className="grid gap-4"><section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm leading-6 text-rose-900"><h2 className="font-semibold">Sage adjustment journals</h2><p className="mt-2">Journal only the Sage gap after statutory values and Sage natural coverage are compared. If the gap is zero, approval and posting are not required for this return.</p></section><Table title="Adjustment journals" data={journals} columns={journalCols} /><Table title="Journal lines" data={journalLines} columns={journalLineCols} /></div> : null}{activeTab === "submission" ? <Table title="Submission evidence" data={matchEvidence} columns={matchCols} empty="No Sage submission evidence captured yet." /> : null}</div></main>;
}
