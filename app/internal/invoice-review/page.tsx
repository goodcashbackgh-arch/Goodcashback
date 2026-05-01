import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  approveSupplierInvoiceCurrentAction,
  rejectSupplierInvoiceRequireResubmissionAction,
  runMindeeOcrForSupplierInvoiceAction,
} from "./actions";
import { assertInvoiceReadyForCurrentApproval } from "./readiness";

type SearchParams = { success?: string; error?: string };

type FinancialSummary = { invoice_total_gbp: number | null };

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
  supplier_invoice_financial_summary: FinancialSummary[] | FinancialSummary | null;
  supplier_invoice_review_flags: { flag_type: string; message: string; status: string }[] | null;
};

function firstRelated<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function getEnteredTotal(invoice: InvoiceRow) {
  const summary = firstRelated(invoice.supplier_invoice_financial_summary);
  return summary?.invoice_total_gbp ?? null;
}

function hasOcrHeader(invoice: InvoiceRow) {
  return Boolean(invoice.ocr_invoice_ref || invoice.ocr_retailer_name || invoice.ocr_invoice_date || invoice.ocr_invoice_total_gbp !== null);
}

function activeReviewFlags(invoice: InvoiceRow) {
  return (invoice.supplier_invoice_review_flags ?? []).filter((flag) => ["open", "under_review"].includes(flag.status));
}

