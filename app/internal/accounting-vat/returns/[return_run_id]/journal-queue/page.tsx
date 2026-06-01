import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { materialiseVatAdjustmentJournalQueueAction } from "../journalQueueAction";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function pretty(value: unknown): string {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

export default async function VatJournalQueueControlPage({ params }: any) {
  const routeParams = params ? await params : {};
  const runId = text(routeParams?.return_run_id);
  if (!runId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data: runData, error: runError } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, locked_at")
    .eq("id", runId)
    .maybeSingle();
  if (!runData && !runError) redirect("/internal/accounting-vat");

  const run = (runData ?? {}) as Row;
  const status = text(run.status);
  const locked = Boolean(text(run.locked_at)) || status === "matched_to_sage_locked";
  const blockedStatus = [
    "sage_adjustment_journals_posted",
    "sage_return_review_required",
    "sage_return_submitted",
    "matched_to_sage_locked",
    "mismatch_needs_admin_review",
    "superseded",
  ].includes(status);
  const canMaterialise = !locked && !blockedStatus;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-3xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-vat/returns/${runId}?tab=journals`} className="text-sm font-semibold text-sky-600">← Back to Sage adjustment journals</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT journal queue control</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Create Sage-gap journal queue</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">This uses the authenticated admin session, so the admin-only RPC can see auth.uid(). It creates platform-calculated VAT adjustment journals only where the platform/Sage gap requires them.</p>
        </section>

        {runError ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">VAT run read error: {runError.message}</div> : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="grid gap-3 text-sm md:grid-cols-2">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Run</p><p className="mt-1 font-bold">{text(run.return_period_label) || text(run.run_ref) || runId}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Status</p><p className="mt-1 font-bold">{pretty(run.status)}</p></div>
          </div>

          {canMaterialise ? (
            <form action={materialiseVatAdjustmentJournalQueueAction} className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4">
              <input type="hidden" name="vat_return_run_id" value={runId} />
              <p className="text-sm font-semibold leading-6 text-amber-950">Create the VAT adjustment journal queue only after the platform source snapshot and read-only Sage reconstruction are current.</p>
              <button className="mt-4 rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Materialise VAT adjustment journal queue</button>
            </form>
          ) : (
            <p className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm font-semibold text-slate-700">Queue creation is blocked for this return status. Locked, submitted, posted, mismatched, or superseded returns must not create new current-period Sage-gap journals.</p>
          )}
        </section>
      </div>
    </main>
  );
}
