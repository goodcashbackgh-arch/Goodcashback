import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveSageOnlyPurchaseBucketsAction } from "./actions";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });
function text(v: unknown): string { return typeof v === "string" ? v.trim() : typeof v === "number" && Number.isFinite(v) ? String(v) : ""; }
function num(v: unknown): number { const n = Number(text(v).replace(/,/g, "")); return Number.isFinite(n) ? n : 0; }
function obj(v: unknown): Row { return v && typeof v === "object" && !Array.isArray(v) ? v as Row : {}; }
function gbp(v: unknown): string { return money.format(num(v)); }
function pretty(v: unknown): string { return text(v).replaceAll("_", " ") || "—"; }
function label(v: unknown): string { const s = text(v).replaceAll("[object Object]", "").trim(); return s || "VAT return"; }
function review(s: Row): Row { return obj(obj(s.source_summary).purchase_vat_line_review); }
function buckets(r: Row): Row[] { return Object.entries(obj(r.buckets)).map(([bucket, value]) => ({ bucket, ...obj(value) })); }
function ok(n: number): boolean { return Math.abs(n) <= 0.01; }
function auditDocs(s: Row): Row[] { const audit = obj(obj(s.source_summary).document_status_audit); return [...((obj(audit.purchase_invoices).documents as Row[] | undefined) ?? []), ...((obj(audit.purchase_credit_notes).documents as Row[] | undefined) ?? [])].filter(Boolean); }
function hasAudit(s: Row): boolean { return auditDocs(s).length > 0; }
function close(a: number, b: number): boolean { return Math.abs(a - b) <= 0.01; }

