import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { fetchAndSaveMindeeOcrResultAction, rejectSupplierInvoiceRequireResubmissionAction, runMindeeOcrForSupplierInvoiceAction, saveSupplierInvoiceHeaderReviewAction } from "./actions";
import { assertInvoiceReadyForCurrentApproval } from "./readiness";

type SearchParams = { success?: string; error?: string };
type MaybeArray<T> = T | T[] | null | undefined;
type InvoiceRow = {
  id: string;
  order_id: string;
  invoice_ref: string;
  invoice_pdf_url: string;
  uploaded_at: string;
  ocr_invoice_ref: string | null;
  ocr_invoice_total_gbp: number | null;
  ocr_retailer_name: string | null;
  ocr_invoice_date: string | null;
  review_status: string;
  blocked_from_sage_yn: boolean;
  review_notes: string | null;
  mindee_job_id: string | null;
  mindee_inference_id: string | null;
  mindee_model_id: string | null;
  mindee_ocr_status: string | null;
  mindee_enqueued_at: string | null;
  mindee_result_saved_at: string | null;
  mindee_pages_consumed: number | null;
  mindee_error_message: string | null;
  orders: MaybeArray<{
    order_ref: string | null;
    order_total_gbp_declared: number | null;
    total_qty_declared: number | null;
    retailers: MaybeArray<{ name: string | null }>;
    importers: MaybeArray<{ company_name: string | null }>;
  }>;
  supplier_invoice_financial_summary: MaybeArray<{ invoice_total_gbp: number | null }>;
  supplier_invoice_review_flags: { flag_type: string; message: string; status: string }[] | null;
};

function first<T>(value: MaybeArray<T>): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}
function money(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}
function orderOf(invoice: InvoiceRow) { return first(invoice.orders); }
function orderRetailer(invoice: InvoiceRow) { return first(orderOf(invoice)?.retailers)?.name ?? "—"; }
function importer(invoice: InvoiceRow) { return first(orderOf(invoice)?.importers)?.company_name ?? "—"; }
function enteredTotal(invoice: InvoiceRow) { return first(invoice.supplier_invoice_financial_summary)?.invoice_total_gbp ?? null; }
function openFlags(invoice: InvoiceRow) { return (invoice.supplier_invoice_review_flags ?? []).filter((f) => ["open", "under_review"].includes(f.status)); }
function hasMindeeJob(invoice: InvoiceRow) { return Boolean(invoice.mindee_job_id || invoice.mindee_inference_id); }
function mindeeCompleted(invoice: InvoiceRow) { return invoice.mindee_ocr_status === "completed" || Boolean(invoice.mindee_result_saved_at); }
function canStartMindee(invoice: InvoiceRow) { return !hasMindeeJob(invoice) && !mindeeCompleted(invoice); }
function canFetchMindee(invoice: InvoiceRow) { return hasMindeeJob(invoice) && !mindeeCompleted(invoice); }

