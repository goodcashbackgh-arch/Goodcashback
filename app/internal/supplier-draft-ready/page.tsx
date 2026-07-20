import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  assertInvoiceReadyForCurrentApproval,
  assertSupplierInvoiceAccountingCodingReady,
} from "../invoice-review/readiness";
import {
  approveSupplierInvoiceCurrentAction,
  approveSupplierRefundEvidenceCurrentAction,
  bulkApproveSupplierInvoicesCurrentAction,
} from "./actions";

type SearchParams = { success?: string; error?: string; status?: string };

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

type RefundEvidenceMessage = {
  id: string;
  dispute_id: string;
  message_type: string | null;
  body: string | null;
  created_at: string | null;
  generated_by: string | null;
};

type RefundSubmission = {
  id: string;
  dispute_id: string;
  document_mode: string | null;
  credit_note_ref: string | null;
  credit_note_date: string | null;
  expected_credit_note_total_gbp: number | null;
  captured_refund_amount_abs_gbp: number | null;
  expected_exception_amount_abs_gbp: number | null;
  amount_balance_status: string | null;
  evidence_control_status: string | null;
  supplier_readiness_route: string | null;
  supplier_approval_status: string | null;
  supervisor_review_status: string | null;
  ocr_status: string | null;
  match_status: string | null;
  supplier_control_status: string | null;
  ocr_credit_note_ref: string | null;
  ocr_retailer_name: string | null;
  ocr_credit_note_date: string | null;
  ocr_credit_note_total_gbp: number | null;
  credit_note_file_url: string | null;
  refund_proof_file_url: string | null;
  created_at: string | null;
};

type RefundAccountingTotals = {
  refund_evidence_submission_id: string;
  accepted_document_gross_gbp: number | null;
  total_coded_net_gbp: number | null;
  total_coded_vat_gbp: number | null;
  total_coded_gross_gbp: number | null;
  progressed_line_count: number | null;
  coded_line_count: number | null;
  all_progressed_lines_coded_yn: boolean | null;
  gross_reconciled_to_document_yn: boolean | null;
  gross_variance_gbp: number | null;
};

type AuthoritativeRefundStatus = {
  label: string;
  badgeClass: string;
  explanation: string | null;
  approvedCurrent: boolean;
};

type DisputeRow = {
  id: string;
  order_id: string;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | null;
};

type OrderLite = {
  id: string;
  order_ref: string | null;
  retailers: { name: string | null } | { name: string | null }[] | null;
  importers: { company_name: string | null } | { company_name: string | null }[] | null;
};

type ApprovalMessage = {
  id: string;
  dispute_id: string;
  body: string | null;
};

const STATUS_FILTERS = ["open", "ready", "blocked", "approved", "actioned", "all"] as const;
type StatusFilter = (typeof STATUS_FILTERS)[number];

const STATUS_FILTER_LABELS: Record<StatusFilter, string> = {
  open: "Open approval queue",
  ready: "Ready only",
  blocked: "Blocked only",
  approved: "Approved/current",
  actioned: "Actioned history",
  all: "All loaded statuses",
};

