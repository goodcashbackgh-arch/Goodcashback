import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type HoldRow = {
  order_id: string;
  order_ref: string | null;
  tracking_submission_id: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  hold_scope: string | null;
  hold_status: string | null;
  set_aside_instruction: string | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

export default async function ShipperCustomerHoldsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: shipperUser } = await supabase
    .from("shipper_users")
    .select("id, full_name, shipper_id, role_at_shipper, shippers(name)")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!shipperUser) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("shipper_customer_hold_set_aside_v1");
  const rows = (data ?? []) as HoldRow[];
  const shipper = Array.isArray((shipperUser as any).shippers) ? (shipperUser as any).shippers[0] : (shipperUser as any).shippers;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/shipper">← Package receipt dashboard</Link>
            <Link href="/shipper/shipments">Shipment batches</Link>
            <Link href="/shipper/package-receipts">Package receipt actions</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Shipper</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Customer hold / set-aside instructions</h1>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            This page only shows operational set-aside instructions approved by supervisor. It does not show customer commercial details, supplier invoice controls, VAT, Sage, or DVA/card information.
          </p>
          <p className="mt-3 text-sm text-slate-600">Welcome: <span className="font-semibold text-slate-900">{shipperUser.full_name}</span> · {shipper?.name ?? "Shipper"}</p>
          {error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Customer hold set-aside queue unavailable: {error.message}. Apply the latest migration before testing this page.</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Set-aside worklist</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Do not ship packages/items shown here until supervisor clears the hold or gives updated instruction.</p>
            </div>
            <div className={`rounded-2xl px-4 py-3 text-sm font-semibold ${rows.length > 0 ? "bg-amber-100 text-amber-900" : "bg-emerald-100 text-emerald-900"}`}>
              {rows.length} active hold(s)
            </div>
          </div>

          {rows.length === 0 ? (
            <p className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No active customer hold instructions for your shipper account.</p>
          ) : (
            <div className="mt-5 grid gap-4">
              {rows.map((row) => (
                <article key={`${row.order_id}-${row.tracking_submission_id ?? "order"}-${row.supplier_invoice_line_id ?? "line"}`} className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
                  <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                    <div>
                      <p className="text-xs font-semibold uppercase tracking-wide text-amber-700">Set aside / do not ship</p>
                      <h3 className="mt-1 text-lg font-semibold text-amber-950">{row.order_ref ?? row.order_id}</h3>
                      <p className="mt-2 text-sm leading-6 text-amber-900">{row.set_aside_instruction ?? "CUSTOMER HOLD — SET ASIDE"}</p>
                    </div>
                    <div className="grid gap-2 text-sm sm:grid-cols-3 lg:min-w-[560px]">
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Scope</p><p className="mt-1 font-semibold">{friendly(row.hold_scope)}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Tracking/package</p><p className="mt-1 font-semibold">{row.tracking_ref ?? "Order-level hold"}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Status</p><p className="mt-1 font-semibold">{friendly(row.hold_status)}</p></div>
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
