import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { assertInvoiceReadyForCurrentApproval } from "../invoice-review/readiness";
import { approveSupplierInvoiceCurrentAction, bulkApproveSupplierInvoicesCurrentAction } from "./actions";

type SearchParams = { success?: string; error?: string };

type FinancialSummary = { invoice_total_gbp: number | null };

type OrderRelation = {
  order_ref: string | null;
  order_total_gbp_declared: number | null;
  total_qty_declared: number | null;
  retailers: { name: string | null } | { name: string | null }[] | null;
  importers: { company_name: string | null } | { company_name: string | null }[] | null;
};

type InvoiceRow = {
  id: string;
  order_id: string;
  invoice_ref: string;
  invoice_pdf_url: string;
  uploaded_at: string;
  ocr_invoice_ref: string | null;
  ocr_invoice_total_gbp: number | null;
  review_status: string;
  is_current_for_order: boolean;
  orders: OrderRelation | OrderRelation[] | null;
  supplier_invoice_financial_summary: FinancialSummary[] | FinancialSummary | null;
  supplier_invoice_review_flags: { flag_type: string; status: string }[] | null;
  supplier_invoice_lines: { amount_inc_vat_gbp: number | null; eligible_for_invoice_yn: string | null }[] | null;
  order_value_adjustments: { adjustment_type: string; amount_gbp: number | null; approval_status: string | null }[] | null;
};

function firstRelated<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function getOrder(invoice: InvoiceRow) {
  return firstRelated(invoice.orders);
}

function getOrderRetailerName(invoice: InvoiceRow) {
  const order = getOrder(invoice);
  return firstRelated(order?.retailers)?.name ?? null;
}

function getOrderImporterName(invoice: InvoiceRow) {
  const order = getOrder(invoice);
  return firstRelated(order?.importers)?.company_name ?? null;
}

