import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  approveSupplierInvoiceCurrentAction,
  rejectSupplierInvoiceRequireResubmissionAction,
  runMindeeOcrForSupplierInvoiceAction,
} from "./actions";

type SearchParams = { success?: string; error?: string };

type InvoiceRow = {
  id: string;
  order_id: string;
  retailer_id: string;
  invoice_ref: string;
  invoice_pdf_url: string;
  uploaded_at: string;
  ocr_invoice_ref: string | null;
  ocr_invoice_total_gbp: number | null;
  ocr_retailer_name: string | null;
  ocr_invoice_date: string | null;
  review_status: string;
  blocked_from_sage_yn: boolean;
  is_current_for_order: boolean;
  review_notes: string | null;
  orders: {
    order_ref: string | null;
    order_total_gbp_declared: number | null;
    total_qty_declared: number | null;
    retailers: { name: string | null } | null;
    importers: { company_name: string | null } | null;
  } | null;
  retailers: { name: string | null } | null;
  supplier_invoice_financial_summary: { invoice_total_gbp: number | null }[] | null;
  supplier_invoice_review_flags: { flag_type: string; message: string; status: string }[] | null;
};

function gbp(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function statusClass(status: string) {
  if (["approved_current", "ref_corrected_approved"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (["rejected_resubmit_required", "duplicate_blocked"].includes(status)) return "bg-rose-100 text-rose-800";
  if (status === "superseded") return "bg-slate-200 text-slate-700";
  return "bg-amber-100 text-amber-800";
}

function flagLabel(type: string) {
  if (type === "invoice_total_mismatch") return "Invoice total mismatch";
  if (type === "ocr_unclear") return "OCR unclear";
  if (type === "wrong_invoice") return "Wrong invoice";
  if (type === "delivery_discount_query") return "Delivery/discount query";
  if (type === "manual_line_needed") return "Manual line needed";
  return "Other";
}

export default async function InternalInvoiceReviewPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
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
      retailer_id,
      invoice_ref,
      invoice_pdf_url,
      uploaded_at,
      ocr_invoice_ref,
      ocr_invoice_total_gbp,
      ocr_retailer_name,
      ocr_invoice_date,
      review_status,
      blocked_from_sage_yn,
      is_current_for_order,
      review_notes,
      orders(order_ref, order_total_gbp_declared, total_qty_declared, retailers(name), importers(company_name)),
      retailers(name),
      supplier_invoice_financial_summary(invoice_total_gbp),
      supplier_invoice_review_flags(flag_type, message, status)
    `)
    .in("review_status", ["pending_review", "duplicate_blocked", "rejected_resubmit_required", "approved_current", "ref_corrected_approved"])
    .order("uploaded_at", { ascending: false })
    .limit(100);

  const invoices = (data ?? []) as unknown as InvoiceRow[];
  const pending = invoices.filter((invoice) => invoice.review_status === "pending_review" || invoice.blocked_from_sage_yn);
  const reviewed = invoices.filter((invoice) => !pending.includes(invoice));

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Invoice review</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Supplier invoice approval gate</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Approve the correct invoice as current for the order, correct small reference/OCR header issues, or reject wrong invoices for operator resubmission. Only approved-current invoices should feed final invoice drafting and Sage.
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

        {error ? <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-800">Failed to load invoice review queue: {error.message}</section> : null}

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Pending/blocked</p><p className="mt-2 text-3xl font-semibold">{pending.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Reviewed visible</p><p className="mt-2 text-3xl font-semibold">{reviewed.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Loaded invoices</p><p className="mt-2 text-3xl font-semibold">{invoices.length}</p></div>
        </section>

        <section className="grid gap-4">
          {invoices.length === 0 ? <p className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm text-emerald-800">No invoices found for review.</p> : null}
          {invoices.map((invoice) => {
            const enteredTotal = invoice.supplier_invoice_financial_summary?.[0]?.invoice_total_gbp ?? null;
            const activeFlags = (invoice.supplier_invoice_review_flags ?? []).filter((flag) => ["open", "under_review"].includes(flag.status));
            const retailerMismatch = Boolean(invoice.ocr_retailer_name && invoice.retailers?.name && !invoice.ocr_retailer_name.toLowerCase().includes(String(invoice.retailers.name).toLowerCase()));
            const refMismatch = Boolean(invoice.ocr_invoice_ref && invoice.ocr_invoice_ref !== invoice.invoice_ref);
            const totalMismatch = enteredTotal !== null && invoice.ocr_invoice_total_gbp !== null && Math.abs(Number(enteredTotal) - Number(invoice.ocr_invoice_total_gbp)) >= 0.01;

            return (
              <article key={invoice.id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="text-xl font-semibold">{invoice.orders?.order_ref ?? invoice.order_id}</h2>
                      <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${statusClass(invoice.review_status)}`}>{invoice.review_status}</span>
                      {invoice.blocked_from_sage_yn ? <span className="rounded-full bg-rose-100 px-2.5 py-1 text-xs font-semibold text-rose-800">Blocked from Sage</span> : <span className="rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-semibold text-emerald-800">Sage eligible gate</span>}
                      {invoice.is_current_for_order ? <span className="rounded-full bg-sky-100 px-2.5 py-1 text-xs font-semibold text-sky-800">Current for order</span> : null}
                    </div>
                    <p className="mt-2 text-sm text-slate-600">Importer: {invoice.orders?.importers?.company_name ?? "—"}</p>
                    <p className="text-sm text-slate-600">Order retailer: {invoice.orders?.retailers?.name ?? invoice.retailers?.name ?? "—"}</p>
                    <p className="text-sm text-slate-600">Order goods baseline: {gbp(invoice.orders?.order_total_gbp_declared)} · Qty {invoice.orders?.total_qty_declared ?? "—"}</p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Link href={`/internal/evidence/${invoice.order_id}`} className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open staff order detail</Link>
                    <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white">Open invoice</a>
                    <form action={runMindeeOcrForSupplierInvoiceAction}>
                      <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                      <button className="rounded-xl border border-violet-300 bg-violet-50 px-3 py-2 text-sm font-semibold text-violet-800 hover:bg-violet-100">Run Mindee OCR</button>
                    </form>
                  </div>
                </div>

                <div className="mt-4 grid gap-3 md:grid-cols-4">
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Typed ref</p><p className="mt-1 font-semibold">{invoice.invoice_ref}</p></div>
                  <div className={`rounded-2xl p-3 ${refMismatch ? "bg-amber-50" : "bg-slate-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">OCR ref</p><p className="mt-1 font-semibold">{invoice.ocr_invoice_ref ?? "—"}</p></div>
                  <div className={`rounded-2xl p-3 ${retailerMismatch ? "bg-rose-50" : "bg-slate-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">OCR retailer</p><p className="mt-1 font-semibold">{invoice.ocr_retailer_name ?? "—"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">OCR date</p><p className="mt-1 font-semibold">{invoice.ocr_invoice_date ?? "—"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Entered final total</p><p className="mt-1 font-semibold">{enteredTotal === null ? "—" : gbp(enteredTotal)}</p></div>
                  <div className={`rounded-2xl p-3 ${totalMismatch ? "bg-amber-50" : "bg-slate-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">OCR total</p><p className="mt-1 font-semibold">{invoice.ocr_invoice_total_gbp === null ? "—" : gbp(invoice.ocr_invoice_total_gbp)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Uploaded</p><p className="mt-1 font-semibold">{new Date(invoice.uploaded_at).toLocaleString("en-GB")}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Flags</p><p className="mt-1 font-semibold">{activeFlags.length}</p></div>
                </div>

                {activeFlags.length > 0 ? <div className="mt-4 grid gap-2">
                  {activeFlags.map((flag, index) => <p key={`${flag.flag_type}-${index}`} className="rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900"><span className="font-semibold">{flagLabel(flag.flag_type)}:</span> {flag.message}</p>)}
                </div> : null}

                <div className="mt-4 grid gap-4 lg:grid-cols-2">
                  <form action={approveSupplierInvoiceCurrentAction} className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
                    <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                    <h3 className="text-sm font-semibold text-emerald-950">Approve / correct header and approve current</h3>
                    <div className="mt-3 grid gap-3 md:grid-cols-2">
                      <input name="corrected_invoice_ref" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_ref ?? invoice.invoice_ref} placeholder="Correct invoice ref" />
                      <input name="ocr_invoice_ref" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_ref ?? ""} placeholder="OCR invoice ref" />
                      <input name="ocr_retailer_name" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_retailer_name ?? ""} placeholder="OCR retailer name" />
                      <input name="ocr_invoice_date" type="date" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_date ?? ""} />
                      <input name="ocr_invoice_total_gbp" type="number" min="0" step="0.01" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_total_gbp ?? enteredTotal ?? ""} placeholder="OCR invoice total GBP" />
                      <input name="review_notes" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Review note" />
                    </div>
                    <button className="mt-3 rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-600">Approve current</button>
                  </form>

                  <form action={rejectSupplierInvoiceRequireResubmissionAction} className="rounded-2xl border border-rose-200 bg-rose-50 p-4">
                    <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                    <h3 className="text-sm font-semibold text-rose-950">Reject / require resubmission</h3>
                    <p className="mt-2 text-xs leading-5 text-rose-900">Use when the uploaded file is wrong, retailer is wrong, duplicate is unsafe, or evidence cannot be corrected from the invoice PDF.</p>
                    <div className="mt-3 grid gap-2 md:grid-cols-[1fr_auto]">
                      <input name="review_notes" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Reason for resubmission" />
                      <button className="rounded-xl border border-rose-300 bg-white px-4 py-2 text-sm font-semibold text-rose-800 hover:bg-rose-100">Reject</button>
                    </div>
                  </form>
                </div>

                {invoice.review_notes ? <p className="mt-4 rounded-xl bg-slate-50 px-3 py-2 text-sm text-slate-700">Previous notes: {invoice.review_notes}</p> : null}
              </article>
            );
          })}
        </section>
      </div>
    </main>
  );
}
