import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

const gbp = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });
function text(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}
function object(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Row) : {};
}
function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}
function list(value: unknown): string {
  const values = array(value).map(text).filter(Boolean);
  return values.length ? values.join(", ") : "—";
}
function money(value: unknown): string {
  const amount = typeof value === "number" ? value : Number(text(value));
  return gbp.format(Number.isFinite(amount) ? amount : 0);
}
function date(value: unknown): string {
  const raw = text(value).trim();
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "short" }).format(parsed);
}
function shape(summary: Row, key: string): Row {
  return object(object(summary.sage_shape_diagnostic)[key]);
}
function audit(summary: Row, key: string): Row {
  return object(object(summary.document_status_audit)[key]);
}
function count(value: unknown, fallback: unknown = 0): string {
  return text(value) || text(fallback) || "0";
}
function excludedReasons(value: Row): string {
  const reasons = array(value.excluded_documents)
    .map(object)
    .map((row) => text(row.exclusion_reason) || text(row.displayed_as) || text(row.document_number))
    .filter(Boolean);
  return reasons.length ? reasons.join("; ") : "—";
}

function ShapeCard({ title, value }: { title: string; value: Row }) {
  const arrays = array(value.array_fields).map(object);
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex items-center justify-between gap-3">
      <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
      <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{text(value.count) || "0"} docs</span>
    </div>
    <div className="mt-4 rounded-2xl bg-slate-50 p-4">
      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Top-level keys</p>
      <p className="mt-2 break-words text-sm leading-6 text-slate-800">{list(value.top_level_keys)}</p>
    </div>
    <div className="mt-4 space-y-3">
      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Array / line fields</p>
      {arrays.length === 0 ? <p className="text-sm text-slate-500">No array fields detected on first document.</p> : arrays.map((row, index) => <div key={`${title}-${index}`} className="rounded-2xl border border-slate-200 p-4">
        <p className="text-sm font-bold text-slate-900">{text(row.name) || "array"} <span className="font-normal text-slate-500">({text(row.count) || "0"} rows)</span></p>
        <p className="mt-2 break-words text-sm leading-6 text-slate-700">{list(row.first_keys)}</p>
      </div>)}
    </div>
  </section>;
}

function SourceBreakdown({ snapshot, summary }: { snapshot: Row; summary: Row }) {
  const rows = [
    { label: "Sales invoices", audit: audit(summary, "sales_invoices"), fallbackCount: snapshot.sales_invoice_count, net: summary.sales_net, tax: summary.sales_tax, box: "Box 1 + / Box 6 +" },
    { label: "Sales credit notes", audit: audit(summary, "sales_credit_notes"), fallbackCount: snapshot.sales_credit_note_count, net: summary.sales_credit_net, tax: summary.sales_credit_tax, box: "Box 1 - / Box 6 -" },
    { label: "Purchase invoices", audit: audit(summary, "purchase_invoices"), fallbackCount: snapshot.purchase_invoice_count, net: summary.purchase_net, tax: summary.purchase_tax, box: "Box 4 + / Box 7 +" },
    { label: "Purchase credit notes", audit: audit(summary, "purchase_credit_notes"), fallbackCount: snapshot.purchase_credit_note_count, net: summary.purchase_credit_net, tax: summary.purchase_credit_tax, box: "Box 4 - / Box 7 -" },
  ];
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 className="text-lg font-semibold tracking-tight">Sage source breakdown</h2>
        <p className="mt-1 text-sm leading-6 text-slate-600">This is the Sage extraction layer only. It explains the Box 1/4/6/7 movement before platform VAT timing adjustments.</p>
      </div>
      <Link href="/internal/accounting-vat?tab=sage" className="rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-700">Sage Coverage</Link>
    </div>
    <div className="mt-5 overflow-x-auto">
      <table className="w-full min-w-[920px] text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500">
          <tr><th className="border-b border-slate-200 py-3 pr-4">Source</th><th className="border-b border-slate-200 py-3 pr-4">Returned</th><th className="border-b border-slate-200 py-3 pr-4">Included</th><th className="border-b border-slate-200 py-3 pr-4">Excluded</th><th className="border-b border-slate-200 py-3 pr-4">Net included</th><th className="border-b border-slate-200 py-3 pr-4">VAT/tax included</th><th className="border-b border-slate-200 py-3 pr-4">Box treatment</th></tr>
        </thead>
        <tbody>
          {rows.map((row) => <tr key={row.label} className="text-slate-800"><td className="border-b border-slate-100 py-3 pr-4 font-semibold">{row.label}</td><td className="border-b border-slate-100 py-3 pr-4">{count(row.audit.returned_count, row.fallbackCount)}</td><td className="border-b border-slate-100 py-3 pr-4">{count(row.audit.included_count, row.fallbackCount)}</td><td className="border-b border-slate-100 py-3 pr-4">{count(row.audit.excluded_count, 0)}</td><td className="border-b border-slate-100 py-3 pr-4">{money(row.net)}</td><td className="border-b border-slate-100 py-3 pr-4">{money(row.tax)}</td><td className="border-b border-slate-100 py-3 pr-4">{row.box}</td></tr>)}
        </tbody>
      </table>
    </div>
    <div className="mt-5 grid gap-3 md:grid-cols-2">
      <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Sage formula</p><p className="mt-2 text-sm text-slate-700">Box 1 = included sales invoice VAT - included sales credit VAT. Box 4 = included purchase invoice VAT - included purchase credit VAT.</p></div>
      <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Net formula</p><p className="mt-2 text-sm text-slate-700">Box 6 = included sales invoice net - included sales credit net. Box 7 = included purchase invoice net - included purchase credit net.</p></div>
    </div>
  </section>;
}