export default async function InternalInvoiceReviewPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const qp = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("id, full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data, error } = await supabase
    .from("supplier_invoices")
    .select(`id, order_id, invoice_ref, invoice_pdf_url, uploaded_at, ocr_invoice_ref, ocr_invoice_total_gbp, ocr_retailer_name, ocr_invoice_date, review_status, blocked_from_sage_yn, review_notes, mindee_job_id, mindee_inference_id, mindee_model_id, mindee_ocr_status, mindee_enqueued_at, mindee_result_saved_at, mindee_pages_consumed, mindee_error_message, orders(order_ref, order_total_gbp_declared, total_qty_declared, retailers(name), importers(company_name)), supplier_invoice_financial_summary(invoice_total_gbp), supplier_invoice_review_flags(flag_type, message, status)`)
    .in("review_status", ["pending_review", "duplicate_blocked"])
    .order("uploaded_at", { ascending: false })
    .limit(100);

  const invoices = (data ?? []) as unknown as InvoiceRow[];
  const readiness = new Map(await Promise.all(invoices.map(async (invoice) => [invoice.id, await assertInvoiceReadyForCurrentApproval(supabase, invoice.id)] as const)));
  const visible = invoices.filter((invoice) => Boolean(readiness.get(invoice.id)) || openFlags(invoice).length > 0 || hasMindeeJob(invoice));

  return (
    <main className="min-h-screen bg-slate-50 p-6 text-slate-950">
      <section className="rounded-2xl border bg-white p-5">
        <div className="flex flex-wrap justify-between gap-3">
          <Link href="/internal" className="text-sky-700 underline">← Back to internal dashboard</Link>
          <Link href="/internal/supplier-draft-ready" className="rounded bg-emerald-700 px-3 py-2 text-white">Open supplier draft ready →</Link>
        </div>
        <h1 className="mt-4 text-2xl font-semibold">Supplier invoice exceptions queue</h1>
        <p className="mt-2 text-sm text-slate-600">Order retailer is read only from the order-created retailer: orders.retailer_id → retailers.name. OCR retailer is shown separately and never used as the order retailer.</p>
        <p className="mt-2 text-sm">{staff.full_name} · {staff.role_type}</p>
        {qp.success ? <p className="mt-3 rounded border border-emerald-300 bg-emerald-50 p-2 text-sm">{qp.success}</p> : null}
        {qp.error ? <p className="mt-3 rounded border border-rose-300 bg-rose-50 p-2 text-sm">{qp.error}</p> : null}
      </section>

      {error ? <p className="mt-4 rounded border border-rose-300 bg-rose-50 p-3">{error.message}</p> : null}

      <section className="mt-4 grid gap-3 md:grid-cols-3">
        <div className="rounded border bg-white p-4">Needs supervisor attention: <strong>{visible.length}</strong></div>
        <div className="rounded border bg-white p-4">Clean / hidden: <strong>{invoices.length - visible.length}</strong></div>
        <div className="rounded border bg-white p-4">Loaded active invoices: <strong>{invoices.length}</strong></div>
      </section>

      <section className="mt-4 space-y-4">
        {visible.map((invoice) => {
          const order = orderOf(invoice);
          const retailerName = orderRetailer(invoice);
          const flags = openFlags(invoice);
          const block = readiness.get(invoice.id);
          const total = enteredTotal(invoice);
          return (
            <article key={invoice.id} className="rounded-2xl border bg-white p-5">
              <h2 className="text-xl font-semibold">{order?.order_ref ?? invoice.order_id}</h2>
              <p className="text-sm">{invoice.review_status}{invoice.blocked_from_sage_yn ? " · Blocked from Sage" : ""}</p>
              <p className="mt-2 text-sm">Importer: {importer(invoice)}</p>
              <p className="text-sm font-semibold">Order retailer: {retailerName}</p>
              <p className="text-sm">Order baseline: {money(order?.order_total_gbp_declared)} · Qty {order?.total_qty_declared ?? "—"}</p>
              <div className="mt-3 grid gap-2 md:grid-cols-4 text-sm">
                <div>Operator ref<br /><strong>{invoice.invoice_ref}</strong></div>
                <div>OCR ref<br /><strong>{invoice.ocr_invoice_ref ?? "—"}</strong></div>
                <div>OCR retailer / supplier<br /><strong>{invoice.ocr_retailer_name ?? "—"}</strong></div>
                <div>OCR date<br /><strong>{invoice.ocr_invoice_date ?? "—"}</strong></div>
                <div>Operator total<br /><strong>{total === null ? "—" : money(total)}</strong></div>
                <div>OCR total<br /><strong>{invoice.ocr_invoice_total_gbp === null ? "—" : money(invoice.ocr_invoice_total_gbp)}</strong></div>
                <div>Uploaded<br /><strong>{new Date(invoice.uploaded_at).toLocaleString("en-GB")}</strong></div>
                <div>Open flags<br /><strong>{flags.length}</strong></div>
              </div>

              <div className="mt-3 rounded border bg-slate-50 p-3 text-sm">
                <p className="font-semibold">Mindee OCR status</p>
                <p>Status: <strong>{invoice.mindee_ocr_status ?? "not_started"}</strong></p>
                <p>Job ID: <strong>{invoice.mindee_job_id ?? "—"}</strong></p>
                <p>Inference ID: <strong>{invoice.mindee_inference_id ?? "—"}</strong></p>
                <p>Pages reported: <strong>{invoice.mindee_pages_consumed ?? "—"}</strong></p>
                {invoice.mindee_error_message ? <p className="mt-1 rounded bg-rose-50 p-2">Mindee error: {invoice.mindee_error_message}</p> : null}
              </div>

              {flags.map((flag, index) => <p key={index} className="mt-2 rounded bg-amber-50 p-2 text-sm"><strong>{flag.flag_type}</strong>: {flag.message}</p>)}
              {block ? <p className="mt-3 rounded bg-amber-50 p-2 text-sm"><strong>Still blocked from draft queue:</strong> {block}</p> : <p className="mt-3 rounded bg-emerald-50 p-2 text-sm">Issue resolved. Use Supplier draft ready for bulk approval.</p>}
              <div className="mt-4 flex flex-wrap gap-2">
                <Link href={`/internal/evidence/${invoice.order_id}`} className="rounded border px-3 py-2 text-sm">Open staff order detail</Link>
                <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded bg-slate-900 px-3 py-2 text-sm text-white">Open invoice</a>
                {canStartMindee(invoice) ? <form action={runMindeeOcrForSupplierInvoiceAction}><input type="hidden" name="supplier_invoice_id" value={invoice.id} /><button className="rounded border border-amber-400 bg-amber-50 px-3 py-2 text-sm">Send this invoice to Mindee OCR — uses page credit</button></form> : null}
                {canFetchMindee(invoice) ? <form action={fetchAndSaveMindeeOcrResultAction}><input type="hidden" name="supplier_invoice_id" value={invoice.id} /><button className="rounded border border-emerald-600 bg-emerald-50 px-3 py-2 text-sm">Fetch/save Mindee result — no new page</button></form> : null}
              </div>
              <div className="mt-4 grid gap-4 lg:grid-cols-2">
                <form action={saveSupplierInvoiceHeaderReviewAction} className="rounded border bg-sky-50 p-4">
                  <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                  <h3 className="font-semibold">Save header correction / resolve issue</h3>
                  <input name="corrected_invoice_ref" className="mt-2 w-full border p-2" defaultValue={invoice.ocr_invoice_ref ?? invoice.invoice_ref} placeholder="Accepted invoice ref" />
                  <input name="ocr_invoice_ref" className="mt-2 w-full border p-2" defaultValue={invoice.ocr_invoice_ref ?? ""} placeholder="OCR invoice ref" />
                  <input name="ocr_retailer_name" className="mt-2 w-full border p-2" defaultValue={invoice.ocr_retailer_name ?? ""} placeholder="OCR retailer / supplier name" />
                  <input name="ocr_invoice_date" type="date" className="mt-2 w-full border p-2" defaultValue={invoice.ocr_invoice_date ?? ""} />
                  <input name="ocr_invoice_total_gbp" type="number" min="0" step="0.01" className="mt-2 w-full border p-2" defaultValue={invoice.ocr_invoice_total_gbp ?? total ?? ""} placeholder="Accepted/OCR invoice total GBP" />
                  <input name="review_notes" className="mt-2 w-full border p-2" placeholder="Review note / correction reason" />
                  <button className="mt-2 rounded bg-sky-700 px-3 py-2 text-white">Save correction</button>
                </form>
                <form action={rejectSupplierInvoiceRequireResubmissionAction} className="rounded border bg-rose-50 p-4">
                  <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                  <h3 className="font-semibold">Reject / require resubmission</h3>
                  <input name="review_notes" className="mt-2 w-full border p-2" placeholder="Reason for resubmission" />
                  <button className="mt-2 rounded border bg-white px-3 py-2">Reject</button>
                </form>
              </div>
              {invoice.review_notes ? <p className="mt-3 rounded bg-slate-50 p-2 text-sm">Previous notes: {invoice.review_notes}</p> : null}
            </article>
          );
        })}
      </section>
    </main>
  );
}
