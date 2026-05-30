import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { generateNextSageVatDraftRunAction } from "./actions";
import VatWorkflowPreview from "./VatWorkflowPreview";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

function text(v: unknown): string {
  if (typeof v === "string") return v.trim();
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  return "";
}
function num(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  const parsed = Number(text(v).replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}
function gbp(v: unknown): string { return money.format(num(v)); }
function pretty(v: unknown): string { const raw = text(v); return raw ? raw.replaceAll("_", " ") : "—"; }
function cut(v: unknown, max = 46): string { const raw = text(v); return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw || "—"; }
function date(v: unknown): string {
  const raw = text(v);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed);
}
async function countRows(db: any, table: string, configure?: (q: any) => any) {
  let query = db.from(table).select("*", { count: "exact", head: true });
  if (configure) query = configure(query);
  const { count, error } = await query;
  return { count: count ?? 0, error: error?.message ? String(error.message) : null };
}
function Card({ label, value, detail, ok }: { label: string; value: string; detail: string; ok?: boolean }) {
  return <div className={`rounded-2xl border p-4 shadow-sm ${ok === false ? "border-amber-200 bg-amber-50 text-amber-900" : "border-sky-200 bg-sky-50 text-sky-900"}`}><p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p><p className="mt-1 text-2xl font-extrabold">{value}</p><p className="mt-2 text-xs leading-5 opacity-90">{detail}</p></div>;
}

export default async function InternalAccountingVatPage() {
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
  if (text((staff as Row).role_type) !== "admin") redirect("/internal");

  const [runsCount, linesCount, blockersCount, openBlockersCount, journalsCount, journalLinesCount] = await Promise.all([
    countRows(db, "vat_return_runs"),
    countRows(db, "vat_return_run_lines"),
    countRows(db, "vat_return_blockers"),
    countRows(db, "vat_return_blockers", (q) => q.eq("status", "open")),
    countRows(db, "vat_return_adjustment_journals"),
    countRows(db, "vat_return_adjustment_journal_lines"),
  ]);

  const { data: runsData, error: runsError } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box4_gbp, expected_box6_gbp, expected_box7_gbp, locked_at, created_at")
    .order("period_start_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(25);

  const { data: blockersData, error: blockersError } = await db
    .from("vat_return_blockers")
    .select("id, vat_return_run_id, blocker_code, severity, status, source_table, source_ref, message, required_action, created_at")
    .order("created_at", { ascending: false })
    .limit(25);

  const { data: journalsData, error: journalsError } = await db
    .from("vat_return_adjustment_journals")
    .select("id, vat_return_run_id, adjustment_type, target_box, direction, amount_gbp, status, sage_journal_ref, posted_at, created_at")
    .order("created_at", { ascending: false })
    .limit(25);

  const runs = (runsData ?? []) as Row[];
  const blockers = (blockersData ?? []) as Row[];
  const journals = (journalsData ?? []) as Row[];
  const foundationOk = !runsCount.error && !linesCount.error && !blockersCount.error && !journalsCount.error && !journalLinesCount.error;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Admin-only VAT Return Workbench</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">VAT control dashboard</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">Control room for VAT return packs, blockers, and journal readiness. Detailed VAT work happens inside each return pack.</p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{text((staff as Row).full_name) || "Admin"}</div><div>{text((staff as Row).role_type)}</div></div>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <Card label="Foundation layer" value={foundationOk ? "Present" : "Missing"} detail={foundationOk ? "Core VAT tables visible." : "Apply the VAT foundation migration first."} ok={foundationOk} />
          <Card label="Open blockers" value={String(openBlockersCount.count)} detail={`${blockersCount.count} blocker records total.`} ok={openBlockersCount.count === 0} />
          <Card label="Return packs" value={String(runsCount.count)} detail={`${linesCount.count} source-line rows.`} />
          <Card label="Adjustment journals" value={String(journalsCount.count)} detail={`${journalLinesCount.count} journal lines.`} />
        </section>

        <GeneratePanel foundationOk={foundationOk} />
        <VatWorkflowPreview />

        <section className="grid gap-4 md:grid-cols-2">
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm leading-6 text-emerald-900"><h2 className="font-semibold">What matters first</h2><p className="mt-2">Open the earliest unlocked return pack and resolve its blockers before generating or progressing later periods.</p></div>
          <div className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900"><h2 className="font-semibold">No submission route</h2><p className="mt-2">This dashboard does not post journals, pay VAT, submit to HMRC, or lock a return.</p></div>
        </section>

        {runsError ? <ReadError label="VAT packs" message={runsError.message} /> : <RunsTable rows={runs} />}
        {blockersError ? <ReadError label="Blockers" message={blockersError.message} /> : <BlockersList rows={blockers} />}
        {journalsError ? <ReadError label="Journals" message={journalsError.message} /> : <JournalsList rows={journals} />}
      </div>
    </main>
  );
}