function DocumentStatusAudit({ summary }: { summary: Row }) {
  const rows = [
    { label: "Sales invoices", value: audit(summary, "sales_invoices") },
    { label: "Sales credit notes", value: audit(summary, "sales_credit_notes") },
    { label: "Purchase invoices", value: audit(summary, "purchase_invoices") },
    { label: "Purchase credit notes", value: audit(summary, "purchase_credit_notes") },
  ];
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h2 className="text-lg font-semibold tracking-tight">Sage document status audit</h2>
        <p className="mt-1 text-sm leading-6 text-slate-600">Each Sage document is now audited before it reaches the VAT box totals. Deleted, voided, cancelled, draft and unposted documents are excluded.</p>
      </div>
    </div>
    <div className="mt-5 overflow-x-auto">
      <table className="w-full min-w-[920px] text-left text-sm">
        <thead className="text-xs uppercase tracking-wide text-slate-500">
          <tr><th className="border-b border-slate-200 py-3 pr-4">Source</th><th className="border-b border-slate-200 py-3 pr-4">Returned</th><th className="border-b border-slate-200 py-3 pr-4">Included</th><th className="border-b border-slate-200 py-3 pr-4">Excluded</th><th className="border-b border-slate-200 py-3 pr-4">Included net</th><th className="border-b border-slate-200 py-3 pr-4">Excluded net</th><th className="border-b border-slate-200 py-3 pr-4">Excluded reason</th></tr>
        </thead>
        <tbody>
          {rows.map((row) => <tr key={row.label} className="text-slate-800"><td className="border-b border-slate-100 py-3 pr-4 font-semibold">{row.label}</td><td className="border-b border-slate-100 py-3 pr-4">{count(row.value.returned_count)}</td><td className="border-b border-slate-100 py-3 pr-4">{count(row.value.included_count)}</td><td className="border-b border-slate-100 py-3 pr-4">{count(row.value.excluded_count)}</td><td className="border-b border-slate-100 py-3 pr-4">{money(row.value.included_net)}</td><td className="border-b border-slate-100 py-3 pr-4">{money(row.value.excluded_net)}</td><td className="border-b border-slate-100 py-3 pr-4">{excludedReasons(row.value)}</td></tr>)}
        </tbody>
      </table>
    </div>
  </section>;
}

function TimingGuardrails() {
  return <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm">
    <h2 className="text-lg font-semibold tracking-tight text-amber-950">Platform VAT timing guardrails</h2>
    <p className="mt-2 text-sm leading-6 text-amber-900">Do not treat the Sage extraction as final VAT return authority. The final VAT preview must overlay the platform VAT workings before sign-off.</p>
    <div className="mt-4 grid gap-3 lg:grid-cols-3">
      <div className="rounded-2xl bg-white/70 p-4"><p className="text-xs font-bold uppercase tracking-wide text-amber-700">Prepayment tax point</p><p className="mt-2 text-sm text-amber-950">Qualifying known-goods prepayments drive Box 6 timing to the extent covered by the payment. Dispatch is fallback only where no qualifying prepayment exists.</p></div>
      <div className="rounded-2xl bg-white/70 p-4"><p className="text-xs font-bold uppercase tracking-wide text-amber-700">Anti-duplication</p><p className="mt-2 text-sm text-amber-950">Later final invoices must not duplicate Box 6 values already reported from an earlier prepayment period. Carry-in/carry-out adjustments must be visible.</p></div>
      <div className="rounded-2xl bg-white/70 p-4"><p className="text-xs font-bold uppercase tracking-wide text-amber-700">Evidence deadline</p><p className="mt-2 text-sm text-amber-950">The 3-month export/evidence window runs from the tax point. Missing evidence blocks zero-rating clearance; deadline breach creates a Box 1 adjustment, later evidence creates a reversal.</p></div>
    </div>
  </section>;
}

