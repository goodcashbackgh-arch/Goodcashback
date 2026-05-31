import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { refreshVatPurchaseSourceLinesAction } from "../purchaseRefreshAction";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

export default async function VatSourceSnapshotRefreshPage({ params }: any) {
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
  if (text((staff as Row).role_type) !== "admin") redirect(`/internal/accounting-vat/returns/${runId}`);

  const { data: run, error } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status, expected_box1_gbp, expected_box4_gbp, expected_box6_gbp, expected_box7_gbp")
    .eq("id", runId)
    .maybeSingle();

  const row = (run ?? {}) as Row;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-3xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-vat/returns/${runId}`} className="text-sm font-semibold text-sky-600">← Back to VAT pack</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">VAT source snapshot refresh</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Refresh platform source snapshot</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            This refreshes the platform VAT source snapshot for the selected existing period and recalculates platform Boxes 1–9 from active source lines. It does not call Sage, approve journals, post journals, submit to HMRC, or lock the return.
          </p>
        </section>

        {error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Read error: {error.message}</div> : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-lg font-semibold tracking-tight">Selected VAT pack</h2>
          <div className="mt-4 grid gap-3 text-sm md:grid-cols-2">
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Period</p><p className="mt-1 font-semibold text-slate-900">{text(row.return_period_label) || text(row.run_ref) || runId}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Status</p><p className="mt-1 font-semibold text-slate-900">{text(row.status) || "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Current platform Box 1</p><p className="mt-1 font-semibold text-slate-900">£{Number(row.expected_box1_gbp ?? 0).toFixed(2)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Current platform Box 4</p><p className="mt-1 font-semibold text-slate-900">£{Number(row.expected_box4_gbp ?? 0).toFixed(2)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Current platform Box 6</p><p className="mt-1 font-semibold text-slate-900">£{Number(row.expected_box6_gbp ?? 0).toFixed(2)}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Current platform Box 7</p><p className="mt-1 font-semibold text-slate-900">£{Number(row.expected_box7_gbp ?? 0).toFixed(2)}</p></div>
          </div>

          <form action={refreshVatPurchaseSourceLinesAction} className="mt-5">
            <input type="hidden" name="vat_return_run_id" value={runId} />
            <button className="rounded-xl bg-slate-950 px-4 py-3 text-sm font-semibold text-white">Refresh platform source snapshot</button>
          </form>
        </section>
      </div>
    </main>
  );
}