export default async function SageOnlyPurchaseApprovalPage({ params, searchParams }: any) {
  const runId = text((params ? await params : {})?.return_run_id);
  const query = searchParams ? await searchParams : {};
  if (!runId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: staff } = await supabase.from("staff").select("role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (text((staff as Row)?.role_type) !== "admin") redirect("/internal/accounting-vat");

  const [{ data: run }, { data: snapshots }] = await Promise.all([
    (supabase as any).from("vat_return_runs").select("id, run_ref, return_period_label, expected_box4_gbp, expected_box7_gbp").eq("id", runId).maybeSingle(),
    (supabase as any).from("vat_return_sage_reconstruction_snapshots").select("id, box4_gbp, box7_gbp, source_summary").eq("vat_return_run_id", runId).order("created_at", { ascending: false }).limit(20),
  ]);
  if (!run) redirect("/internal/accounting-vat");

  const snapshotRows = (snapshots ?? []) as Row[];
  const snap = snapshotRows.find((s) => text(review(s).version) && hasAudit(s)) ?? snapshotRows.find((s) => text(review(s).version));
  const rows = snap ? buckets(review(snap)).filter((b) => text(b.bucket).startsWith("sage_only")) : [];
  const add4 = rows.reduce((s, r) => s + num(r.box4), 0);
  const add7 = rows.reduce((s, r) => s + num(r.box7), 0);
  const exactEvidence = rows.length === 1 && close(num(rows[0].count), 1);
  const docs = exactEvidence && snap ? auditDocs(snap).filter((d) => close(Math.abs(num(d.tax)), Math.abs(add4)) && close(Math.abs(num(d.net)), Math.abs(add7))).slice(0, 12) : [];
  const after4 = num((run as Row).expected_box4_gbp) + add4;
  const after7 = num((run as Row).expected_box7_gbp) + add7;
  const rem4 = after4 - num(snap?.box4_gbp);
  const rem7 = after7 - num(snap?.box7_gbp);
  const canApprove = Boolean(snap) && rows.length > 0 && ok(rem4) && ok(rem7);
  const err = text(query?.vatError);

  return <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950"><div className="mx-auto flex max-w-5xl flex-col gap-6">
    <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"><Link href={`/internal/accounting-vat/returns/${runId}?tab=purchases`} className="text-sm font-semibold text-sky-600">← Back to Box 4 / Box 7 purchases</Link><p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Final Sage-only purchase approval</p><h1 className="mt-3 text-3xl font-semibold tracking-tight">{label((run as Row).return_period_label || (run as Row).run_ref)}</h1><p className="mt-2 text-sm leading-6 text-slate-600">This final step approves the approvable Sage-only purchase buckets only when Box 4 and Box 7 reconcile to nil difference.</p>{err ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{err}</p> : null}</section>
    <section className="grid gap-4 md:grid-cols-4"><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">Current Box 4</p><p className="mt-2 text-2xl font-extrabold">{gbp((run as Row).expected_box4_gbp)}</p></div><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">After Box 4</p><p className="mt-2 text-2xl font-extrabold">{gbp(after4)}</p></div><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">Current Box 7</p><p className="mt-2 text-2xl font-extrabold">{gbp((run as Row).expected_box7_gbp)}</p></div><div className="rounded-2xl border bg-white p-4"><p className="text-xs font-bold uppercase text-slate-500">After Box 7</p><p className="mt-2 text-2xl font-extrabold">{gbp(after7)}</p></div></section>
    <section className={`rounded-3xl border p-5 text-sm ${canApprove ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}><h2 className="text-lg font-semibold">Balance check</h2><p className="mt-2 font-semibold">Remaining: Box 4 {gbp(rem4)} / Box 7 {gbp(rem7)}</p><p className="mt-1">{canApprove ? "Ready. Approval will reconcile the purchase difference." : "Not ready. Go back to the Box 4 / Box 7 page and resolve the purchase difference first."}</p></section>
    {docs.length ? <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold">Relevant Sage-only document evidence</h2><p className="mt-1 text-sm text-slate-600">Only documents matching the approvable Sage-only Box 4 / Box 7 amount are shown. Use the document reference in Sage, and the Sage API ID for API traceability.</p><div className="mt-4 overflow-x-auto"><table className="min-w-full divide-y divide-slate-200 text-sm"><thead className="text-left text-xs uppercase text-slate-500"><tr><th className="px-3 py-2">Document</th><th className="px-3 py-2">Sage API ID</th><th className="px-3 py-2">Status</th><th className="px-3 py-2">Net</th><th className="px-3 py-2">VAT</th><th className="px-3 py-2">Total</th></tr></thead><tbody className="divide-y divide-slate-100">{docs.map((d) => <tr key={text(d.id) || text(d.document_number)}><td className="px-3 py-2 font-semibold">{label(d.document_number || d.displayed_as)}</td><td className="px-3 py-2">{label(d.id)}</td><td className="px-3 py-2">{label(d.status_displayed_as || d.status)}</td><td className="px-3 py-2">{gbp(d.net)}</td><td className="px-3 py-2">{gbp(d.tax)}</td><td className="px-3 py-2">{gbp(d.total)}</td></tr>)}</tbody></table></div></section> : <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-900"><h2 className="text-lg font-semibold">Relevant Sage-only document evidence</h2><p className="mt-2">Exact document evidence is not shown because the current snapshot does not safely identify a single matching Sage-only document. Re-run Sage reconstruction after the next line-sample patch, or review the detail on the Box 4 / Box 7 page.</p></section>}
    {snap && rows.length ? <form action={approveSageOnlyPurchaseBucketsAction} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><input type="hidden" name="vat_return_run_id" value={runId} /><input type="hidden" name="sage_snapshot_id" value={text(snap.id)} />{rows.map((r) => <input key={text(r.bucket)} type="hidden" name="bucket_keys" value={text(r.bucket)} />)}<div className="flex flex-wrap items-center justify-between gap-3"><div><h2 className="text-lg font-semibold">Approving approvable Sage-only buckets</h2><p className="mt-1 text-sm text-slate-600">Selection and investigation remain on the Box 4 / Box 7 page.</p></div><button disabled={!canApprove} className={`rounded-xl px-4 py-2 text-sm font-bold ${canApprove ? "bg-slate-950 text-white hover:bg-slate-800" : "cursor-not-allowed bg-slate-200 text-slate-500"}`}>Confirm approval into platform VAT return</button></div><div className="mt-5 grid gap-3">{rows.map((r) => <div key={text(r.bucket)} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm"><div className="flex flex-wrap justify-between gap-3"><p className="font-bold">{pretty(r.bucket)}</p><p className="font-semibold">{text(r.count) || "0"} line(s) · Box 4 {gbp(r.box4)} · Box 7 {gbp(r.box7)}</p></div></div>)}</div></form> : <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm font-semibold text-amber-900">No approvable Sage-only purchase buckets found.</section>}
  </div></main>;
}
