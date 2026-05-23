import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function TabLink({ title, detail, tone = "muted" }: { title: string; detail: string; tone?: Tone }) {
  return (
    <div className={`rounded-2xl border p-3 shadow-sm ${toneClass(tone)}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{title}</p>
      <p className="mt-1 text-xs leading-5 opacity-90">{detail}</p>
    </div>
  );
}

function FilterBox({ label, placeholder }: { label: string; placeholder?: string }) {
  return (
    <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
      {label}
      <input disabled placeholder={placeholder ?? label} className="rounded-xl border border-slate-300 bg-slate-100 px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-500" />
    </label>
  );
}

const postingCategories = [
  {
    title: "Customer/importer IN",
    code: "customer_receipt_on_account",
    route: "DVA IN → customer receipt/payment-on-account",
    endpoint: "POST /contact_payments · CUSTOMER_RECEIPT",
    status: "first live lane",
  },
  {
    title: "Supplier/retailer OUT",
    code: "supplier_invoice_payment",
    route: "confirmed supplier invoice allocation → posted purchase invoice",
    endpoint: "POST /purchase_payments → POST /allocations",
    status: "after customer IN",
  },
  {
    title: "Shipper OUT",
    code: "shipper_invoice_payment",
    route: "confirmed shipper AP match → posted shipper purchase invoice",
    endpoint: "POST /purchase_payments → POST /allocations",
    status: "after supplier OUT",
  },
  {
    title: "Retailer refund IN",
    code: "retailer_refund_received",
    route: "confirmed retailer refund allocation → posted supplier credit note",
    endpoint: "endpoint-prove-required before live bulk posting",
    status: "blocked first",
  },
  {
    title: "Residuals",
    code: "fx_card_difference / bank_fee / unmatched_hold",
    route: "coded residual allocation only",
    endpoint: "blocked until GL/bank transaction endpoint is proven",
    status: "read-only first",
  },
];

export default async function CashPostingWorkbenchPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);

  if (!canAccess) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-4xl space-y-5">
          <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
            <h1 className="mt-5 text-3xl font-bold tracking-tight">Cash Posting Workbench</h1>
            <p className="mt-3 text-sm leading-6 text-slate-600">This page is admin-accounting controlled. Your current staff role is {pretty(staff.role_type)}.</p>
          </section>
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
            <h2 className="font-bold">Access required</h2>
            <p className="mt-2">For testing, keep the user as supervisor and grant the narrow <code>accounting_admin_testing</code> flag in <code>staff.permissions_json</code>.</p>
          </section>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1600px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Accounting cockpit · cash layer</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Cash Posting Workbench</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
                Read-only scaffold for DVA/card/bank IN and OUT posting. Rows must come from confirmed upstream reconciliations/allocations; this page must not infer customer, retailer, shipper, order or invoice from raw statement text at posting time.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name)}</div>
              <div>{text(staff.role_type)}{accessFromPermissions((staff as Row).permissions_json) ? " · accounting admin testing" : ""}</div>
            </div>
          </div>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full border border-amber-200 bg-amber-50 px-3 py-1 text-amber-900">Phase 1: route + read-only control shell</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">No live Sage cash call on this scaffold</span>
            <span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">Contract: CASH_POSTING_WORKBENCH_CONTRACT_v1</span>
          </div>
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
          <TabLink title="All" detail="All cash posting categories" tone="review" />
          <TabLink title="IN — Customer/importer" detail="DVA receipts/payment-on-account" tone="action" />
          <TabLink title="OUT — Supplier/retailer" detail="Supplier AP payment allocations" />
          <TabLink title="OUT — Shipper" detail="Shipper AP payment allocations" />
          <TabLink title="Residuals" detail="FX/card, bank fee and holds" tone="blocked" />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-6 xl:items-end">
            <FilterBox label="Search" placeholder="Order ref, auth/ref, counterparty" />
            <FilterBox label="Customer/importer" />
            <FilterBox label="Retailer/supplier" />
            <FilterBox label="Shipper" />
            <FilterBox label="Date range" />
            <FilterBox label="Category" />
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            <button disabled className="rounded-lg border border-slate-300 bg-slate-100 px-3 py-1.5 text-[11px] font-bold text-slate-500">Select all visible</button>
            <button disabled className="rounded-lg border border-slate-300 bg-slate-100 px-3 py-1.5 text-[11px] font-bold text-slate-500">Unselect all</button>
            <button disabled className="rounded-lg bg-slate-200 px-3 py-1.5 text-[11px] font-bold text-slate-500">Freeze selected</button>
            <button disabled className="rounded-lg bg-slate-200 px-3 py-1.5 text-[11px] font-bold text-slate-500">Validate selected</button>
            <button disabled className="rounded-lg bg-slate-200 px-3 py-1.5 text-[11px] font-bold text-slate-500">Post selected</button>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3">
            <h2 className="text-xl font-semibold">Cash posting rows</h2>
            <p className="mt-1 text-sm text-slate-500">Grid contract only. The next backend patch should add the read model feeding confirmed customer IN, supplier OUT, shipper OUT, refund IN and residual rows.</p>
          </div>
          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1180px] divide-y divide-slate-200 text-xs">
              <thead className="bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Select</th>
                  <th className="px-3 py-2 text-left">Direction</th>
                  <th className="px-3 py-2 text-left">Category</th>
                  <th className="px-3 py-2 text-left">Date</th>
                  <th className="px-3 py-2 text-left">Customer / retailer / shipper</th>
                  <th className="px-3 py-2 text-left">Order ref</th>
                  <th className="px-3 py-2 text-left">Auth/ref</th>
                  <th className="px-3 py-2 text-right">GBP amount</th>
                  <th className="px-3 py-2 text-left">Matched target</th>
                  <th className="px-3 py-2 text-left">Status</th>
                  <th className="px-3 py-2 text-left">Details</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                <tr>
                  <td colSpan={11} className="px-3 py-8 text-center text-sm text-slate-500">
                    No live rows are queried yet. This shell intentionally has no posting buttons wired until the cash posting read model and mapping rows are added.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section className="grid gap-3 lg:grid-cols-2">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 className="text-lg font-bold">Posting categories locked by contract</h2>
            <div className="mt-4 grid gap-3">
              {postingCategories.map((item) => (
                <div key={item.code} className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm">
                  <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                    <div>
                      <p className="font-bold text-slate-950">{item.title}</p>
                      <p className="mt-1 font-mono text-[11px] text-slate-500">{item.code}</p>
                    </div>
                    <span className="w-fit rounded-full border border-slate-200 bg-white px-3 py-1 text-[11px] font-bold text-slate-700">{item.status}</span>
                  </div>
                  <p className="mt-2 text-xs leading-5 text-slate-600">{item.route}</p>
                  <p className="mt-1 text-xs font-semibold leading-5 text-slate-800">{item.endpoint}</p>
                </div>
              ))}
            </div>
          </div>

          <div className="rounded-3xl border border-violet-200 bg-violet-50 p-5 text-sm leading-6 text-violet-900">
            <h2 className="font-bold">Next backend build</h2>
            <p className="mt-2">Add the read model behind this page before any posting action. It should expose simple rows plus a detail trace for statement line, match source, Sage target and payload preview.</p>
            <div className="mt-4 grid gap-2 rounded-2xl border border-violet-200 bg-white/70 p-3 text-xs font-semibold leading-5">
              <p>1. Add minimum mapping rows: DVA cash bank account, payment method defaults, FX gain/loss, bank fee and hold ledgers.</p>
              <p>2. Add read-only cash posting rows from confirmed DVA funding and statement-line allocations.</p>
              <p>3. Add detail drawer / Posting Trace.</p>
              <p>4. Only then add customer IN freeze/validate/post.</p>
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}
