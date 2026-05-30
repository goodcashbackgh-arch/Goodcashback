import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
const money = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function amount(value: unknown): string {
  const parsed = Number(text(value).replace(/,/g, ""));
  return money.format(Number.isFinite(parsed) ? parsed : 0);
}

function pretty(value: unknown): string {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

export default async function VatJournalDetailPage({ params }: any) {
  const routeParams = params ? await params : {};
  const journalId = text(routeParams?.journal_id);
  if (!journalId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data, error } = await db
    .from("vat_return_adjustment_journals")
    .select("id, vat_return_run_id, adjustment_type, target_box, direction, amount_gbp, status, sage_journal_ref, created_at")
    .eq("id", journalId)
    .maybeSingle();

  const journal = (data ?? {}) as Row;
  const runId = text(journal.vat_return_run_id);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-5xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={runId ? `/internal/accounting-vat/returns/${runId}?tab=journals` : "/internal/accounting-vat?tab=journals"} className="text-sm font-semibold text-sky-600">← Back to VAT journals</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT journal detail</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Sage adjustment journal</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">This page is the journal detail route required by the VAT contract. Full payload preview and reversal controls will be added after the adjustment-pack rules are complete.</p>
        </section>

        {error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Read error: {error.message}</div> : null}

        <section className="grid gap-4 md:grid-cols-2">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Type</p><p className="mt-1 text-xl font-bold">{pretty(journal.adjustment_type)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Status</p><p className="mt-1 text-xl font-bold">{pretty(journal.status)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Target box</p><p className="mt-1 text-xl font-bold">{pretty(journal.target_box)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Amount</p><p className="mt-1 text-xl font-bold">{amount(journal.amount_gbp)}</p></div>
        </section>
      </div>
    </main>
  );
}