function gbp(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function money(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function getEnteredTotal(invoice: InvoiceRow) {
  const summary = firstRelated(invoice.supplier_invoice_financial_summary);
  return summary?.invoice_total_gbp ?? null;
}

function lineTotal(invoice: InvoiceRow) {
  return (invoice.supplier_invoice_lines ?? []).reduce((sum, line) => sum + money(line.amount_inc_vat_gbp), 0);
}

function adjustmentTotal(invoice: InvoiceRow, type: string) {
  return (invoice.order_value_adjustments ?? [])
    .filter((row) => row.adjustment_type === type && ["auto_approved", "approved"].includes(String(row.approval_status)))
    .reduce((sum, row) => sum + money(row.amount_gbp), 0);
}

function activeFlagCount(invoice: InvoiceRow) {
  return (invoice.supplier_invoice_review_flags ?? []).filter((flag) => ["open", "under_review"].includes(flag.status)).length;
}

export default async function SupplierDraftReadyPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const qp = await searchParams;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data, error } = await supabase
    .from("supplier_invoices")
    .select(`
      id,
      order_id,
      invoice_ref,
      invoice_pdf_url,
      uploaded_at,
      ocr_invoice_ref,
      ocr_invoice_total_gbp,
      review_status,
      is_current_for_order,
      orders(order_ref, order_total_gbp_declared, total_qty_declared, retailers(name), importers(company_name)),
      supplier_invoice_financial_summary(invoice_total_gbp),
      supplier_invoice_review_flags(flag_type, status),
      supplier_invoice_lines(amount_inc_vat_gbp, eligible_for_invoice_yn),
      order_value_adjustments(adjustment_type, amount_gbp, approval_status)
    `)
    .in("review_status", ["pending_review", "duplicate_blocked"])
    .order("uploaded_at", { ascending: false })
    .limit(100);

  const invoices = (data ?? []) as unknown as InvoiceRow[];
  const readinessEntries = await Promise.all(
    invoices.map(async (invoice) => [
      invoice.id,
      await assertInvoiceReadyForCurrentApproval(supabase, invoice.id),
    ] as const),
  );
  const readinessByInvoiceId = new Map(readinessEntries);
  const readyInvoices = invoices.filter((invoice) => !readinessByInvoiceId.get(invoice.id) && !invoice.is_current_for_order);
  const blockedCount = invoices.length - readyInvoices.length;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-emerald-500">Supplier draft ready</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Clean supplier invoices ready for approval</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This lane shows active invoices that have passed the readiness gate. Approving here marks the supplier invoice as current for later Sage supplier draft preparation; it does not post to Sage yet.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        {error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-800">Failed to load supplier draft queue: {error.message}</section> : null}

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Ready for approval</p><p className="mt-2 text-3xl font-semibold">{readyInvoices.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Blocked elsewhere</p><p className="mt-2 text-3xl font-semibold">{blockedCount}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Loaded active invoices checked</p><p className="mt-2 text-3xl font-semibold">{invoices.length}</p></div>
        </section>

        <form action={bulkApproveSupplierInvoicesCurrentAction} className="grid gap-4">
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
            <p className="text-sm text-slate-600">Select clean invoices below, then bulk approve current. Sage posting remains a later controlled step.</p>
            <button className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-600">Bulk approve selected</button>
          </div>

          {readyInvoices.length === 0 ? <p className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-900">No clean supplier invoices are currently ready. Check the invoice exceptions queue for blocked invoices.</p> : null}

          {readyInvoices.map((invoice) => {
            const order = getOrder(invoice);
            const enteredTotal = getEnteredTotal(invoice);
            const acceptedTotal = invoice.ocr_invoice_total_gbp ?? enteredTotal;
            const delivery = adjustmentTotal(invoice, "retailer_delivery");
            const discount = adjustmentTotal(invoice, "retailer_discount");
            const totalLines = lineTotal(invoice);
            const flagCount = activeFlagCount(invoice);

            return (
              <article key={invoice.id} className="rounded-3xl border border-emerald-200 bg-white p-5 shadow-sm">
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div className="flex gap-3">
                    <input type="checkbox" name="supplier_invoice_id" value={invoice.id} className="mt-1 h-5 w-5 rounded border-slate-300" defaultChecked />
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <h2 className="text-xl font-semibold">{order?.order_ref ?? invoice.order_id}</h2>
                        <span className="rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-semibold text-emerald-800">Ready</span>
                      </div>
                      <p className="mt-2 text-sm text-slate-600">Importer: {getOrderImporterName(invoice) ?? "—"}</p>
                      <p className="text-sm text-slate-600">Retailer: {getOrderRetailerName(invoice) ?? "—"}</p>
                      <p className="text-sm text-slate-600">Invoice ref: {invoice.ocr_invoice_ref ?? invoice.invoice_ref}</p>
                    </div>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Link href={`/internal/evidence/${invoice.order_id}`} className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open order</Link>
                    <Link href={`/internal/reconciliation/${invoice.order_id}`} className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open reconciliation</Link>
                    <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white">Open invoice</a>
                    <button
                      formAction={approveSupplierInvoiceCurrentAction}
                      name="single_supplier_invoice_id"
                      value={invoice.id}
                      className="rounded-xl bg-emerald-700 px-3 py-2 text-sm font-semibold text-white hover:bg-emerald-600"
                    >
                      Approve current
                    </button>
                  </div>
                </div>

                <div className="mt-4 grid gap-3 md:grid-cols-4">
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Accepted total</p><p className="mt-1 font-semibold">{acceptedTotal === null ? "—" : gbp(acceptedTotal)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Line total</p><p className="mt-1 font-semibold">{gbp(totalLines)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Delivery / discount</p><p className="mt-1 font-semibold">{gbp(delivery)} / -{gbp(discount)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Open flags</p><p className="mt-1 font-semibold">{flagCount}</p></div>
                </div>
              </article>
            );
          })}
        </form>
      </div>
    </main>
  );
}
