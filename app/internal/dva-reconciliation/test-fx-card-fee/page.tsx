import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { allocateStatementLineToFxCardOrFeeAction } from "../actions";

const TEST_LINE_REF = "TEST OUT DVA FX CARD FEE 001";

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  return typeof value === "string" ? value : "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

export default async function FocusedDvaFxCardFeeTestPage() {
  const supabase = await createClient();

  const { data: lines, error: lineError } = await supabase
    .from("dva_statement_line_allocation_summary_vw")
    .select("*")
    .eq("reference_raw", TEST_LINE_REF)
    .limit(1);

  const line = lines?.[0] ?? null;
  const remaining = Math.max(0, num(line?.confirmed_unallocated_gbp)).toFixed(2);
  const canAllocate = Boolean(line && text(line.direction) === "out" && !line.confirmed_balanced_yn && Number(remaining) > 0);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-4xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-reconciliation" className="text-sm font-semibold text-sky-600">← Back to DVA workbench</Link>
          <h1 className="mt-4 text-3xl font-semibold tracking-tight">Focused FX/card/fee allocation test</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">
            This proves the residual allocation path: one OUT line with a supplier-invoice allocation and a remaining balance → allocate the residual to FX/card difference or bank fee.
          </p>
        </section>

        {lineError ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">
            <p className="font-semibold">Read error</p>
            <pre className="mt-2 whitespace-pre-wrap text-xs">{JSON.stringify(lineError, null, 2)}</pre>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Statement line</h2>
          {line ? (
            <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
              <div><dt className="font-semibold text-slate-500">Line ID</dt><dd>{text(line.dva_statement_line_id)}</dd></div>
              <div><dt className="font-semibold text-slate-500">Direction</dt><dd>{text(line.direction) || "—"}</dd></div>
              <div><dt className="font-semibold text-slate-500">Reference</dt><dd>{text(line.reference_raw) || "—"}</dd></div>
              <div><dt className="font-semibold text-slate-500">Card/ref</dt><dd>{text(line.retailer_name_ref) || "—"}</dd></div>
              <div><dt className="font-semibold text-slate-500">Statement amount</dt><dd>{gbp(line.statement_gbp_amount)}</dd></div>
              <div><dt className="font-semibold text-slate-500">Confirmed allocated</dt><dd>{gbp(line.confirmed_allocated_gbp)}</dd></div>
              <div><dt className="font-semibold text-slate-500">Supplier invoice allocated</dt><dd>{gbp(line.supplier_invoice_allocated_gbp)}</dd></div>
              <div><dt className="font-semibold text-slate-500">FX/card/fees allocated</dt><dd>{gbp(line.fx_card_or_fee_allocated_gbp)}</dd></div>
              <div><dt className="font-semibold text-slate-500">Remaining</dt><dd>{gbp(line.confirmed_unallocated_gbp)}</dd></div>
              <div><dt className="font-semibold text-slate-500">Balanced</dt><dd>{line.confirmed_balanced_yn ? "Yes" : "No"}</dd></div>
            </dl>
          ) : (
            <p className="mt-4 text-sm text-slate-600">No test line found. Seed TEST OUT DVA FX CARD FEE 001 first.</p>
          )}
        </section>

        <section className="rounded-3xl border border-sky-200 bg-sky-50 p-6 shadow-sm">
          <h2 className="text-xl font-semibold text-sky-950">Residual allocation action</h2>
          {canAllocate ? (
            <form action={allocateStatementLineToFxCardOrFeeAction} className="mt-4 max-w-sm space-y-3">
              <input type="hidden" name="dva_statement_line_id" value={text(line?.dva_statement_line_id)} />
              <label className="block text-sm font-semibold text-sky-950">Allocation type</label>
              <select className="w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="allocation_type" defaultValue="fx_card_difference">
                <option value="fx_card_difference">FX/card difference</option>
                <option value="bank_fee">Bank fee</option>
              </select>
              <label className="block text-sm font-semibold text-sky-950">Amount to allocate</label>
              <input className="w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="allocated_gbp_amount" type="number" min="0.01" step="0.01" defaultValue={remaining} />
              <input className="w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="notes" placeholder="Optional note" />
              <button className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white" type="submit">Allocate residual</button>
            </form>
          ) : (
            <p className="mt-4 text-sm text-slate-700">No residual allocation available. The line is missing, already balanced, or has no remaining balance.</p>
          )}
        </section>
      </div>
    </main>
  );
}
