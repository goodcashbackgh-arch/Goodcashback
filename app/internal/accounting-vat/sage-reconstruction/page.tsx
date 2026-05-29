import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { reconstructSageVatDraftForRunAction } from "../actions";

type Row = Record<string, unknown>;

const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

function s(v: unknown) {
  if (typeof v === "string") return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return "";
}

function n(v: unknown) {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim()) {
    const parsed = Number(v);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(v: unknown) { return money.format(n(v)); }
function pretty(v: unknown) { const raw = s(v).trim(); return raw ? raw.replaceAll("_", " ") : "—"; }
function date(v: unknown) { const raw = s(v).trim(); if (!raw) return "—"; const d = new Date(raw); if (Number.isNaN(d.getTime())) return raw; return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(d); }
function one(v: unknown) { return Array.isArray(v) ? s(v[0]) : s(v); }

function BoxCard({ label, value, detail }: { label: string; value: unknown; detail: string }) {
  return <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">{label}</p><p className="mt-1 text-2xl font-extrabold text-slate-950">{gbp(value)}</p><p className="mt-2 text-xs leading-5 text-slate-600">{detail}</p></div>;
}

export default async function SageVatReconstructionPage({ searchParams }: any = {}) {
  const params = searchParams ? await searchParams : {};
  const vatError = one(params?.vatError).trim();
  const vatReconstructed = one(params?.vatReconstructed).trim();
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
    return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto max-w-4xl rounded-3xl border border-rose-200 bg-white p-6 shadow-sm"><Link href="/internal/accounting-vat" className="text-sm font-semibold text-sky-600">← Back to VAT workbench</Link><p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-rose-500">Admin-only VAT control</p><h1 className="mt-2 text-3xl font-semibold tracking-tight">Sage VAT reconstruction</h1><p className="mt-3 text-sm leading-6 text-slate-600">Live VAT return controls are restricted to admin users.</p></div></main>;
  }

  const { data: runs } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box4_gbp, expected_box6_gbp, expected_box7_gbp")
    .order("created_at", { ascending: false })
    .limit(20);

  const { data: latest, error: latestError } = await db
    .from("vat_return_sage_reconstruction_snapshots")
    .select("id, vat_return_run_id, period_start_date, period_end_date, status, source_basis, box1_gbp, box2_gbp, box3_gbp, box4_gbp, box5_gbp, box6_gbp, box7_gbp, box8_gbp, box9_gbp, sales_invoice_count, sales_credit_note_count, purchase_invoice_count, purchase_credit_note_count, warning_notes, created_at")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const latestRow = (latest ?? null) as Row | null;

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto flex max-w-7xl flex-col gap-6">
    <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
      <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
        <Link href="/internal/accounting-vat">← VAT workbench</Link>
        <Link href="/internal/sage-mapping">Sage mapping</Link>
      </div>
      <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Read-only Sage coverage</p>
      <h1 className="mt-2 text-3xl font-semibold tracking-tight">Sage VAT draft reconstruction</h1>
      <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">This reconstructs Sage VAT boxes from posted Sage documents for an existing VAT run period. It does not submit to HMRC, post Sage journals, pay VAT, or create any Sage/HMRC write action.</p>
    </section>

    {vatError ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Sage reconstruction failed: {vatError}</div> : null}
    {vatReconstructed ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">Sage VAT reconstruction saved: {vatReconstructed}</div> : null}

    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="text-xl font-semibold tracking-tight">Run read-only reconstruction</h2>
      <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">Choose the VAT return run. The period from that run is used to fetch posted Sage sales invoices, sales credit notes, purchase invoices and purchase credit notes.</p>
      <form action={reconstructSageVatDraftForRunAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_auto]">
        <select name="vat_return_run_id" className="rounded-xl border border-slate-300 bg-white px-3 py-3 text-sm font-medium text-slate-950">
          <option value="">Choose VAT return run</option>
          {((runs ?? []) as Row[]).map((run) => <option key={s(run.id)} value={s(run.id)}>{s(run.run_ref)} · {s(run.return_period_label) || `${date(run.period_start_date)}-${date(run.period_end_date)}`} · {pretty(run.status)}</option>)}
        </select>
        <button className="rounded-xl bg-slate-950 px-4 py-3 text-sm font-semibold text-white">Reconstruct Sage VAT draft for this period</button>
      </form>
    </section>

    {latestError ? <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">Latest reconstruction unavailable: {latestError.message}</div> : null}

    {latestRow ? <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3"><div><h2 className="text-xl font-semibold tracking-tight">Latest Sage reconstruction</h2><p className="mt-1 text-sm text-slate-600">Period {date(latestRow.period_start_date)} to {date(latestRow.period_end_date)} · {pretty(latestRow.source_basis)} · created {date(latestRow.created_at)}</p></div><span className="rounded-full bg-emerald-100 px-3 py-1 text-xs font-bold text-emerald-800">{pretty(latestRow.status)}</span></div>
      <div className="mt-5 grid gap-4 md:grid-cols-3 xl:grid-cols-5">
        <BoxCard label="Box 1" value={latestRow.box1_gbp} detail="Output VAT from posted sales less sales credits." />
        <BoxCard label="Box 2" value={latestRow.box2_gbp} detail="EU acquisitions VAT; currently zero for model." />
        <BoxCard label="Box 3" value={latestRow.box3_gbp} detail="Box 1 + Box 2." />
        <BoxCard label="Box 4" value={latestRow.box4_gbp} detail="Input VAT from posted purchases less purchase credits." />
        <BoxCard label="Box 5" value={latestRow.box5_gbp} detail="Net VAT payable/reclaimable." />
        <BoxCard label="Box 6" value={latestRow.box6_gbp} detail="Net sales from posted sales less sales credits." />
        <BoxCard label="Box 7" value={latestRow.box7_gbp} detail="Net purchases from posted purchases less purchase credits." />
        <BoxCard label="Box 8" value={latestRow.box8_gbp} detail="EU goods supplied; currently zero for model." />
        <BoxCard label="Box 9" value={latestRow.box9_gbp} detail="EU goods acquired; currently zero for model." />
      </div>
      <div className="mt-5 grid gap-3 md:grid-cols-4"><div className="rounded-2xl bg-slate-50 p-4 text-sm"><p className="font-bold">Sales invoices</p><p>{s(latestRow.sales_invoice_count)}</p></div><div className="rounded-2xl bg-slate-50 p-4 text-sm"><p className="font-bold">Sales credits</p><p>{s(latestRow.sales_credit_note_count)}</p></div><div className="rounded-2xl bg-slate-50 p-4 text-sm"><p className="font-bold">Purchase invoices</p><p>{s(latestRow.purchase_invoice_count)}</p></div><div className="rounded-2xl bg-slate-50 p-4 text-sm"><p className="font-bold">Purchase credits</p><p>{s(latestRow.purchase_credit_note_count)}</p></div></div>
      {latestRow.warning_notes ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">{s(latestRow.warning_notes)}</p> : null}
    </section> : <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm text-sm text-slate-600">No Sage VAT reconstruction has been run yet.</section>}

    <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
      <h2 className="font-semibold">Hard control</h2>
      <p className="mt-2">This page is read-only against Sage GET endpoints. It does not contain any VAT submission, Sage journal posting, HMRC payment, or VAT return POST action.</p>
    </section>
  </div></main>;
}