function GeneratePanel({ foundationOk }: { foundationOk: boolean }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-xl font-semibold tracking-tight">Generate VAT Return Pack</h2><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">Creates the next permitted return pack only when no earlier return pack is still open. It does not post to Sage, submit to HMRC, or lock a return.</p><form action={generateNextSageVatDraftRunAction} className="mt-4"><button disabled={!foundationOk} className={`rounded-xl px-4 py-3 text-sm font-semibold ${foundationOk ? "bg-slate-950 text-white" : "cursor-not-allowed bg-slate-200 text-slate-500"}`}>Generate next VAT return pack</button></form></section>;
}
function ReadError({ label, message }: { label: string; message: string }) { return <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{label} read error: {message}</div>; }
function RunsTable({ rows }: { rows: Row[] }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-center justify-between"><h2 className="text-lg font-semibold tracking-tight">VAT return packs</h2><span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-xs font-bold text-slate-600">{rows.length} shown</span></div><div className="mt-4 overflow-x-auto"><table className="min-w-full divide-y divide-slate-200 text-left text-sm"><thead className="text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2">Run</th><th className="px-3 py-2">Period</th><th className="px-3 py-2">Start</th><th className="px-3 py-2">End</th><th className="px-3 py-2">Status</th><th className="px-3 py-2">Box 6</th><th className="px-3 py-2">Action</th></tr></thead><tbody className="divide-y divide-slate-100">{rows.length === 0 ? <tr><td colSpan={7} className="px-3 py-5 text-slate-500">No VAT return packs yet.</td></tr> : rows.map((row) => <tr key={text(row.id)}><td className="px-3 py-2">{cut(row.run_ref)}</td><td className="px-3 py-2">{cut(row.return_period_label, 60)}</td><td className="px-3 py-2">{date(row.period_start_date)}</td><td className="px-3 py-2">{date(row.period_end_date)}</td><td className="px-3 py-2">{pretty(row.status)}</td><td className="px-3 py-2">{gbp(row.expected_box6_gbp)}</td><td className="px-3 py-2"><Link className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-xs font-bold text-sky-800" href={`/internal/accounting-vat/returns/${text(row.id)}`}>Open pack</Link></td></tr>)}</tbody></table></div></section>;
}
function BlockersList({ rows }: { rows: Row[] }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-center justify-between"><h2 className="text-lg font-semibold tracking-tight">VAT blockers</h2><Link href="/internal/accounting-vat/blockers" className="text-sm font-semibold text-sky-700">Open blocker page →</Link></div><div className="mt-4 grid gap-3">{rows.length === 0 ? <p className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-600">No blockers found.</p> : rows.map((row) => <div key={text(row.id)} className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><div className="flex flex-wrap justify-between gap-3"><p className="font-semibold text-slate-950">{cut(row.blocker_code, 70)}</p>{text(row.vat_return_run_id) ? <Link href={`/internal/accounting-vat/returns/${text(row.vat_return_run_id)}`} className="text-sm font-semibold text-sky-700">Open pack</Link> : null}</div><p className="mt-2 text-sm text-slate-700">{cut(row.message, 150)}</p><p className="mt-1 text-xs font-semibold uppercase tracking-wide text-slate-500">{pretty(row.severity)} · {pretty(row.status)}</p></div>)}</div></section>;
}
function JournalsList({ rows }: { rows: Row[] }) {
  return <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="text-lg font-semibold tracking-tight">VAT adjustment journals</h2><div className="mt-4 grid gap-3">{rows.length === 0 ? <p className="rounded-2xl bg-slate-50 p-4 text-sm text-slate-600">No adjustment journals yet.</p> : rows.map((row) => <div key={text(row.id)} className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><div className="flex flex-wrap justify-between gap-3"><p className="font-semibold text-slate-950">{pretty(row.adjustment_type)} · {gbp(row.amount_gbp)}</p><Link href={`/internal/accounting-vat/journals/${text(row.id)}`} className="text-sm font-semibold text-sky-700">Open journal</Link></div><p className="mt-1 text-xs font-semibold uppercase tracking-wide text-slate-500">{pretty(row.status)} · {pretty(row.target_box)} · {pretty(row.direction)}</p></div>)}</div></section>;
}
