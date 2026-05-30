import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
type Tone = "ok" | "warn" | "block" | "info" | "muted";
type OverlayLine = {
  reportType: string;
  targetBox: "box1" | "box6";
  direction: "add" | "subtract";
  amount: number;
  source: string;
  sourceDate: string;
  reason: string;
};

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

function text(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function object(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function num(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value.replace(/,/g, ""));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(value: unknown): string {
  return money.format(num(value));
}

function round2(value: number): number {
  return Number(value.toFixed(2));
}

function iso(value: unknown): string {
  const raw = text(value).trim();
  return raw ? raw.slice(0, 10) : "";
}

function date(value: unknown): string {
  const raw = iso(value);
  if (!raw) return "—";
  const parsed = new Date(`${raw}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric", timeZone: "UTC" }).format(parsed);
}

function periodKey(value: unknown): string {
  const raw = iso(value);
  return raw.length >= 7 ? raw.slice(0, 7) : "";
}

function periodKeyText(value: unknown): string {
  const raw = text(value).trim();
  return /^\d{4}-\d{2}/.test(raw) ? raw.slice(0, 7) : "";
}

function comparablePeriod(value: unknown): string {
  return periodKeyText(value) || periodKey(value);
}

function inPeriod(value: unknown, start: string, end: string): boolean {
  const raw = iso(value);
  return Boolean(raw && start && end && raw >= start && raw <= end);
}

function beforePeriod(value: unknown, currentKey: string): boolean {
  const period = comparablePeriod(value);
  return Boolean(period && currentKey && period < currentKey);
}

function samePeriod(value: unknown, currentKey: string): boolean {
  const period = comparablePeriod(value);
  return Boolean(period && currentKey && period === currentKey);
}

function isVoid(row: Row): boolean {
  const status = text(row.sage_status).toLowerCase();
  return status.includes("void") || status.includes("cancel") || status.includes("delete");
}

function isCreditNote(row: Row): boolean {
  return text(row.invoice_type).toLowerCase() === "credit_note";
}

function isPosted(row: Row): boolean {
  return text(row.sage_status).toLowerCase().includes("posted");
}

function sourceLabel(row: Row): string {
  return text(row.sage_invoice_id) || text(row.id).slice(0, 8) || "sales invoice";
}

function lineAmount(row: Row): number {
  return round2(num(row.amount_gbp));
}

function sumLines(lines: OverlayLine[]): number {
  return round2(lines.reduce((sum, line) => sum + line.amount, 0));
}

function tone(toneName: Tone): string {
  if (toneName === "ok") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (toneName === "warn") return "border-amber-200 bg-amber-50 text-amber-900";
  if (toneName === "block") return "border-rose-200 bg-rose-50 text-rose-900";
  if (toneName === "info") return "border-sky-200 bg-sky-50 text-sky-900";
  return "border-slate-200 bg-white text-slate-800";
}

function Card({ label, value, detail, state = "muted" }: { label: string; value: string; detail: string; state?: Tone }) {
  return <div className={`rounded-2xl border p-4 shadow-sm ${tone(state)}`}>
    <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p>
    <p className="mt-1 text-2xl font-extrabold">{value}</p>
    <p className="mt-2 text-xs leading-5 opacity-90">{detail}</p>
  </div>;
}

function LinesTable({ title, rows }: { title: string; rows: OverlayLine[] }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
        <p className="mt-1 text-sm leading-6 text-slate-600">Read-only preview. No Sage journal or platform adjustment is posted from this page.</p>
      </div>
      <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{rows.length} lines</span>
    </div>
    <div className="mt-4 overflow-x-auto">
      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500">
          <tr><th className="px-3 py-2">Type</th><th className="px-3 py-2">Box</th><th className="px-3 py-2">Direction</th><th className="px-3 py-2">Amount</th><th className="px-3 py-2">Source</th><th className="px-3 py-2">Date</th><th className="px-3 py-2">Reason</th></tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.length === 0 ? <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={7}>No overlay lines for the selected/latest period.</td></tr> : rows.map((row, index) => <tr key={`${row.reportType}-${row.source}-${index}`}>
            <td className="whitespace-nowrap px-3 py-2 font-semibold text-slate-800">{row.reportType.replaceAll("_", " ")}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{row.targetBox.toUpperCase()}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{row.direction}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{gbp(row.amount)}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{row.source}</td>
            <td className="whitespace-nowrap px-3 py-2 text-slate-700">{date(row.sourceDate)}</td>
            <td className="min-w-[420px] px-3 py-2 text-slate-700">{row.reason}</td>
          </tr>)}
        </tbody>
      </table>
    </div>
  </section>;
}

function ExistingAdjustments({ rows, error }: { rows: Row[]; error: string | null }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <h2 className="text-lg font-semibold tracking-tight">Existing legacy VAT adjustments for this period</h2>
    {error ? <p className="mt-2 text-sm font-semibold text-rose-700">Read error: {error}</p> : null}
    <div className="mt-4 overflow-x-auto">
      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Type</th><th className="px-3 py-2">Direction</th><th className="px-3 py-2">Amount</th><th className="px-3 py-2">Sage ref</th><th className="px-3 py-2">Posted</th><th className="px-3 py-2">Notes</th></tr></thead>
        <tbody className="divide-y divide-slate-100">
          {rows.length === 0 ? <tr><td className="px-3 py-5 text-sm text-slate-500" colSpan={6}>No existing legacy adjustment rows found for this period key.</td></tr> : rows.map((row) => <tr key={text(row.id)}><td className="px-3 py-2 font-semibold text-slate-800">{text(row.report_type).replaceAll("_", " ")}</td><td className="px-3 py-2 text-slate-700">{text(row.direction)}</td><td className="px-3 py-2 text-slate-700">{gbp(row.amount_gbp)}</td><td className="px-3 py-2 text-slate-700">{text(row.sage_journal_ref) || "—"}</td><td className="px-3 py-2 text-slate-700">{date(row.posted_at)}</td><td className="min-w-[300px] px-3 py-2 text-slate-700">{text(row.notes) || "—"}</td></tr>)}
        </tbody>
      </table>
    </div>
  </section>;
}

export default async function PlatformVatOverlayPage() {
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

  if (!staff || text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data: runData, error: runError } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box4_gbp, expected_box6_gbp, expected_box7_gbp, created_at")
    .order("period_end_date", { ascending: false })
    .limit(1)
    .maybeSingle();

  const run = object(runData);
  const runId = text(run.id);
  const periodStart = iso(run.period_start_date);
  const periodEnd = iso(run.period_end_date);
  const currentPeriodKey = periodKey(periodStart);

  let invoices: Row[] = [];
  let invoiceError: string | null = null;
  let recon: Row = {};
  let reconError: string | null = null;
  let adjustments: Row[] = [];
  let adjustmentError: string | null = null;

  if (runId && periodStart && periodEnd) {
    const [invoiceResult, reconResult, adjustmentResult] = await Promise.all([
      db.from("sales_invoices").select("id, order_id, invoice_type, amount_gbp, consideration_received_date, sage_invoice_date, tax_point_period, sage_invoice_period, vat_box6_reported_period, sage_status, sage_invoice_id, zero_rating_deadline_date, zero_rating_status, export_evidence_complete_date, created_at").order("created_at", { ascending: false }).limit(500),
      db.from("vat_return_sage_reconstruction_snapshots").select("id, created_at, vat_return_run_id, status, source_basis, box1_gbp, box4_gbp, box6_gbp, box7_gbp, warning_notes").eq("vat_return_run_id", runId).order("created_at", { ascending: false }).limit(1).maybeSingle(),
      db.from("vat_return_adjustments").select("id, return_period, report_type, source_sales_invoice_id, amount_gbp, direction, sage_journal_ref, posted_at, notes").eq("return_period", currentPeriodKey).order("posted_at", { ascending: false }).limit(100),
    ]);
    invoices = (invoiceResult.data ?? []) as Row[];
    invoiceError = invoiceResult.error?.message ? String(invoiceResult.error.message) : null;
    recon = object(reconResult.data);
    reconError = reconResult.error?.message ? String(reconResult.error.message) : null;
    adjustments = (adjustmentResult.data ?? []) as Row[];
    adjustmentError = adjustmentResult.error?.message ? String(adjustmentResult.error.message) : null;
  }

  const salesRows = invoices.filter((row) => !isVoid(row) && !isCreditNote(row));
  const currentCreditNotes = invoices.filter((row) => isCreditNote(row) && (inPeriod(row.consideration_received_date, periodStart, periodEnd) || inPeriod(row.sage_invoice_date, periodStart, periodEnd)));
  const sageNaturallyCurrent = (row: Row) => isPosted(row) && inPeriod(row.sage_invoice_date, periodStart, periodEnd);

  const box6IncreaseRows = salesRows.filter((row) => inPeriod(row.consideration_received_date, periodStart, periodEnd) && !sageNaturallyCurrent(row));
  const box6DecreaseRows = salesRows.filter((row) => sageNaturallyCurrent(row) && (
    beforePeriod(row.vat_box6_reported_period, currentPeriodKey) ||
    (!samePeriod(row.vat_box6_reported_period, currentPeriodKey) && beforePeriod(row.consideration_received_date, currentPeriodKey))
  ));
  const box1BreachRows = salesRows.filter((row) => {
    const deadline = iso(row.zero_rating_deadline_date);
    const evidence = iso(row.export_evidence_complete_date);
    return inPeriod(deadline, periodStart, periodEnd) && (!evidence || evidence > deadline);
  });
  const box1ReinstatementRows = salesRows.filter((row) => {
    const deadline = iso(row.zero_rating_deadline_date);
    const evidence = iso(row.export_evidence_complete_date);
    const status = text(row.zero_rating_status).toLowerCase();
    return inPeriod(evidence, periodStart, periodEnd) && (status === "reinstated" || Boolean(deadline && evidence > deadline));
  });

  const overlayLines: OverlayLine[] = [
    ...box6IncreaseRows.map((row) => ({
      reportType: "box6_prepayment_increase",
      targetBox: "box6" as const,
      direction: "add" as const,
      amount: lineAmount(row),
      source: sourceLabel(row),
      sourceDate: iso(row.consideration_received_date),
      reason: "Known-goods prepayment is in this VAT period, but Sage has no current-period posted sales invoice natural Box 6 coverage.",
    })),
    ...box6DecreaseRows.map((row) => ({
      reportType: "box6_anti_duplicate_decrease",
      targetBox: "box6" as const,
      direction: "subtract" as const,
      amount: lineAmount(row),
      source: sourceLabel(row),
      sourceDate: iso(row.sage_invoice_date),
      reason: "Sage sales invoice is in this VAT period, but the same value appears to have an earlier Box 6 tax-point/reporting period.",
    })),
    ...box1BreachRows.map((row) => ({
      reportType: "box1_export_evidence_breach",
      targetBox: "box1" as const,
      direction: "add" as const,
      amount: round2(lineAmount(row) / 6),
      source: sourceLabel(row),
      sourceDate: iso(row.zero_rating_deadline_date),
      reason: "Export/zero-rating evidence deadline expires in this VAT period and acceptable evidence is missing or late. VAT-inclusive 1/6 basis used.",
    })),
    ...box1ReinstatementRows.map((row) => ({
      reportType: "box1_export_evidence_reinstatement",
      targetBox: "box1" as const,
      direction: "subtract" as const,
      amount: round2(lineAmount(row) / 6),
      source: sourceLabel(row),
      sourceDate: iso(row.export_evidence_complete_date),
      reason: "Late export evidence/reinstatement falls in this VAT period. Link to the original breach before posting any journal.",
    })),
  ];

  const box6Increase = sumLines(overlayLines.filter((line) => line.reportType === "box6_prepayment_increase"));
  const box6Decrease = sumLines(overlayLines.filter((line) => line.reportType === "box6_anti_duplicate_decrease"));
  const box1Breach = sumLines(overlayLines.filter((line) => line.reportType === "box1_export_evidence_breach"));
  const box1Reinstatement = sumLines(overlayLines.filter((line) => line.reportType === "box1_export_evidence_reinstatement"));
  const netBox6Adjustment = round2(box6Increase - box6Decrease);
  const netBox1Adjustment = round2(box1Breach - box1Reinstatement);

  const sageBox1 = num(recon.box1_gbp);
  const sageBox4 = num(recon.box4_gbp);
  const sageBox6 = num(recon.box6_gbp);
  const sageBox7 = num(recon.box7_gbp);
  const platformBox1 = round2(sageBox1 + netBox1Adjustment);
  const platformBox6 = round2(sageBox6 + netBox6Adjustment);

  const warnings = [
    runError?.message ? `VAT run read error: ${runError.message}` : "",
    invoiceError ? `Sales invoice read error: ${invoiceError}` : "",
    reconError ? `Sage reconstruction read error: ${reconError}` : "",
    !runId ? "No VAT return run exists yet." : "",
    runId && !text(recon.id) ? "No Sage reconstruction snapshot exists for the latest VAT run yet." : "",
    currentCreditNotes.length ? `${currentCreditNotes.length} sales credit note row(s) exist in this period. Credit-note VAT treatment is not included in this first timing overlay.` : "",
  ].filter(Boolean);

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
    <div className="mx-auto flex max-w-7xl flex-col gap-6">
      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <Link href="/internal/accounting-vat" className="text-sm font-semibold text-sky-600">← Back to VAT workbench</Link>
        <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Admin-only VAT timing overlay</p>
        <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <div>
            <h1 className="text-3xl font-semibold tracking-tight">Platform statutory overlay vs Sage natural VAT</h1>
            <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Read-only calculation layer. It previews Box 6 prepayment timing, Box 6 anti-duplication, and Box 1 export evidence breach/reinstatement before any Sage journal queue is built.</p>
          </div>
          <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
            <div className="font-medium text-slate-950">{text((staff as Row).full_name) || "Admin"}</div>
            <div>{text((staff as Row).role_type)}</div>
          </div>
        </div>
      </section>

      {warnings.length ? <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950"><h2 className="font-semibold">Read-only overlay warnings</h2><ul className="mt-2 list-disc space-y-1 pl-5">{warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul></section> : null}

      <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <Card label="Latest VAT run" value={text(run.return_period_label) || text(run.run_ref) || "—"} detail={`${date(run.period_start_date)} – ${date(run.period_end_date)} · ${text(run.status) || "no status"}`} state={runId ? "ok" : "warn"} />
        <Card label="Sage natural Box 6" value={gbp(sageBox6)} detail={text(recon.id) ? `Snapshot ${text(recon.id).slice(0, 8)} · ${text(recon.source_basis)}` : "Run Sage reconstruction before relying on the comparison."} state={text(recon.id) ? "ok" : "warn"} />
        <Card label="Required Box 6 overlay" value={gbp(netBox6Adjustment)} detail={`${gbp(box6Increase)} increase less ${gbp(box6Decrease)} anti-duplicate decrease.`} state={netBox6Adjustment === 0 ? "muted" : "info"} />
        <Card label="Platform target Box 6" value={gbp(platformBox6)} detail="Sage natural Box 6 plus required read-only overlay adjustment." state="info" />
        <Card label="Sage natural Box 1" value={gbp(sageBox1)} detail="From latest Sage reconstruction snapshot for this VAT run." state={text(recon.id) ? "ok" : "warn"} />
        <Card label="Required Box 1 overlay" value={gbp(netBox1Adjustment)} detail={`${gbp(box1Breach)} breach less ${gbp(box1Reinstatement)} reinstatement.`} state={netBox1Adjustment === 0 ? "muted" : "warn"} />
        <Card label="Platform target Box 1" value={gbp(platformBox1)} detail="Sage natural Box 1 plus export evidence breach/reinstatement overlay." state="info" />
        <Card label="Box 4 / Box 7" value={`${gbp(sageBox4)} / ${gbp(sageBox7)}`} detail="Purchase/refund VAT overlay is deliberately not added in this first timing pass." state="muted" />
      </section>

      <section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 text-sm leading-6 text-sky-950">
        <h2 className="font-semibold">Current build boundary</h2>
        <p className="mt-2">This page calculates the read-only statutory overlay only. It does not create VAT return lines, does not create blockers, does not create adjustment journals, and does not post to Sage. The next safe step is to compare this preview to the platform run/source-line pack before generating any journal queue.</p>
      </section>

      <LinesTable title="Platform VAT overlay line preview" rows={overlayLines} />
      <ExistingAdjustments rows={adjustments} error={adjustmentError} />
    </div>
  </main>;
}
