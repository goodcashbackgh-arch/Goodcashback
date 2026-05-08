import Link from "next/link";
import { notFound } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import { saveRetailerUpdateAction } from "./actions";
import RefundEvidenceModeSelector, { type RefundDocumentHistoryRow } from "./RefundEvidenceModeSelector";

type SearchParams = {
  success?: string;
  error?: string;
};

type SupplierInvoiceOption = {
  id: string;
  invoice_ref: string | null;
  review_status?: string | null;
};

type CourierOption = {
  id: string;
  name: string;
};

type PrefillLine = {
  description: string;
  qty: number;
  amount: number;
};

type MessageRow = {
  id: string;
  message_type: string | null;
  body: string | null;
  generated_by: string | null;
  created_at: string | null;
};

type ReturnTrackingRow = {
  id: string;
  courier_id: string | null;
  couriers?: { name?: string | null } | { name?: string | null }[] | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  tracking_evidence_url: string | null;
  retailer_return_instructions_file_url: string | null;
  return_label_file_url: string | null;
  return_proof_file_url: string | null;
  submitted_at: string | null;
  is_final_return_yn: boolean | null;
  review_status: string | null;
  note: string | null;
};

type SourceLine = {
  line_order: number | string | null;
  line_source: string | null;
  description: string | null;
};

type DisputeLine = {
  id: string;
  qty_impact: number | string | null;
  amount_impact_gbp: number | string | null;
  conversation_status: string | null;
  supplier_invoice_lines: SourceLine | SourceLine[] | null;
};

const FINAL_OUTCOME_STATUSES = new Set(["approved_replacement", "replaced", "awaiting_refund_credit", "refunded", "closed"]);