export default async function SageVatDiagnosticsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data, error } = await supabase
    .from("vat_return_sage_reconstruction_snapshots")
    .select("id, created_at, period_start_date, period_end_date, status, box1_gbp, box4_gbp, box6_gbp, box7_gbp, sales_invoice_count, sales_credit_note_count, purchase_invoice_count, purchase_credit_note_count, source_summary")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const snapshot = object(data);
  const summary = object(snapshot.source_summary);
  const siAudit = audit(summary, "sales_invoices");
  const scnAudit = audit(summary, "sales_credit_notes");
  const piAudit = audit(summary, "purchase_invoices");
  const pcnAudit = audit(summary, "purchase_credit_notes");

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
    <div className="mx-auto flex max-w-7xl flex-col gap-6">
      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <Link href="/internal/accounting-vat?tab=sage" className="text-sm font-semibold text-sky-600">← Back to Sage Coverage</Link>
        <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Sage VAT reconstruction diagnostics</p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">Latest Sage document status audit</h1>
        <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">This route is dynamic and reads the latest saved snapshot. It shows returned, included and excluded Sage documents, source totals, safe field keys and timing guardrails.</p>
      </section>

      {error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-900">Read error: {error.message}</section> : null}
      {!data ? <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm font-semibold text-amber-900">No reconstruction snapshot found yet.</section> : null}

      {data ? <>
        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Snapshot</p><p className="mt-2 text-sm font-semibold">{text(snapshot.id)}</p><p className="mt-2 text-xs text-slate-600">{date(snapshot.created_at)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Period</p><p className="mt-2 text-sm font-semibold">{date(snapshot.period_start_date)} – {date(snapshot.period_end_date)}</p><p className="mt-2 text-xs text-slate-600">{text(snapshot.status)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Boxes</p><p className="mt-2 text-sm font-semibold">B1 {money(snapshot.box1_gbp)} · B4 {money(snapshot.box4_gbp)}</p><p className="mt-2 text-xs text-slate-600">B6 {money(snapshot.box6_gbp)} · B7 {money(snapshot.box7_gbp)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Included docs</p><p className="mt-2 text-sm font-semibold">{count(siAudit.included_count, snapshot.sales_invoice_count)} SI / {count(scnAudit.included_count, snapshot.sales_credit_note_count)} SCN</p><p className="mt-2 text-xs text-slate-600">{count(piAudit.included_count, snapshot.purchase_invoice_count)} PI / {count(pcnAudit.included_count, snapshot.purchase_credit_note_count)} PCN</p></div>
        </section>
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold tracking-tight">Current included parser source totals</h2><div className="mt-4 grid gap-3 md:grid-cols-4"><div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Sales tax</p><p className="mt-2 font-semibold">{money(summary.sales_tax)}</p></div><div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Purchase tax</p><p className="mt-2 font-semibold">{money(summary.purchase_tax)}</p></div><div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Sales net</p><p className="mt-2 font-semibold">{money(summary.sales_net)}</p></div><div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Purchase net</p><p className="mt-2 font-semibold">{money(summary.purchase_net)}</p></div></div></section>
        <DocumentStatusAudit summary={summary} />
        <SourceBreakdown snapshot={snapshot} summary={summary} />
        <TimingGuardrails />
        <div className="grid gap-4 xl:grid-cols-2"><ShapeCard title="Sales invoice shape" value={shape(summary, "sales_invoice")} /><ShapeCard title="Sales credit note shape" value={shape(summary, "sales_credit_note")} /><ShapeCard title="Purchase invoice shape" value={shape(summary, "purchase_invoice")} /><ShapeCard title="Purchase credit note shape" value={shape(summary, "purchase_credit_note")} /></div>
      </> : null}
    </div>
  </main>;
}