const STATUS_FILTER_DESCRIPTIONS: Record<StatusFilter, string> = {
  open: "Pending and duplicate-blocked invoices split into ready and blocked lanes.",
  ready: "Only invoices that can be approved current now.",
  blocked: "Only invoices that need reconciliation, coding, or review before approval.",
  approved: "Invoices already approved/current or reference-corrected approved.",
  actioned: "Approved/current, rejected and superseded invoice history.",
  all: "Open queue plus approved/rejected/superseded history.",
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

function bodyValue(body: string | null | undefined, key: string) {
  const line = (body ?? "").split("\n").find((row) => row.startsWith(`${key}:`));
  return line ? line.slice(key.length + 1).trim() : "";
}

function evidenceStatus(body: string | null | undefined) {
  const text = body ?? "";
  if (text.includes("credit_note_uploaded_pending_ocr_compare")) return "Credit note pending OCR/compare";
  if (text.includes("refund_adjustment_ready_no_credit_note")) return "Refund adjustment ready";
  if (text.includes("variance_supervisor_review_required")) return "Variance review needed";
  if (text.includes("no_document_supervisor_review_required")) return "No-document review needed";
  if (text.includes("supplier_refund_adjustment_review_required")) return "Review needed";
  return "Evidence uploaded";
}

function evidenceBadgeClass(body: string | null | undefined, approved: boolean) {
  if (approved) return "bg-emerald-100 text-emerald-800";
  const text = body ?? "";
  if (text.includes("refund_adjustment_ready_no_credit_note")) return "bg-emerald-100 text-emerald-800";
  if (text.includes("credit_note_uploaded_pending_ocr_compare")) return "bg-sky-100 text-sky-800";
  if (text.includes("review_required")) return "bg-amber-100 text-amber-800";
  return "bg-slate-100 text-slate-800";
}

function evidenceRoute(body: string | null | undefined) {
  return bodyValue(body, "supplier_readiness_route") || "—";
}

function isCreditNotePending(body: string | null | undefined) {
  const text = body ?? "";
  return text.includes("credit_note_uploaded_pending_ocr_compare") || text.includes("supplier_credit_note_readiness_pending_ocr");
}

function isReviewRequired(body: string | null | undefined) {
  const text = body ?? "";
  return text.includes("variance_supervisor_review_required") || text.includes("no_document_supervisor_review_required") || text.includes("supplier_refund_adjustment_review_required");
}

function isRefundAdjustmentReady(body: string | null | undefined) {
  return (body ?? "").includes("refund_adjustment_ready_no_credit_note");
}

function approvalReferencesEvidence(approval: ApprovalMessage, evidenceId: string) {
  return String(approval.body ?? "").includes(`source_evidence_message_id: ${evidenceId}`);
}

function authoritativeRefundStatus(submission: RefundSubmission, totals: RefundAccountingTotals | undefined): AuthoritativeRefundStatus {
  const approvedCurrent = submission.supplier_approval_status === "approved_current" || submission.supplier_control_status === "approved_current";
  if (approvedCurrent) {
    return { label: "Approved current", badgeClass: "bg-emerald-100 text-emerald-800", explanation: null, approvedCurrent: true };
  }

  const statuses = [submission.evidence_control_status, submission.supplier_readiness_route, submission.supplier_control_status].map((value) => String(value ?? ""));
  const rejected = submission.supervisor_review_status === "rejected"
    || submission.evidence_control_status === "staff_rejected_resubmission_required"
    || submission.supplier_readiness_route === "operator_resubmission_required"
    || statuses.some((value) => value.includes("rejected") || value.includes("resubmission_required"));
  if (rejected) {
    return { label: "Operator resubmission required", badgeClass: "bg-rose-100 text-rose-800", explanation: "The refund document was rejected or returned for operator resubmission.", approvedCurrent: false };
  }

  const ocrStatus = String(submission.ocr_status ?? "").toLowerCase();
  const creditNotePending = submission.document_mode === "credit_note" && (
    (ocrStatus !== "completed" && ocrStatus !== "complete")
    || submission.match_status === "pending_ocr"
    || submission.supplier_readiness_route === "supplier_credit_note_readiness_pending_ocr"
    || submission.evidence_control_status === "credit_note_uploaded_pending_ocr_compare"
  );
  if (creditNotePending) {
    return { label: "Credit note pending OCR/compare", badgeClass: "bg-sky-100 text-sky-800", explanation: "Credit-note control is blocked until OCR and document comparison complete.", approvedCurrent: false };
  }

  const reviewRequired = submission.supervisor_review_status === "pending_review"
    || submission.match_status === "needs_supervisor_review"
    || statuses.some((value) => value.includes("review_required"));
  if (reviewRequired) {
    return { label: "Supervisor review required", badgeClass: "bg-amber-100 text-amber-800", explanation: "Supervisor review must be completed before supplier approval can proceed.", approvedCurrent: false };
  }

  const accountingReady = Boolean(totals)
    && money(totals?.progressed_line_count) > 0
    && totals?.all_progressed_lines_coded_yn === true
    && totals?.gross_reconciled_to_document_yn === true;
  if (submission.supplier_control_status === "released_to_supplier_control" && accountingReady) {
    return { label: "Ready for approval", badgeClass: "bg-emerald-100 text-emerald-800", explanation: "Coding and document gross reconciliation are complete. Open supplier control to approve.", approvedCurrent: false };
  }
  if (submission.supplier_control_status === "released_to_supplier_control") {
    return { label: "Released — coding required", badgeClass: "bg-amber-100 text-amber-800", explanation: "Released to supplier control, but progressed lines are not fully coded and reconciled to the document gross.", approvedCurrent: false };
  }

  const readyForControl = submission.match_status === "matched"
    || statuses.some((value) => value.includes("ready") || value.includes("matched"));
  if (readyForControl) {
    return { label: "Ready for supplier control", badgeClass: "bg-sky-100 text-sky-800", explanation: "Document checks are ready. Open the dedicated supplier control page to continue.", approvedCurrent: false };
  }

  return { label: "Blocked / pending", badgeClass: "bg-slate-100 text-slate-800", explanation: "Refund-document readiness is still blocked or pending in the current workflow.", approvedCurrent: false };
}

function firstRefundTotal(...values: (number | null | undefined)[]) {
  return values.find((value) => value !== null && value !== undefined) ?? null;
}

function approvalBlocker(invoiceId: string, invoiceReadinessById: Map<string, string | null>, codingReadinessById: Map<string, string | null>) {
  return invoiceReadinessById.get(invoiceId) || codingReadinessById.get(invoiceId) || null;
}

function normalizedStatusFilter(value: string | undefined): StatusFilter {
  return STATUS_FILTERS.includes(value as StatusFilter) ? (value as StatusFilter) : "open";
}

function reviewStatusesForFilter(status: StatusFilter) {
  if (status === "approved") return ["approved_current", "ref_corrected_approved"];
  if (status === "actioned") return ["approved_current", "ref_corrected_approved", "rejected_resubmit_required", "superseded"];
  if (status === "all") return ["pending_review", "duplicate_blocked", "approved_current", "ref_corrected_approved", "rejected_resubmit_required", "superseded"];
  return ["pending_review", "duplicate_blocked"];
}

function statusHref(status: StatusFilter) {
  const params = new URLSearchParams();
  params.set("status", status);
  return `/internal/supplier-draft-ready?${params.toString()}`;
}

function invoiceStatusLabel(invoice: InvoiceRow) {
  if (invoice.is_current_for_order) return "Current";
  return invoice.review_status.replaceAll("_", " ");
}

function invoiceStatusBadgeClass(invoice: InvoiceRow, blocker: string | null) {
  if (blocker) return "bg-amber-100 text-amber-800";
  if (invoice.is_current_for_order || ["approved_current", "ref_corrected_approved"].includes(invoice.review_status)) return "bg-emerald-100 text-emerald-800";
  if (["rejected_resubmit_required", "superseded"].includes(invoice.review_status)) return "bg-slate-100 text-slate-700";
  return "bg-sky-100 text-sky-800";
}

function isActionedInvoice(invoice: InvoiceRow) {
  return invoice.is_current_for_order || ["approved_current", "ref_corrected_approved", "rejected_resubmit_required", "superseded"].includes(invoice.review_status);
}

function isHttpUrl(value: string | null | undefined) {
  return typeof value === "string" && (value.startsWith("http://") || value.startsWith("https://"));
}

export default async function SupplierDraftReadyPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const qp = await searchParams;
  const statusFilter = normalizedStatusFilter(qp.status);
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
    .in("review_status", reviewStatusesForFilter(statusFilter))
    .order("uploaded_at", { ascending: false })
    .limit(150);

  const invoices = (data ?? []) as unknown as InvoiceRow[];
  const invoiceReadinessEntries = await Promise.all(
    invoices.map(async (invoice) => [
      invoice.id,
      await assertInvoiceReadyForCurrentApproval(supabase, invoice.id),
    ] as const),
  );
  const invoiceReadinessById = new Map(invoiceReadinessEntries);

  const codingReadinessEntries = await Promise.all(
    invoices.map(async (invoice) => [
      invoice.id,
      await assertSupplierInvoiceAccountingCodingReady(supabase, invoice.id),
    ] as const),
  );
  const codingReadinessById = new Map(codingReadinessEntries);

  const readyInvoices = invoices.filter((invoice) => !approvalBlocker(invoice.id, invoiceReadinessById, codingReadinessById) && !invoice.is_current_for_order);
  const blockedInvoices = invoices.filter((invoice) => approvalBlocker(invoice.id, invoiceReadinessById, codingReadinessById) && !invoice.is_current_for_order);
  const actionedInvoices = invoices.filter(isActionedInvoice);
  const visibleReadyInvoices = ["open", "ready", "all"].includes(statusFilter) ? readyInvoices : [];
  const visibleBlockedInvoices = ["open", "blocked", "all"].includes(statusFilter) ? blockedInvoices : [];
  const visibleActionedInvoices = ["approved", "actioned", "all"].includes(statusFilter) ? actionedInvoices : [];
  const blockedCount = blockedInvoices.length;

  const { data: refundSubmissionsRaw, error: refundSubmissionsError } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select(`
      id,
      dispute_id,
      document_mode,
      credit_note_ref,
      credit_note_date,
      expected_credit_note_total_gbp,
      captured_refund_amount_abs_gbp,
      expected_exception_amount_abs_gbp,
      amount_balance_status,
      evidence_control_status,
      supplier_readiness_route,
      supplier_approval_status,
      supervisor_review_status,
      ocr_status,
      match_status,
      supplier_control_status,
      ocr_credit_note_ref,
      ocr_retailer_name,
      ocr_credit_note_date,
      ocr_credit_note_total_gbp,
      credit_note_file_url,
      refund_proof_file_url,
      created_at
    `)
    .order("created_at", { ascending: false })
    .order("id", { ascending: false })
    .limit(100);

  const refundSubmissions = (refundSubmissionsRaw ?? []) as RefundSubmission[];
  const latestSubmissionByDispute = new Map<string, RefundSubmission>();
  for (const submission of refundSubmissions) {
    if (!latestSubmissionByDispute.has(submission.dispute_id)) latestSubmissionByDispute.set(submission.dispute_id, submission);
  }
  const authoritativeSubmissions = [...latestSubmissionByDispute.values()];
  const authoritativeDisputeIds = new Set(authoritativeSubmissions.map((row) => row.dispute_id));
  const submissionIds = authoritativeSubmissions.map((row) => row.id);

  const { data: refundTotalsRaw, error: refundTotalsError } = submissionIds.length
    ? await supabase
        .from("dispute_refund_document_accounting_totals_vw")
        .select(`
          refund_evidence_submission_id,
          accepted_document_gross_gbp,
          total_coded_net_gbp,
          total_coded_vat_gbp,
          total_coded_gross_gbp,
          progressed_line_count,
          coded_line_count,
          all_progressed_lines_coded_yn,
          gross_reconciled_to_document_yn,
          gross_variance_gbp
        `)
        .in("refund_evidence_submission_id", submissionIds)
    : { data: [], error: null };
  const refundTotalsBySubmissionId = new Map(
    ((refundTotalsRaw ?? []) as RefundAccountingTotals[]).map((row) => [row.refund_evidence_submission_id, row]),
  );

  const { data: refundEvidenceRaw, error: legacyRefundEvidenceError } = await supabase
    .from("dispute_messages")
    .select("id, dispute_id, message_type, body, created_at, generated_by")
    .in("message_type", ["credit_note_evidence", "refund_evidence"])
    .order("created_at", { ascending: false })
    .limit(50);

  const refundEvidence = (refundEvidenceRaw ?? []) as RefundEvidenceMessage[];
  const latestLegacyEvidenceByDispute = new Map<string, RefundEvidenceMessage>();
  for (const row of refundEvidence) {
    if (!authoritativeDisputeIds.has(row.dispute_id) && !latestLegacyEvidenceByDispute.has(row.dispute_id)) {
      latestLegacyEvidenceByDispute.set(row.dispute_id, row);
    }
  }
  const legacyRefundRows = [...latestLegacyEvidenceByDispute.values()];
  const legacyDisputeIds = legacyRefundRows.map((row) => row.dispute_id);

  const { data: refundApprovalRaw } = legacyDisputeIds.length
    ? await supabase
        .from("dispute_messages")
        .select("id, dispute_id, body")
        .eq("message_type", "supplier_refund_current_approved")
        .in("dispute_id", legacyDisputeIds)
    : { data: [] };
  const refundApprovals = (refundApprovalRaw ?? []) as ApprovalMessage[];

  const disputeIds = [...new Set([
    ...authoritativeSubmissions.map((row) => row.dispute_id),
    ...legacyDisputeIds,
  ].filter(Boolean))];
  const { data: disputesRaw } = disputeIds.length
    ? await supabase
        .from("disputes")
        .select("id, order_id, desired_outcome, status, amount_impact_gbp")
        .in("id", disputeIds)
    : { data: [] };

  const disputes = (disputesRaw ?? []) as DisputeRow[];
  const orderIds = [...new Set(disputes.map((row) => row.order_id).filter(Boolean))];
  const { data: ordersRaw } = orderIds.length
    ? await supabase
        .from("orders")
        .select("id, order_ref, retailers(name), importers(company_name)")
        .in("id", orderIds)
    : { data: [] };

  const disputeById = new Map(disputes.map((row) => [row.id, row]));
  const orderById = new Map(((ordersRaw ?? []) as unknown as OrderLite[]).map((row) => [row.id, row]));
  const refundPanelErrors = [
    refundSubmissionsError ? `Failed to load current refund submissions: ${refundSubmissionsError.message}` : null,
    refundTotalsError ? `Failed to load refund accounting totals: ${refundTotalsError.message}` : null,
    legacyRefundEvidenceError ? `Failed to load historic refund evidence fallback: ${legacyRefundEvidenceError.message}` : null,
  ].filter((message): message is string => Boolean(message));


  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-emerald-500">Supplier draft ready</p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Supplier invoices and refund credits ready for control</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This lane shows supplier invoices by status: open approval queue, blocked coding/reconciliation, approved/current, rejected and superseded history. Approving here marks supplier-side records as ready for later Sage preparation; it does not post to Sage yet.
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

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p className="text-sm font-semibold text-slate-950">Invoice status filter</p>
              <p className="mt-1 text-sm text-slate-600">{STATUS_FILTER_DESCRIPTIONS[statusFilter]}</p>
            </div>
            <div className="flex flex-wrap gap-2">
              {STATUS_FILTERS.map((status) => (
                <Link
                  key={status}
                  href={statusHref(status)}
                  className={`rounded-full px-3 py-1 text-xs font-semibold ring-1 ${statusFilter === status ? "bg-slate-950 text-white ring-slate-950" : "bg-white text-slate-700 ring-slate-200 hover:bg-slate-50"}`}
                >
                  {STATUS_FILTER_LABELS[status]}
                </Link>
              ))}
            </div>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Invoices ready</p><p className="mt-2 text-3xl font-semibold">{readyInvoices.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Blocked invoices</p><p className="mt-2 text-3xl font-semibold">{blockedCount}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Actioned invoices</p><p className="mt-2 text-3xl font-semibold">{actionedInvoices.length}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm uppercase tracking-wide text-slate-500">Loaded invoices checked</p><p className="mt-2 text-3xl font-semibold">{invoices.length}</p></div>
        </section>

        <section className="rounded-3xl border border-sky-200 bg-white p-6 shadow-sm">
          <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Refund / credit-note readiness</p>
              <h2 className="mt-2 text-xl font-semibold">Supplier-side refund evidence routed from exceptions</h2>
              <p className="mt-2 max-w-3xl text-sm text-slate-600">
                Credit notes must be OCR-compared before supplier credit-note approval. Refunds without credit notes can be approved current here when balanced to the exception. DVA/card refund IN matching still clears the money position.
              </p>
            </div>
          </div>

          {refundPanelErrors.length > 0 ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-900">
              <p className="font-semibold">Some refund readiness data could not be loaded.</p>
              {refundPanelErrors.map((message) => <p key={message} className="mt-1">{message}</p>)}
            </div>
          ) : null}

          {authoritativeSubmissions.length === 0 && legacyRefundRows.length === 0 && refundPanelErrors.length === 0 ? (
            <p className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">No refund or credit-note evidence has been routed here yet.</p>
          ) : (
            <div className="mt-5 grid gap-4">
              {authoritativeSubmissions.map((submission) => {
                const dispute = disputeById.get(submission.dispute_id);
                const order = dispute ? orderById.get(dispute.order_id) : null;
                const retailer = firstRelated(order?.retailers)?.name ?? submission.ocr_retailer_name ?? "—";
                const importer = firstRelated(order?.importers)?.company_name ?? "—";
                const totals = refundTotalsBySubmissionId.get(submission.id);
                const currentStatus = authoritativeRefundStatus(submission, totals);
                const acceptedTotal = firstRefundTotal(
                  totals?.accepted_document_gross_gbp,
                  submission.ocr_credit_note_total_gbp,
                  submission.expected_credit_note_total_gbp,
                  submission.captured_refund_amount_abs_gbp,
                  submission.expected_exception_amount_abs_gbp,
                );
                const documentUrl = isHttpUrl(submission.credit_note_file_url)
                  ? submission.credit_note_file_url
                  : isHttpUrl(submission.refund_proof_file_url) ? submission.refund_proof_file_url : null;

                return (
                  <article key={submission.id} className="rounded-3xl border border-sky-100 bg-sky-50 p-5 shadow-sm">
                    <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                      <div>
                        <div className="flex flex-wrap items-center gap-2">
                          <h3 className="text-lg font-semibold">{order?.order_ref ?? dispute?.order_id ?? submission.dispute_id}</h3>
                          <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${currentStatus.badgeClass}`}>{currentStatus.label}</span>
                        </div>
                        <p className="mt-2 text-sm text-slate-600">Importer: {importer} · Retailer: {retailer}</p>
                        <p className="text-sm text-slate-600">Document mode: {submission.document_mode ?? "—"} · Credit note ref: {submission.ocr_credit_note_ref ?? submission.credit_note_ref ?? "—"}</p>
                        <p className="text-sm text-slate-600">Route: {submission.supplier_readiness_route ?? "—"}</p>
                      </div>
                      <div className="flex flex-wrap gap-2">
                        <Link href={`/internal/exceptions/${submission.dispute_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open exception</Link>
                        {dispute?.order_id ? <Link href={`/internal/evidence/${dispute.order_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open order</Link> : null}
                        <Link href={`/internal/refund-document-control/${submission.id}`} className="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white hover:bg-slate-700">Open credit/refund control</Link>
                        {documentUrl ? <a href={documentUrl} target="_blank" rel="noreferrer" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open document</a> : null}
                      </div>
                    </div>

                    <div className="mt-4 grid gap-3 md:grid-cols-3">
                      <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Exception amount</p><p className="mt-1 font-semibold">{gbp(dispute?.amount_impact_gbp)}</p></div>
                      <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Accepted / captured total</p><p className="mt-1 font-semibold">{acceptedTotal === null ? "—" : gbp(acceptedTotal)}</p></div>
                      <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Submission date</p><p className="mt-1 font-semibold">{submission.created_at ? new Date(submission.created_at).toLocaleDateString("en-GB") : "—"}</p></div>
                    </div>

                    {currentStatus.explanation ? <p className="mt-3 rounded-xl border border-amber-200 bg-white p-3 text-sm text-amber-800">{currentStatus.explanation}</p> : null}
                    {currentStatus.approvedCurrent ? <p className="mt-3 rounded-xl border border-emerald-200 bg-white p-3 text-sm text-emerald-800">Supplier-side refund evidence is approved current. DVA/card refund IN still needs matching for money clearance.</p> : null}
                  </article>
                );
              })}

              {legacyRefundRows.map((evidence) => {
                const dispute = disputeById.get(evidence.dispute_id);
                const order = dispute ? orderById.get(dispute.order_id) : null;
                const retailer = firstRelated(order?.retailers)?.name ?? "—";
                const importer = firstRelated(order?.importers)?.company_name ?? "—";
                const documentMode = bodyValue(evidence.body, "document_mode") || "—";
                const expectedTotal = bodyValue(evidence.body, "operator_expected_credit_note_total_gbp") || bodyValue(evidence.body, "captured_refund_amount_abs_gbp") || "0";
                const creditNoteRef = bodyValue(evidence.body, "credit_note_ref") || "—";
                const route = evidenceRoute(evidence.body);
                const approvedCurrent = refundApprovals.some((approval) => approvalReferencesEvidence(approval, evidence.id));
                const canApproveNow = !approvedCurrent && isRefundAdjustmentReady(evidence.body) && !isCreditNotePending(evidence.body) && !isReviewRequired(evidence.body);
                const reviewNeeded = isReviewRequired(evidence.body);
                const creditNotePending = isCreditNotePending(evidence.body);

                return (
                  <article key={evidence.id} className="rounded-3xl border border-sky-100 bg-sky-50 p-5 shadow-sm">
                    <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                      <div>
                        <div className="flex flex-wrap items-center gap-2">
                          <h3 className="text-lg font-semibold">{order?.order_ref ?? dispute?.order_id ?? evidence.dispute_id}</h3>
                          <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${evidenceBadgeClass(evidence.body, approvedCurrent)}`}>{approvedCurrent ? "Approved current" : evidenceStatus(evidence.body)}</span>
                          <span className="rounded-full bg-slate-200 px-2.5 py-1 text-xs font-semibold text-slate-700">Historic fallback</span>
                        </div>
                        <p className="mt-2 text-sm text-slate-600">Importer: {importer} · Retailer: {retailer}</p>
                        <p className="text-sm text-slate-600">Document mode: {documentMode} · Credit note ref: {creditNoteRef}</p>
                        <p className="text-sm text-slate-600">Route: {route}</p>
                      </div>
                      <div className="flex flex-wrap gap-2">
                        <Link href={`/internal/exceptions/${evidence.dispute_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open exception</Link>
                        {dispute?.order_id ? <Link href={`/internal/evidence/${dispute.order_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open order</Link> : null}
                        {canApproveNow ? (
                          <form action={approveSupplierRefundEvidenceCurrentAction}>
                            <input type="hidden" name="evidence_message_id" value={evidence.id} />
                            <input type="hidden" name="dispute_id" value={evidence.dispute_id} />
                            <button className="rounded-xl bg-emerald-700 px-3 py-2 text-sm font-semibold text-white hover:bg-emerald-600">Approve refund adjustment current</button>
                          </form>
                        ) : null}
                      </div>
                    </div>

                    <div className="mt-4 grid gap-3 md:grid-cols-4">
                      <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Exception amount</p><p className="mt-1 font-semibold">{gbp(dispute?.amount_impact_gbp)}</p></div>
                      <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Captured / expected</p><p className="mt-1 font-semibold">{gbp(expectedTotal)}</p></div>
                      <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Evidence date</p><p className="mt-1 font-semibold">{evidence.created_at ? new Date(evidence.created_at).toLocaleDateString("en-GB") : "—"}</p></div>
                      <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Generated by</p><p className="mt-1 font-semibold">{evidence.generated_by ?? "—"}</p></div>
                    </div>

                    {creditNotePending ? <p className="mt-3 rounded-xl border border-sky-200 bg-white p-3 text-sm text-sky-800">Credit-note approval is blocked until OCR/compare is wired and passes.</p> : null}
                    {reviewNeeded ? <p className="mt-3 rounded-xl border border-amber-200 bg-white p-3 text-sm text-amber-800">Supervisor exception review is required before this evidence can be approved current.</p> : null}
                    {approvedCurrent ? <p className="mt-3 rounded-xl border border-emerald-200 bg-white p-3 text-sm text-emerald-800">Supplier-side refund evidence is approved current. DVA/card refund IN still needs matching for money clearance.</p> : null}
                  </article>
                );
              })}
            </div>
          )}
        </section>

        <form id="bulk-approve-supplier-invoices" action={bulkApproveSupplierInvoicesCurrentAction} />

        <div className="grid gap-4">
          {visibleReadyInvoices.length > 0 || visibleBlockedInvoices.length > 0 ? (
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
              <p className="text-sm text-slate-600">Only fully reconciled and accounting-coded supplier invoices can be approved current. Sage posting remains a later controlled step.</p>
              <button form="bulk-approve-supplier-invoices" disabled={visibleReadyInvoices.length === 0} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-600 disabled:cursor-not-allowed disabled:bg-slate-300">Bulk approve selected</button>
            </div>
          ) : null}

          {visibleReadyInvoices.length === 0 && ["open", "ready", "all"].includes(statusFilter) ? <p className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-900">No fully coded supplier invoices are currently ready in this filter. Open reconciliation/accounting coding for blocked invoices below.</p> : null}

          {visibleReadyInvoices.map((invoice) => {
            const order = getOrder(invoice);
            const enteredTotal = getEnteredTotal(invoice);
            const acceptedTotal = invoice.ocr_invoice_total_gbp ?? enteredTotal;
            const delivery = adjustmentTotal(invoice, "retailer_delivery");
            const discount = adjustmentTotal(invoice, "retailer_discount");
            const totalLines = lineTotal(invoice);
            const flagCount = activeFlagCount(invoice);
            const singleApproveFormId = `approve-current-${invoice.id}`;

            return (
              <article key={invoice.id} className="rounded-3xl border border-emerald-200 bg-white p-5 shadow-sm">
                <form id={singleApproveFormId} action={approveSupplierInvoiceCurrentAction}>
                  <input type="hidden" name="single_supplier_invoice_id" value={invoice.id} />
                </form>
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div className="flex gap-3">
                    <input form="bulk-approve-supplier-invoices" type="checkbox" name="supplier_invoice_id" value={invoice.id} className="mt-1 h-5 w-5 rounded border-slate-300" defaultChecked />
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
                    {isHttpUrl(invoice.invoice_pdf_url) ? <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white">Open invoice</a> : null}
                    <button form={singleApproveFormId} className="rounded-xl bg-emerald-700 px-3 py-2 text-sm font-semibold text-white hover:bg-emerald-600">Approve current</button>
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

          {visibleBlockedInvoices.length > 0 ? (
            <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 shadow-sm">
              <h2 className="text-xl font-semibold text-amber-950">Blocked invoices needing reconciliation/coding</h2>
              <p className="mt-2 text-sm text-amber-900">These are not approval-ready and cannot be bulk approved. Fix the blocker from reconciliation/accounting coding first.</p>
              <div className="mt-4 grid gap-3">
                {visibleBlockedInvoices.map((invoice) => {
                  const order = getOrder(invoice);
                  const blocker = approvalBlocker(invoice.id, invoiceReadinessById, codingReadinessById) ?? "Invoice is blocked.";
                  const enteredTotal = getEnteredTotal(invoice);
                  const acceptedTotal = invoice.ocr_invoice_total_gbp ?? enteredTotal;
                  const totalLines = lineTotal(invoice);
                  const flagCount = activeFlagCount(invoice);
                  return (
                    <article key={invoice.id} className="rounded-2xl border border-amber-200 bg-white p-4">
                      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                        <div>
                          <div className="flex flex-wrap items-center gap-2">
                            <h3 className="text-lg font-semibold">{order?.order_ref ?? invoice.order_id}</h3>
                            <span className="rounded-full bg-amber-100 px-2.5 py-1 text-xs font-semibold text-amber-800">Blocked</span>
                          </div>
                          <p className="mt-2 text-sm text-slate-600">Importer: {getOrderImporterName(invoice) ?? "—"}</p>
                          <p className="text-sm text-slate-600">Retailer: {getOrderRetailerName(invoice) ?? "—"}</p>
                          <p className="text-sm text-slate-600">Invoice ref: {invoice.ocr_invoice_ref ?? invoice.invoice_ref}</p>
                        </div>
                        <div className="flex flex-wrap gap-2">
                          <Link href={`/internal/evidence/${invoice.order_id}`} className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open order</Link>
                          <Link href={`/internal/reconciliation/${invoice.order_id}`} className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open reconciliation/coding</Link>
                          {isHttpUrl(invoice.invoice_pdf_url) ? <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white">Open invoice</a> : null}
                        </div>
                      </div>
                      <p className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{blocker}</p>
                      <div className="mt-4 grid gap-3 md:grid-cols-3">
                        <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Accepted total</p><p className="mt-1 font-semibold">{acceptedTotal === null ? "—" : gbp(acceptedTotal)}</p></div>
                        <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Line total</p><p className="mt-1 font-semibold">{gbp(totalLines)}</p></div>
                        <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Open flags</p><p className="mt-1 font-semibold">{flagCount}</p></div>
                      </div>
                    </article>
                  );
                })}
              </div>
            </section>
          ) : null}

          {visibleActionedInvoices.length > 0 ? (
            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <h2 className="text-xl font-semibold text-slate-950">Actioned invoices / approval history</h2>
              <p className="mt-2 text-sm text-slate-600">These records have already been actioned: approved/current, rejected or superseded. They are shown for traceability and follow-up, not for bulk approval.</p>
              <div className="mt-4 grid gap-3">
                {visibleActionedInvoices.map((invoice) => {
                  const order = getOrder(invoice);
                  const blocker = approvalBlocker(invoice.id, invoiceReadinessById, codingReadinessById);
                  const enteredTotal = getEnteredTotal(invoice);
                  const acceptedTotal = invoice.ocr_invoice_total_gbp ?? enteredTotal;
                  const totalLines = lineTotal(invoice);
                  const flagCount = activeFlagCount(invoice);
                  return (
                    <article key={invoice.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                        <div>
                          <div className="flex flex-wrap items-center gap-2">
                            <h3 className="text-lg font-semibold text-slate-950">{order?.order_ref ?? invoice.order_id}</h3>
                            <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${invoiceStatusBadgeClass(invoice, blocker)}`}>{invoiceStatusLabel(invoice)}</span>
                          </div>
                          <p className="mt-2 text-sm text-slate-600">Importer: {getOrderImporterName(invoice) ?? "—"}</p>
                          <p className="text-sm text-slate-600">Retailer: {getOrderRetailerName(invoice) ?? "—"}</p>
                          <p className="text-sm text-slate-600">Invoice ref: {invoice.ocr_invoice_ref ?? invoice.invoice_ref}</p>
                          <p className="text-sm text-slate-600">Uploaded: {invoice.uploaded_at ? new Date(invoice.uploaded_at).toLocaleString("en-GB") : "—"}</p>
                        </div>
                        <div className="flex flex-wrap gap-2">
                          <Link href={`/internal/evidence/${invoice.order_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open order</Link>
                          <Link href={`/internal/reconciliation/${invoice.order_id}`} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open reconciliation/coding</Link>
                          {isHttpUrl(invoice.invoice_pdf_url) ? <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white">Open invoice</a> : null}
                        </div>
                      </div>
                      {blocker ? <p className="mt-3 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Follow-up needed: {blocker}</p> : null}
                      <div className="mt-4 grid gap-3 md:grid-cols-3">
                        <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Accepted total</p><p className="mt-1 font-semibold">{acceptedTotal === null ? "—" : gbp(acceptedTotal)}</p></div>
                        <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Line total</p><p className="mt-1 font-semibold">{gbp(totalLines)}</p></div>
                        <div className="rounded-2xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Open flags</p><p className="mt-1 font-semibold">{flagCount}</p></div>
                      </div>
                    </article>
                  );
                })}
              </div>
            </section>
          ) : null}
        </div>
      </div>
    </main>
  );
}
