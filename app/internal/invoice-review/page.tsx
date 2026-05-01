import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { fetchAndSaveMindeeOcrResultAction, rejectSupplierInvoiceRequireResubmissionAction, runMindeeOcrForSupplierInvoiceAction, saveSupplierInvoiceHeaderReviewAction } from "./actions";
import { assertInvoiceReadyForCurrentApproval } from "./readiness";

const MINDEE_RESULT_FETCH_RELEASE_MARKER = "mindee-result-fetch-v2";
const BRAND_COLOUR = "#20c1fc";

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

type MatchDecisionRow = {
  supplier_invoice_id: string;
  routing_decision: string;
  routing_reason: string | null;
  retailer_match_yn: boolean | null;
  invoice_ref_match_yn: boolean | null;
  total_match_yn: boolean | null;
  ocr_line_count: number | null;
  pending_adjustment_yn: boolean | null;
  supplier_approval_blocked_yn: boolean | null;
  supplier_approval_block_reason: string | null;
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
function yesNo(value: boolean | null | undefined) { return value ? "Yes" : "No"; }
function decisionLabel(decision: string | undefined) {
  if (!decision) return "decision unavailable";
  return decision.replaceAll("_", " ");
}
function shouldShowInInvoiceReview(invoice: InvoiceRow, decision: MatchDecisionRow | undefined) {
  if (!decision) {
    // Safe fallback while the DB view is not installed yet.
    return hasMindeeJob(invoice) || openFlags(invoice).length > 0;
  }
  if (["needs_invoice_review", "ocr_pending"].includes(decision.routing_decision)) return true;
  if (canFetchMindee(invoice)) return true;
  return false;
}
function reviewStatusTone(status: string) {
  if (status === "duplicate_blocked") return "border-rose-200 bg-rose-50 text-rose-700";
  if (status === "pending_review") return "border-amber-200 bg-amber-50 text-amber-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}
function matchTone(value: boolean | null | undefined) {
  if (value === true) return "border-emerald-200 bg-emerald-50 text-emerald-700";
  if (value === false) return "border-rose-200 bg-rose-50 text-rose-700";
  return "border-slate-200 bg-slate-50 text-slate-500";
}
function mindeeTone(status: string | null) {
  if (status === "completed") return "border-emerald-200 bg-emerald-50 text-emerald-700";
  if (status === "failed") return "border-rose-200 bg-rose-50 text-rose-700";
  if (status) return "border-sky-200 bg-sky-50 text-sky-700";
  return "border-slate-200 bg-slate-50 text-slate-600";
}

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
  const invoiceIds = invoices.map((invoice) => invoice.id);
  const { data: matchData, error: matchError } = invoiceIds.length > 0
    ? await supabase
        .from("supplier_invoice_match_decision_vw")
        .select("supplier_invoice_id, routing_decision, routing_reason, retailer_match_yn, invoice_ref_match_yn, total_match_yn, ocr_line_count, pending_adjustment_yn, supplier_approval_blocked_yn, supplier_approval_block_reason")
        .in("supplier_invoice_id", invoiceIds)
    : { data: [] as MatchDecisionRow[], error: null };

  const matchByInvoiceId = new Map<string, MatchDecisionRow>();
  for (const row of (matchData ?? []) as MatchDecisionRow[]) {
    matchByInvoiceId.set(row.supplier_invoice_id, row);
  }

  const readiness = new Map(await Promise.all(invoices.map(async (invoice) => [invoice.id, await assertInvoiceReadyForCurrentApproval(supabase, invoice.id)] as const)));
  const visible = invoices.filter((invoice) => shouldShowInInvoiceReview(invoice, matchByInvoiceId.get(invoice.id)));

  return (
    <main
      className="min-h-screen bg-white px-4 py-6 text-slate-950 sm:px-6 lg:px-8"
      data-release-marker={MINDEE_RESULT_FETCH_RELEASE_MARKER}
      style={{ backgroundImage: "radial-gradient(circle at top left, rgba(32, 193, 252, 0.14), transparent 34rem)" }}
    >
      <div className="mx-auto max-w-7xl">
        <section className="overflow-hidden rounded-[2rem] border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 bg-slate-950 px-5 py-4 text-white sm:px-7">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <Link href="/internal" className="text-sm font-medium text-white/80 transition hover:text-white">← Back to internal dashboard</Link>
              <div className="flex flex-wrap gap-2">
                <span className="rounded-full border border-white/15 bg-white/10 px-3 py-1 text-xs font-semibold text-white/80">{staff.full_name} · {staff.role_type}</span>
                <Link href="/internal/supplier-draft-ready" className="rounded-full px-4 py-2 text-sm font-semibold text-slate-950 shadow-sm transition hover:opacity-90" style={{ backgroundColor: BRAND_COLOUR }}>
                  Open supplier draft ready →
                </Link>
              </div>
            </div>
          </div>

          <div className="grid gap-6 p-5 sm:p-7 lg:grid-cols-[1.35fr_0.65fr] lg:items-end">
            <div>
              <div className="mb-4 inline-flex items-center gap-2 rounded-full border border-sky-100 bg-sky-50 px-3 py-1 text-xs font-semibold uppercase tracking-[0.2em] text-sky-700">
                <span className="h-2 w-2 rounded-full" style={{ backgroundColor: BRAND_COLOUR }} />
                OCR control room
              </div>
              <h1 className="max-w-3xl text-3xl font-semibold tracking-tight text-slate-950 sm:text-4xl">Supplier invoice exceptions queue</h1>
              <p className="mt-3 max-w-2xl text-sm leading-6 text-slate-600">
                Review OCR/header exceptions only. Full matches should route out to operator reconciliation, so this page stays focused on genuine intervention work.
              </p>
            </div>

            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Queue discipline</p>
              <p className="mt-2 text-sm leading-6 text-slate-700">
                Do not use this screen as a general invoice list. It exists to clear OCR pending items, header mismatches, duplicate blocks, and review flags.
              </p>
            </div>
          </div>

          {(qp.success || qp.error || matchError) ? (
            <div className="space-y-3 border-t border-slate-100 px-5 py-4 sm:px-7">
              {qp.success ? <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-medium text-emerald-800">{qp.success}</p> : null}
              {qp.error ? <p className="rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-medium text-rose-800">{qp.error}</p> : null}
              {matchError ? <p className="rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-medium text-amber-800">Match decision view not available yet: run docs/governing-pack/backend/supplier_invoice_match_decision_v1.sql. Fallback filtering is active.</p> : null}
            </div>
          ) : null}
        </section>

        {error ? <p className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-medium text-rose-800">{error.message}</p> : null}

        <section className="mt-5 grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Needs action</p>
            <p className="mt-3 text-3xl font-semibold text-slate-950">{visible.length}</p>
            <p className="mt-1 text-sm text-slate-500">Review / OCR pending</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Routed away</p>
            <p className="mt-3 text-3xl font-semibold text-slate-950">{invoices.length - visible.length}</p>
            <p className="mt-1 text-sm text-slate-500">Matched or no longer relevant</p>
          </div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Loaded</p>
            <p className="mt-3 text-3xl font-semibold text-slate-950">{invoices.length}</p>
            <p className="mt-1 text-sm text-slate-500">Active invoice records</p>
          </div>
        </section>

        <section className="mt-5 space-y-5">
          {visible.length === 0 ? (
            <div className="rounded-[2rem] border border-dashed border-slate-300 bg-white p-10 text-center shadow-sm">
              <p className="text-lg font-semibold text-slate-950">No invoice exceptions need review.</p>
              <p className="mt-2 text-sm text-slate-500">That is the target state. New OCR/header mismatches will appear here when they need supervisor attention.</p>
            </div>
          ) : null}

          {visible.map((invoice) => {
            const order = orderOf(invoice);
            const retailerName = orderRetailer(invoice);
            const flags = openFlags(invoice);
            const block = readiness.get(invoice.id);
            const total = enteredTotal(invoice);
            const match = matchByInvoiceId.get(invoice.id);
            return (
              <article key={invoice.id} className="overflow-hidden rounded-[2rem] border border-slate-200 bg-white shadow-sm">
                <div className="border-b border-slate-100 px-5 py-5 sm:px-7">
                  <div className="flex flex-wrap items-start justify-between gap-4">
                    <div>
                      <div className="flex flex-wrap items-center gap-2">
                        <span className={`rounded-full border px-3 py-1 text-xs font-semibold ${reviewStatusTone(invoice.review_status)}`}>{invoice.review_status}</span>
                        {invoice.blocked_from_sage_yn ? <span className="rounded-full border border-rose-200 bg-rose-50 px-3 py-1 text-xs font-semibold text-rose-700">Blocked from Sage</span> : null}
                        <span className={`rounded-full border px-3 py-1 text-xs font-semibold ${mindeeTone(invoice.mindee_ocr_status)}`}>Mindee: {invoice.mindee_ocr_status ?? "not started"}</span>
                      </div>
                      <h2 className="mt-3 text-2xl font-semibold tracking-tight text-slate-950">{order?.order_ref ?? invoice.order_id}</h2>
                      <p className="mt-1 text-sm text-slate-500">Uploaded {new Date(invoice.uploaded_at).toLocaleString("en-GB")}</p>
                    </div>
                    <div className="flex flex-wrap gap-2">
                      <Link href={`/internal/evidence/${invoice.order_id}`} className="rounded-full border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 transition hover:border-slate-300 hover:bg-slate-50">Staff detail</Link>
                      <Link href={`/importer/reconciliation/${invoice.order_id}`} className="rounded-full border border-sky-200 bg-sky-50 px-4 py-2 text-sm font-semibold text-sky-700 transition hover:bg-sky-100">Operator reconciliation</Link>
                      <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-full bg-slate-950 px-4 py-2 text-sm font-semibold text-white transition hover:bg-slate-800">Open invoice</a>
                    </div>
                  </div>
                </div>

                <div className="grid gap-0 lg:grid-cols-[1.45fr_0.55fr]">
                  <div className="space-y-5 p-5 sm:p-7">
                    <div className="grid gap-4 md:grid-cols-3">
                      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">Importer</p>
                        <p className="mt-2 text-sm font-semibold text-slate-950">{importer(invoice)}</p>
                      </div>
                      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">Expected retailer</p>
                        <p className="mt-2 text-sm font-semibold text-slate-950">{retailerName}</p>
                      </div>
                      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                        <p className="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">Order baseline</p>
                        <p className="mt-2 text-sm font-semibold text-slate-950">{money(order?.order_total_gbp_declared)} · Qty {order?.total_qty_declared ?? "—"}</p>
                      </div>
                    </div>

                    <div className="rounded-3xl border border-slate-200 bg-white p-5">
                      <div className="flex flex-wrap items-center justify-between gap-3">
                        <div>
                          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Header comparison</p>
                          <h3 className="mt-1 text-lg font-semibold text-slate-950">Operator submission vs OCR extraction</h3>
                        </div>
                        <span className="rounded-full px-3 py-1 text-xs font-semibold text-slate-950" style={{ backgroundColor: "rgba(32, 193, 252, 0.16)" }}>{flags.length} open flags</span>
                      </div>

                      <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">Operator ref</p>
                          <p className="mt-1 break-words text-sm font-semibold text-slate-950">{invoice.invoice_ref}</p>
                        </div>
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">OCR ref</p>
                          <p className="mt-1 break-words text-sm font-semibold text-slate-950">{invoice.ocr_invoice_ref ?? "—"}</p>
                        </div>
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">OCR retailer / supplier</p>
                          <p className="mt-1 break-words text-sm font-semibold text-slate-950">{invoice.ocr_retailer_name ?? "—"}</p>
                        </div>
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">OCR date</p>
                          <p className="mt-1 text-sm font-semibold text-slate-950">{invoice.ocr_invoice_date ?? "—"}</p>
                        </div>
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">Operator total</p>
                          <p className="mt-1 text-sm font-semibold text-slate-950">{total === null ? "—" : money(total)}</p>
                        </div>
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">OCR total</p>
                          <p className="mt-1 text-sm font-semibold text-slate-950">{invoice.ocr_invoice_total_gbp === null ? "—" : money(invoice.ocr_invoice_total_gbp)}</p>
                        </div>
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">Pages reported</p>
                          <p className="mt-1 text-sm font-semibold text-slate-950">{invoice.mindee_pages_consumed ?? "—"}</p>
                        </div>
                        <div className="rounded-2xl border border-slate-200 p-4">
                          <p className="text-xs font-medium text-slate-500">OCR line count</p>
                          <p className="mt-1 text-sm font-semibold text-slate-950">{match?.ocr_line_count ?? "—"}</p>
                        </div>
                      </div>
                    </div>

                    <div className="rounded-3xl border border-slate-200 bg-slate-950 p-5 text-white">
                      <div className="flex flex-wrap items-start justify-between gap-3">
                        <div>
                          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-white/50">Matching / routing decision</p>
                          <p className="mt-2 text-xl font-semibold capitalize">{decisionLabel(match?.routing_decision)}</p>
                          <p className="mt-1 text-sm leading-6 text-white/70">{match?.routing_reason ?? "Decision view unavailable."}</p>
                        </div>
                        <div className="h-10 w-10 rounded-2xl" style={{ backgroundColor: BRAND_COLOUR }} />
                      </div>

                      <div className="mt-5 grid gap-3 md:grid-cols-3">
                        <div className={`rounded-2xl border px-4 py-3 text-sm font-semibold ${matchTone(match?.retailer_match_yn)}`}>Retailer match: {yesNo(match?.retailer_match_yn)}</div>
                        <div className={`rounded-2xl border px-4 py-3 text-sm font-semibold ${matchTone(match?.invoice_ref_match_yn)}`}>Ref match: {yesNo(match?.invoice_ref_match_yn)}</div>
                        <div className={`rounded-2xl border px-4 py-3 text-sm font-semibold ${matchTone(match?.total_match_yn)}`}>Total match: {yesNo(match?.total_match_yn)}</div>
                      </div>

                      {match?.pending_adjustment_yn ? <p className="mt-4 rounded-2xl border border-amber-300/40 bg-amber-300/10 p-3 text-sm text-amber-100">Delivery/discount approval is pending. This blocks supplier approval/Sage readiness, not operator line reconciliation.</p> : null}
                    </div>

                    <div className="grid gap-4 lg:grid-cols-2">
                      <form action={saveSupplierInvoiceHeaderReviewAction} className="rounded-3xl border border-slate-200 bg-slate-50 p-5">
                        <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                        <h3 className="text-lg font-semibold text-slate-950">Save header correction</h3>
                        <p className="mt-1 text-sm text-slate-500">Use this only to resolve OCR/header issues. It does not replace operator line reconciliation.</p>
                        <input name="corrected_invoice_ref" className="mt-4 w-full rounded-2xl border border-slate-200 bg-white p-3 text-sm outline-none transition focus:border-sky-300" defaultValue={invoice.ocr_invoice_ref ?? invoice.invoice_ref} placeholder="Accepted invoice ref" />
                        <input name="ocr_invoice_ref" className="mt-3 w-full rounded-2xl border border-slate-200 bg-white p-3 text-sm outline-none transition focus:border-sky-300" defaultValue={invoice.ocr_invoice_ref ?? ""} placeholder="OCR invoice ref" />
                        <input name="ocr_retailer_name" className="mt-3 w-full rounded-2xl border border-slate-200 bg-white p-3 text-sm outline-none transition focus:border-sky-300" defaultValue={invoice.ocr_retailer_name ?? ""} placeholder="OCR retailer / supplier name" />
                        <input name="ocr_invoice_date" type="date" className="mt-3 w-full rounded-2xl border border-slate-200 bg-white p-3 text-sm outline-none transition focus:border-sky-300" defaultValue={invoice.ocr_invoice_date ?? ""} />
                        <input name="ocr_invoice_total_gbp" type="number" min="0" step="0.01" className="mt-3 w-full rounded-2xl border border-slate-200 bg-white p-3 text-sm outline-none transition focus:border-sky-300" defaultValue={invoice.ocr_invoice_total_gbp ?? total ?? ""} placeholder="Accepted/OCR invoice total GBP" />
                        <input name="review_notes" className="mt-3 w-full rounded-2xl border border-slate-200 bg-white p-3 text-sm outline-none transition focus:border-sky-300" placeholder="Review note / correction reason" />
                        <button className="mt-4 rounded-full px-5 py-3 text-sm font-semibold text-slate-950 shadow-sm transition hover:opacity-90" style={{ backgroundColor: BRAND_COLOUR }}>Save correction</button>
                      </form>

                      <form action={rejectSupplierInvoiceRequireResubmissionAction} className="rounded-3xl border border-rose-200 bg-rose-50 p-5">
                        <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                        <h3 className="text-lg font-semibold text-rose-950">Reject / require resubmission</h3>
                        <p className="mt-1 text-sm text-rose-700">Use this when the uploaded document cannot safely support the invoice record.</p>
                        <input name="review_notes" className="mt-4 w-full rounded-2xl border border-rose-200 bg-white p-3 text-sm outline-none transition focus:border-rose-300" placeholder="Reason for resubmission" />
                        <button className="mt-4 rounded-full border border-rose-200 bg-white px-5 py-3 text-sm font-semibold text-rose-700 transition hover:bg-rose-100">Reject</button>
                      </form>
                    </div>
                  </div>

                  <aside className="border-t border-slate-100 bg-slate-50 p-5 sm:p-7 lg:border-l lg:border-t-0">
                    <div className="sticky top-6 space-y-4">
                      <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Mindee OCR status</p>
                        <p className="mt-3 text-lg font-semibold text-slate-950">{invoice.mindee_ocr_status ?? "not_started"}</p>
                        <dl className="mt-4 space-y-3 text-sm">
                          <div>
                            <dt className="text-slate-500">Job ID</dt>
                            <dd className="mt-1 break-words font-medium text-slate-950">{invoice.mindee_job_id ?? "—"}</dd>
                          </div>
                          <div>
                            <dt className="text-slate-500">Inference ID</dt>
                            <dd className="mt-1 break-words font-medium text-slate-950">{invoice.mindee_inference_id ?? "—"}</dd>
                          </div>
                        </dl>
                        {invoice.mindee_error_message ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">Mindee error: {invoice.mindee_error_message}</p> : null}
                        <div className="mt-4 space-y-2">
                          {canStartMindee(invoice) ? <form action={runMindeeOcrForSupplierInvoiceAction}><input type="hidden" name="supplier_invoice_id" value={invoice.id} /><button className="w-full rounded-full border border-amber-200 bg-amber-50 px-4 py-3 text-sm font-semibold text-amber-800 transition hover:bg-amber-100">Send to Mindee OCR — uses page credit</button></form> : null}
                          {canFetchMindee(invoice) ? <form action={fetchAndSaveMindeeOcrResultAction}><input type="hidden" name="supplier_invoice_id" value={invoice.id} /><button className="w-full rounded-full border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-800 transition hover:bg-emerald-100">Fetch/save Mindee result — no new page</button></form> : null}
                        </div>
                      </div>

                      <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">Approval gate</p>
                        {block ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800"><strong>Supplier approval/Sage still blocked:</strong> {block}</p> : <p className="mt-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">Supplier approval gate looks clear. Use Supplier draft ready for bulk approval after reconciliation is complete.</p>}
                      </div>

                      {flags.length > 0 ? (
                        <div className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm">
                          <p className="text-xs font-semibold uppercase tracking-[0.18em] text-amber-700">Open review flags</p>
                          <div className="mt-3 space-y-2">
                            {flags.map((flag, index) => <p key={index} className="rounded-2xl bg-white p-3 text-sm text-amber-900"><strong>{flag.flag_type}</strong>: {flag.message}</p>)}
                          </div>
                        </div>
                      ) : null}

                      {invoice.review_notes ? <p className="rounded-3xl border border-slate-200 bg-white p-5 text-sm text-slate-600 shadow-sm"><strong className="text-slate-950">Previous notes:</strong> {invoice.review_notes}</p> : null}
                    </div>
                  </aside>
                </div>
              </article>
            );
          })}
        </section>
      </div>
    </main>
  );
}
