import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { importSageDraftVatReturnTotalsAction } from "./actions";

export const dynamic = "force-dynamic";
export const revalidate = 0;

type Row = Record<string, unknown>;

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function date(value: unknown): string {
  const raw = text(value);
  if (!raw) return "—";
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return raw;
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed);
}

function label(value: unknown, max = 80): string {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

const BOXES = [
  { box: 1, label: "VAT due on sales/outputs" },
  { box: 2, label: "VAT due on acquisitions", optional: true },
  { box: 3, label: "Total VAT due", optional: true },
  { box: 4, label: "VAT reclaimed on purchases/inputs" },
  { box: 5, label: "Net VAT to pay/reclaim", optional: true },
  { box: 6, label: "Net sales/outputs" },
  { box: 7, label: "Net purchases/inputs" },
  { box: 8, label: "EU dispatches", optional: true },
  { box: 9, label: "EU acquisitions", optional: true },
];

export default async function SageDraftVatImportPage({ params, searchParams }: any) {
  const routeParams = params ? await params : {};
  const queryParams = searchParams ? await searchParams : {};
  const runId = text(routeParams?.return_run_id);
  const vatError = text(queryParams?.vatError);
  if (!runId) redirect("/internal/accounting-vat");

  const supabase = await createClient();
  const db = supabase as any;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (text((staff as Row).role_type) !== "admin") redirect("/internal/accounting-vat");

  const { data: run } = await db
    .from("vat_return_runs")
    .select("id, run_ref, return_period_label, period_start_date, period_end_date, status")
    .eq("id", runId)
    .maybeSingle();
  if (!run) redirect("/internal/accounting-vat");

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-5xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/internal/accounting-vat/returns/${runId}?tab=summary`} className="text-sm font-semibold text-sky-600">← Back to VAT return pack</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Sage draft VAT import</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Import Sage draft totals</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This creates the Sage pre-adjustment comparator from the Sage draft VAT return totals. It does not hydrate invoices or post anything to Sage.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{label((run as Row).return_period_label || (run as Row).run_ref)}</div>
              <div>{date((run as Row).period_start_date)} → {date((run as Row).period_end_date)}</div>
            </div>
          </div>
        </section>

        {vatError ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">Import failed: {vatError}</div> : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold tracking-tight">Upload Sage draft VAT return export</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Best source is a Sage draft VAT return XLSX/CSV/text export. The parser extracts the VAT boxes only. If the export format changes, enter the boxes manually below and the uploaded file still acts as evidence.
          </p>

          <form action={importSageDraftVatReturnTotalsAction} className="mt-6 grid gap-5">
            <input type="hidden" name="vat_return_run_id" value={runId} />

            <label className="grid gap-2 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
              <span className="font-semibold text-slate-950">Sage draft file</span>
              <span className="text-xs leading-5 text-slate-600">XLSX, CSV, TSV or plain-text export. Keep it under 2MB.</span>
              <input name="sage_draft_file" type="file" accept=".xlsx,.csv,.tsv,.txt,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/csv,text/plain" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" />
            </label>

            <section className="rounded-2xl border border-slate-200 bg-white p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h3 className="font-semibold text-slate-950">Manual override / fallback</h3>
                  <p className="mt-1 text-xs leading-5 text-slate-600">Required boxes are 1, 4, 6 and 7. Optional boxes can be left blank unless Sage shows a value. Box 3 and Box 5 are calculated if blank.</p>
                </div>
                <span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-bold text-amber-800">Admin must check against Sage</span>
              </div>

              <div className="mt-4 grid gap-3 md:grid-cols-3">
                {BOXES.map((item) => (
                  <label key={item.box} className="grid gap-1 text-sm">
                    <span className="font-medium text-slate-800">Box {item.box}{item.optional ? " (optional)" : ""}</span>
                    <span className="text-xs text-slate-500">{item.label}</span>
                    <input name={`box${item.box}_gbp`} inputMode="decimal" placeholder="0.00" className="rounded-xl border border-slate-200 px-3 py-2 text-sm" />
                  </label>
                ))}
              </div>
            </section>

            <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm leading-6 text-sky-900">
              The result is saved into the existing Sage reconstruction snapshot history, so the current VAT return workspace continues to compare platform draft vs Sage natural totals, then adjustment journals deal with the remaining gap.
            </div>

            <button className="w-fit rounded-xl bg-slate-950 px-5 py-3 text-sm font-bold text-white hover:bg-slate-800">Save Sage draft totals snapshot</button>
          </form>
        </section>
      </div>
    </main>
  );
}