function gbp(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function statusClass(status: string) {
  if (["approved_current", "ref_corrected_approved"].includes(status)) return "bg-emerald-100 text-emerald-800";
  if (["duplicate_blocked"].includes(status)) return "bg-rose-100 text-rose-800";
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
  const visibleInvoices = invoices.filter((invoice) => Boolean(readinessByInvoiceId.get(invoice.id)) || activeReviewFlags(invoice).length > 0);
  const hiddenCleanCount = invoices.length - visibleInvoices.length;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
            <Link href="/internal/supplier-draft-ready" className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-600">Open supplier draft ready →</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Invoice review</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Supplier invoice exceptions queue</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This page shows supplier invoices that need supervisor attention because a match, OCR, total, adjustment, line-settlement, or resubmission issue exists. Rejected invoices are audit-only and are excluded from this active queue. Clean matched invoices flow to Supplier draft ready for bulk approval.
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
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Needs supervisor attention</p><p className="mt-2 text-3xl font-semibold">{visibleInvoices.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Clean / hidden from this queue</p><p className="mt-2 text-3xl font-semibold">{hiddenCleanCount}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Loaded active invoices checked</p><p className="mt-2 text-3xl font-semibold">{invoices.length}</p></div>
        </section>

        <section className="grid gap-4">
          {visibleInvoices.length === 0 ? <p className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm text-emerald-800">No active supplier invoice exceptions found. Clean matched invoices should continue to Supplier draft ready rather than being checked individually here.</p> : null}
          {visibleInvoices.map((invoice) => {
            const enteredTotal = getEnteredTotal(invoice);
            const ocrHeaderPresent = hasOcrHeader(invoice);
            const activeFlags = activeReviewFlags(invoice);
            const retailerMismatch = Boolean(invoice.ocr_retailer_name && invoice.retailers?.name && !invoice.ocr_retailer_name.toLowerCase().includes(String(invoice.retailers.name).toLowerCase()));
            const refMismatch = Boolean(invoice.ocr_invoice_ref && invoice.ocr_invoice_ref !== invoice.invoice_ref);
            const totalMismatch = enteredTotal !== null && invoice.ocr_invoice_total_gbp !== null && Math.abs(Number(enteredTotal) - Number(invoice.ocr_invoice_total_gbp)) >= 0.01;
            const readinessError = readinessByInvoiceId.get(invoice.id) ?? null;
            const alreadyApproved = ["approved_current", "ref_corrected_approved"].includes(invoice.review_status);
            const approveDisabled = alreadyApproved || Boolean(readinessError);

            return (
              <article key={invoice.id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="text-xl font-semibold">{invoice.orders?.order_ref ?? invoice.order_id}</h2>
                      <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${statusClass(invoice.review_status)}`}>{invoice.review_status}</span>
                      {invoice.blocked_from_sage_yn ? <span className="rounded-full bg-rose-100 px-2.5 py-1 text-xs font-semibold text-rose-800">Blocked from Sage</span> : <span className="rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-semibold text-emerald-800">Sage eligible gate</span>}
                      {invoice.is_current_for_order ? <span className="rounded-full bg-sky-100 px-2.5 py-1 text-xs font-semibold text-sky-800">Current for order</span> : null}
                      {!alreadyApproved && !readinessError ? <span className="rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-semibold text-emerald-800">Issue resolved / ready for draft queue</span> : null}
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
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Operator typed ref</p><p className="mt-1 font-semibold">{invoice.invoice_ref}</p></div>
                  <div className={`rounded-2xl p-3 ${refMismatch ? "bg-amber-50" : "bg-slate-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">OCR ref</p><p className="mt-1 font-semibold">{invoice.ocr_invoice_ref ?? "—"}</p></div>
                  <div className={`rounded-2xl p-3 ${retailerMismatch ? "bg-rose-50" : "bg-slate-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">OCR retailer</p><p className="mt-1 font-semibold">{invoice.ocr_retailer_name ?? "—"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">OCR date</p><p className="mt-1 font-semibold">{invoice.ocr_invoice_date ?? "—"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Operator entered final total</p><p className="mt-1 font-semibold">{enteredTotal === null ? "—" : gbp(enteredTotal)}</p></div>
                  <div className={`rounded-2xl p-3 ${totalMismatch ? "bg-amber-50" : "bg-slate-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">OCR total</p><p className="mt-1 font-semibold">{invoice.ocr_invoice_total_gbp === null ? "—" : gbp(invoice.ocr_invoice_total_gbp)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Uploaded</p><p className="mt-1 font-semibold">{new Date(invoice.uploaded_at).toLocaleString("en-GB")}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Flags</p><p className="mt-1 font-semibold">{activeFlags.length}</p></div>
                </div>

                {!ocrHeaderPresent ? <p className="mt-4 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700"><span className="font-semibold">OCR pending / manual test mode:</span> header fields are blank because OCR has not populated them. Do not invent OCR values; use the invoice PDF if a manual correction is needed during testing.</p> : null}

                {activeFlags.length > 0 ? <div className="mt-4 grid gap-2">
                  {activeFlags.map((flag, index) => <p key={`${flag.flag_type}-${index}`} className="rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900"><span className="font-semibold">{flagLabel(flag.flag_type)}:</span> {flag.message}</p>)}
                </div> : null}

                {readinessError && !alreadyApproved ? <p className="mt-4 rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900"><span className="font-semibold">Approval blocked:</span> {readinessError}</p> : null}
                {!readinessError && !alreadyApproved ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">Issue resolved: invoice lines are settled, totals match, and no pending adjustment approvals remain. Use Supplier draft ready for bulk approval.</p> : null}

                <div className="mt-4 grid gap-4 lg:grid-cols-2">
                  <form action={approveSupplierInvoiceCurrentAction} className={`rounded-2xl border p-4 ${approveDisabled ? "border-slate-200 bg-slate-50" : "border-emerald-200 bg-emerald-50"}`}>
                    <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                    <h3 className={`text-sm font-semibold ${approveDisabled ? "text-slate-700" : "text-emerald-950"}`}>Supervisor invoice header review</h3>
                    <p className={`mt-2 text-xs leading-5 ${approveDisabled ? "text-slate-600" : "text-emerald-900"}`}>{ocrHeaderPresent ? "Correct OCR/PDF header values only if the extraction is wrong. Clean invoices should normally move to Supplier draft ready for bulk approval." : "OCR has not populated the header yet. For manual testing, only fill accepted values after checking the invoice PDF."}</p>
                    <div className="mt-3 grid gap-3 md:grid-cols-2">
                      <input name="corrected_invoice_ref" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_ref ?? invoice.invoice_ref} placeholder="Accepted invoice ref" />
                      <input name="ocr_invoice_ref" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_ref ?? ""} placeholder="OCR invoice ref" />
                      <input name="ocr_retailer_name" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_retailer_name ?? ""} placeholder="OCR retailer name" />
                      <input name="ocr_invoice_date" type="date" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_date ?? ""} />
                      <input name="ocr_invoice_total_gbp" type="number" min="0" step="0.01" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" defaultValue={invoice.ocr_invoice_total_gbp ?? enteredTotal ?? ""} placeholder="Accepted/OCR invoice total GBP" />
                      <input name="review_notes" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Review note / correction reason" />
                    </div>
                    <button disabled={approveDisabled} className={`mt-3 rounded-xl px-4 py-2 text-sm font-semibold ${approveDisabled ? "cursor-not-allowed bg-slate-300 text-slate-600" : "bg-emerald-700 text-white hover:bg-emerald-600"}`}>{alreadyApproved ? "Already approved" : "Approve current"}</button>
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
