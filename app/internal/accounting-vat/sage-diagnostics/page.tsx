import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

function s(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function date(value: unknown): string {
  const raw = s(value).trim();
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }).format(parsed);
}

function money(value: unknown): string {
  const n = typeof value === "number" ? value : Number(s(value));
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number.isFinite(n) ? n : 0);
}

function obj(value: unknown): Row {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
}

function arr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function list(value: unknown): string {
  const values = arr(value).map((item) => s(item)).filter(Boolean);
  return values.length ? values.join(", ") : "—";
}

function shape(summary: unknown, key: string): Row {
  return obj(obj(obj(summary).sage_shape_diagnostic)[key]);
}

function ShapeCard({ title, data }: { title: string; data: Row }) {
  const arrays = arr(data.array_fields).map((item) => obj(item));
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex flex-wrap items-center justify-between gap-3">
      <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
      <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{s(data.count) || "0"} docs</span>
    </div>
    <div className="mt-4 rounded-2xl bg-slate-50 p-4">
      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Top-level keys</p>
      <p className="mt-2 break-words text-sm leading-6 text-slate-800">{list(data.top_level_keys)}</p>
    </div>
    <div className="mt-4 space-y-3">
      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Array / line fields</p>
      {arrays.length === 0 ? <p className="text-sm text-slate-500">No array fields detected on first document.</p> : arrays.map((row, index) => <div key={`${title}-${index}`} className="rounded-2xl border border-slate-200 p-4">
        <p className="text-sm font-bold text-slate-900">{s(row.name) || "array"} <span className="font-normal text-slate-500">({s(row.count) || "0"} rows)</span></p>
        <p className="mt-2 break-words text-sm leading-6 text-slate-700">{list(row.first_keys)}</p>
      </div>)}
    </div>
  </section>;
}

export default async function SageVatDiagnosticsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, active")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || s((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data, error } = await supabase
    .from("vat_return_sage_reconstruction_snapshots")
    .select("id, created_at, period_start_date, period_end_date, status, box1_gbp, box4_gbp, box6_gbp, box7_gbp, sales_invoice_count, sales_credit_note_count, purchase_invoice_count, purchase_credit_note_count, source_summary, warning_notes")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const row = obj(data);
  const summary = obj(row.source_summary);

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
    <div className="mx-auto flex max-w-7xl flex-col gap-6">
      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <Link href="/internal/accounting-vat?tab=sage" className="text-sm font-semibold text-sky-600">← Back to Sage Coverage</Link>
        <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Sage VAT reconstruction diagnostics</p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">Safe Sage field-shape keys</h1>
        <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">This page shows only field names and array names from the latest Sage VAT reconstruction snapshot. It does not show customer names, addresses, invoice payloads, or line values.</p>
      </section>

      {error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-900">Read error: {error.message}</section> : null}
      {!data ? <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm font-semibold text-amber-900">No reconstruction snapshot found yet.</section> : null}

      {data ? <>
        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Snapshot</p><p className="mt-2 text-sm font-semibold text-slate-900">{s(row.id)}</p><p className="mt-2 text-xs text-slate-600">{date(row.created_at)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Period</p><p className="mt-2 text-sm font-semibold text-slate-900">{date(row.period_start_date)} – {date(row.period_end_date)}</p><p className="mt-2 text-xs text-slate-600">{s(row.status)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Boxes</p><p className="mt-2 text-sm font-semibold text-slate-900">B1 {money(row.box1_gbp)} · B4 {money(row.box4_gbp)}</p><p className="mt-2 text-xs text-slate-600">B6 {money(row.box6_gbp)} · B7 {money(row.box7_gbp)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Docs</p><p className="mt-2 text-sm font-semibold text-slate-900">{s(row.sales_invoice_count)} SI / {s(row.sales_credit_note_count)} SCN</p><p className="mt-2 text-xs text-slate-600">{s(row.purchase_invoice_count)} PI / {s(row.purchase_credit_note_count)} PCN</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-lg font-semibold tracking-tight">Current parser source totals</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-4">
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Sales tax</p><p className="mt-2 font-semibold">{money(summary.sales_tax)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Purchase tax</p><p className="mt-2 font-semibold">{money(summary.purchase_tax)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Sales net</p><p className="mt-2 font-semibold">{money(summary.sales_net)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Purchase net</p><p className="mt-2 font-semibold">{money(summary.purchase_net)}</p></div>
          </div>
        </section>

        <div className="grid gap-4 xl:grid-cols-2">
          <ShapeCard title="Sales invoice shape" data={shape(summary, "sales_invoice")} />
          <ShapeCard title="Sales credit note shape" data={shape(summary, "sales_credit_note")} />
          <ShapeCard title="Purchase invoice shape" data={shape(summary, "purchase_invoice")} />
          <ShapeCard title="Purchase credit note shape" data={shape(summary, "purchase_credit_note")} />
        </div>
      </> : null}
    </div>
  </main>;
}