function gbp(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function retailerOutcomeFromStatus(status: string | null | undefined) {
  switch (status) {
    case "retailer_response_received":
      return "retailer_accepted";
    case "awaiting_retailer_resolution":
      return "retailer_disputed";
    case "retailer_draft_ready":
      return "more_info_requested";
    case "retailer_contacted":
    default:
      return "still_waiting";
  }
}

function finalOutcomeMessage(dispute: { desired_outcome: string | null; status: string | null; replacement_child_order_id?: string | null }) {
  if (dispute.desired_outcome === "replacement" && dispute.status === "replaced") return "Replacement accepted — child order created";
  if (dispute.desired_outcome === "refund" && dispute.status === "awaiting_refund_credit") return "Refund accepted — awaiting refund credit processing";
  if (dispute.status === "refunded") return "Refund processed — awaiting closure.";
  if (dispute.status === "closed") return "Exception closed.";
  return "Final outcome accepted.";
}

function normaliseAbsNumber(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? Math.abs(parsed) : 0;
}

function friendlyStatus(status: string | null | undefined) {
  if (!status) return "Pending review";
  return status.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function returnTrackingBody(row: ReturnTrackingRow) {
  const courier = Array.isArray(row.couriers) ? row.couriers[0] : row.couriers;
  const lines = [
    `Courier: ${courier?.name ?? row.courier_id ?? "Not provided"}`,
    `Tracking reference: ${row.tracking_ref ?? "Not provided"}`,
    `Tracking date: ${row.tracking_date ?? "Not provided"}`,
    `Tracking / evidence link: ${row.tracking_evidence_url ?? "Not provided"}`,
    `Final return / collection: ${row.is_final_return_yn ? "Yes" : "No"}`,
    `Supervisor review: ${friendlyStatus(row.review_status)}`,
  ];

  if (row.retailer_return_instructions_file_url) lines.push(`Retailer instructions file: ${row.retailer_return_instructions_file_url}`);
  if (row.return_label_file_url) lines.push(`Return label file: ${row.return_label_file_url}`);
  if (row.return_proof_file_url) lines.push(`Return proof file: ${row.return_proof_file_url}`);

  lines.push(`Note: ${row.note || "No note."}`);
  return lines.join("\n");
}

function firstSourceLine(value: SourceLine | SourceLine[] | null | undefined) {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

export default async function ImporterExceptionDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ dispute_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { dispute_id: disputeId } = await params;
  const query = (await searchParams) ?? {};
  const supabase = await createClient();

  const { data: dispute, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, refund_approved_at, replacement_child_order_id")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) notFound();

  const [
    { data: order },
    { data: linesRaw },
    { data: messagesRaw },
    { data: supplierInvoicesRaw },
    { data: couriersRaw },
    { data: returnTrackingRowsRaw },
    { data: refundEvidenceRowsRaw },
  ] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, total_qty_declared, order_total_gbp_declared")
      .eq("id", dispute.order_id)
      .maybeSingle(),
    supabase
      .from("dispute_lines")
      .select("id, qty_impact, amount_impact_gbp, conversation_status, supplier_invoice_lines!inner(id, line_order, line_source, description)")
      .eq("dispute_id", disputeId)
      .order("created_at", { ascending: true }),
    supabase
      .from("dispute_messages")
      .select("id, message_type, counterparty, body, generated_by, created_at")
      .eq("dispute_id", disputeId)
      .order("created_at", { ascending: true }),
    supabase
      .from("supplier_invoices")
      .select("id, invoice_ref, review_status, uploaded_at")
      .eq("order_id", dispute.order_id)
      .order("uploaded_at", { ascending: false }),
    supabase
      .from("couriers")
      .select("id, name")
      .order("name", { ascending: true }),
    supabase
      .from("dispute_return_tracking_submissions")
      .select("id, courier_id, tracking_ref, tracking_date, tracking_evidence_url, retailer_return_instructions_file_url, return_label_file_url, return_proof_file_url, submitted_at, is_final_return_yn, review_status, note, couriers(name)")
      .eq("dispute_id", disputeId)
      .order("submitted_at", { ascending: false }),
    supabase
      .from("dispute_refund_evidence_submissions")
      .select("id, document_mode, credit_note_ref, credit_note_date, expected_credit_note_total_gbp, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, variance_abs_gbp, credit_note_file_url, refund_proof_file_url, ocr_status, match_status, amount_balance_status, supplier_control_status, supplier_approval_status, supervisor_review_status, notes, submitted_at")
      .eq("dispute_id", disputeId)
      .order("submitted_at", { ascending: false }),
  ]);

  const lines = (linesRaw ?? []) as DisputeLine[];
  const messages = (messagesRaw ?? []) as MessageRow[];
  const invoiceOptions = (supplierInvoicesRaw ?? []) as SupplierInvoiceOption[];
  const courierOptions = (couriersRaw ?? []) as CourierOption[];
  const refundDocumentHistory = (refundEvidenceRowsRaw ?? []) as RefundDocumentHistoryRow[];

  const activeStatus = lines.find((line) => line.conversation_status)?.conversation_status ?? "retailer_contacted";
  const retailerOutcome = retailerOutcomeFromStatus(activeStatus);
  const isFinalOutcome = FINAL_OUTCOME_STATUSES.has(dispute.status ?? "");
  const isTerminalAcceptedState = dispute.status === "replaced" || dispute.status === "awaiting_refund_credit";
  const canUploadRefundEvidence = dispute.desired_outcome === "refund" && dispute.status === "awaiting_refund_credit";
  const legacyRefundEvidenceExists = messages.some((message) => ["credit_note_evidence", "refund_evidence"].includes(message.message_type ?? ""));
  const hasRefundEvidence = refundDocumentHistory.length > 0 || legacyRefundEvidenceExists;

  const messageReturnHistory = messages.filter((message) =>
    ["return_collection_evidence", "return_collection_evidence_review"].includes(message.message_type ?? "")
  );
  const structuredReturnHistory = ((returnTrackingRowsRaw ?? []) as ReturnTrackingRow[]).map((row) => ({
    id: row.id,
    message_type: "return_collection_evidence",
    body: returnTrackingBody(row),
    generated_by: friendlyStatus(row.review_status),
    created_at: row.submitted_at,
  }));
  const returnHistory = [...structuredReturnHistory, ...messageReturnHistory];

  const prefillLines: PrefillLine[] = lines.slice(0, 5).map((line) => {
    const sourceLine = firstSourceLine(line.supplier_invoice_lines);
    return {
      description: sourceLine?.description ?? "Refund line",
      qty: normaliseAbsNumber(line.qty_impact),
      amount: normaliseAbsNumber(line.amount_impact_gbp),
    };
  });

  while (prefillLines.length < 5) prefillLines.push({ description: "", qty: 0, amount: 0 });

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl space-y-6">
        <FlashQueryParamCleaner />

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/importer/reconciliation/${dispute.order_id}`} className="text-sm font-semibold text-sky-600">← Back to reconciliation</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Importer exception workflow</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Dispute {dispute.id}</h1>
          <p className="mt-2 text-sm text-slate-600">Parent order {order?.order_ref ?? dispute.order_id} · Outcome {dispute.desired_outcome} · Status {dispute.status}</p>
          <div className="mt-4 grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Declared qty</p><p className="mt-1 font-semibold">{order?.total_qty_declared ?? "—"}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Declared value</p><p className="mt-1 font-semibold">{gbp(order?.order_total_gbp_declared)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Dispute amount</p><p className="mt-1 font-semibold">{gbp(dispute.amount_impact_gbp)}</p></div>
            {dispute.desired_outcome === "refund" ? (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Refund approval</p><p className="mt-1 font-semibold">{dispute.refund_approved_at ? "Pursuit approved" : "Pending staff approval"}</p></div>
            ) : (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Dispute type</p><p className="mt-1 font-semibold">Replacement</p></div>
            )}
          </div>
          {query.success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">{query.success}</p> : null}
          {query.error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">{query.error}</p> : null}
          {isFinalOutcome ? (
            <div className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
              <p className="font-semibold">{finalOutcomeMessage(dispute)}</p>
              {dispute.replacement_child_order_id ? <p className="mt-1">Replacement child order: {dispute.replacement_child_order_id}</p> : null}
              {hasRefundEvidence ? <p className="mt-1">Refund document evidence has been submitted and is visible below.</p> : null}
            </div>
          ) : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Affected lines</h2>
          <div className="mt-4 space-y-2">
            {lines.map((line) => {
              const sourceLine = firstSourceLine(line.supplier_invoice_lines);
              return (
                <article key={line.id} className="rounded-2xl border border-amber-300 bg-amber-50 p-3 text-sm">
                  <p className="font-semibold">Line {sourceLine?.line_order ?? "—"} · {sourceLine?.line_source ?? "—"}</p>
                  <p>{sourceLine?.description ?? "No description"}</p>
                  <p>Qty impact {line.qty_impact} · Amount impact {gbp(line.amount_impact_gbp)}</p>
                </article>
              );
            })}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Retailer update</h2>
          <p className="mt-2 text-sm text-slate-600">Paste the retailer response first. If the retailer accepts the refund/replacement, mark the outcome as accepted so the supervisor can accept the final outcome.</p>
          {!isTerminalAcceptedState ? <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Current retailer outcome:</span> {retailerOutcome.replaceAll("_", " ")}</p> : null}
          {isTerminalAcceptedState ? <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Active terminal state:</span> {finalOutcomeMessage(dispute)}</p> : null}
          {isFinalOutcome ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">Retailer update is locked because the supervisor has accepted the final outcome.</p>
          ) : (
            <form action={saveRetailerUpdateAction} className="mt-4 space-y-3">
              <input type="hidden" name="dispute_id" value={dispute.id} />
              <label className="block space-y-1">
                <span className="text-sm font-medium text-slate-700">Retailer response</span>
                <textarea name="retailer_response" rows={5} className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
              </label>
              <label className="block space-y-1">
                <span className="text-sm font-medium text-slate-700">Retailer outcome</span>
                <select name="retailer_outcome" defaultValue={retailerOutcome} className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm">
                  <option value="still_waiting">Still waiting</option>
                  <option value="retailer_accepted">Retailer accepted refund / remedy</option>
                  <option value="retailer_disputed">Retailer disputed / rejected</option>
                  <option value="more_info_requested">More information requested</option>
                </select>
              </label>
              <button type="submit" className="rounded-xl bg-sky-700 px-4 py-2 text-sm font-semibold text-white">Save retailer update</button>
            </form>
          )}
        </section>

        {dispute.desired_outcome === "refund" ? (
          <section className="rounded-3xl border border-amber-200 bg-white p-6 shadow-sm">
            <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <p className="text-sm font-medium uppercase tracking-[0.2em] text-amber-600">Refund evidence after supervisor acceptance</p>
                <h2 className="mt-2 text-xl font-semibold">Return tracking and refund document evidence</h2>
                <p className="mt-2 max-w-3xl text-sm text-slate-600">Return/collection evidence is operational. Credit-note/refund/no-document evidence feeds the supplier credit/refund document control lane.</p>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${canUploadRefundEvidence ? "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200" : "bg-amber-50 text-amber-800 ring-1 ring-amber-200"}`}>
                {canUploadRefundEvidence ? "Evidence upload enabled" : "Waiting for final refund acceptance"}
              </span>
            </div>
            {canUploadRefundEvidence ? (
              <RefundEvidenceModeSelector
                disputeId={dispute.id}
                originalOrderId={dispute.order_id}
                invoiceOptions={invoiceOptions}
                courierOptions={courierOptions}
                prefillLines={prefillLines}
                returnHistory={returnHistory}
                refundDocumentHistory={refundDocumentHistory}
              />
            ) : (
              <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">Supervisor must accept the final refund outcome before return tracking or refund document evidence can be submitted here.</p>
            )}
          </section>
        ) : null}
      </div>
    </main>
  );
}
