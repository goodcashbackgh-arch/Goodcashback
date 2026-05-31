import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { postVatAdjustmentJournalToSageAction } from "./actions";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;
type SearchParams = { success?: string; error?: string };
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

export default async function VatJournalDetailPage({ params, searchParams }: any) {
  const routeParams = params ? await params : {};
  const qs = searchParams ? await searchParams as SearchParams : {};
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
    .select("id, vat_return_run_id, adjustment_type, target_box, direction, amount_gbp, status, endpoint_path, method, payload_hash, idempotency_key, sage_business_id, sage_journal_id, sage_journal_ref, posted_at, approved_at, last_error, created_at")
    .eq("id", journalId)
    .maybeSingle();

  const journal = (data ?? {}) as Row;
  const runId = text(journal.vat_return_run_id);
  const status = text(journal.status);
  const canPost = status === "admin_approved";

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-5xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={runId ? `/internal/accounting-vat/returns/${runId}?tab=journals` : "/internal/accounting-vat?tab=journals"} className="text-sm font-semibold text-sky-600">← Back to VAT journals</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT journal detail</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Sage adjustment journal</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">Admin-only VAT journal control. Approved journals can be posted to Sage via /journals only after dry-run validation and approval.</p>
          {qs.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-900">{qs.success}</p> : null}
          {qs.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-900">{qs.error}</p> : null}
        </section>

        {error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Read error: {error.message}</div> : null}

        <section className="grid gap-4 md:grid-cols-2">
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Type</p><p className="mt-1 text-xl font-bold">{pretty(journal.adjustment_type)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Status</p><p className="mt-1 text-xl font-bold">{pretty(journal.status)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Target box</p><p className="mt-1 text-xl font-bold">{pretty(journal.target_box)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Amount</p><p className="mt-1 text-xl font-bold">{amount(journal.amount_gbp)}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Sage reference</p><p className="mt-1 break-all text-sm font-bold">{text(journal.sage_journal_ref) || "—"}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Sage journal id</p><p className="mt-1 break-all text-sm font-bold">{text(journal.sage_journal_id) || "—"}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Posting control</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">This action calls Sage /journals server-side using the existing OAuth token-refresh path. It remains blocked unless the live VAT journal posting environment flag is enabled.</p>
          {journal.last_error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">Last error: {text(journal.last_error)}</p> : null}
          {canPost ? (
            <form action={postVatAdjustmentJournalToSageAction} className="mt-5">
              <input type="hidden" name="journal_id" value={journalId} />
              <input type="hidden" name="return_run_id" value={runId} />
              <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Post approved VAT journal to Sage</button>
            </form>
          ) : (
            <p className="mt-4 rounded-xl border border-slate-200 bg-slate-50 p-3 text-sm font-semibold text-slate-700">Posting button appears only when status is admin approved.</p>
          )}
        </section>
      </div>
    </main>
  );
}
