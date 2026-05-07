import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;
type Row = Record<string, unknown>;

type StaffRow = { id: string; full_name: string | null; role_type: string | null };
type SubmissionRow = {
  id: string;
  dispute_id: string;
  original_order_id: string | null;
  original_supplier_invoice_id: string | null;
  submitted_at: string | null;
  document_mode: string | null;
  credit_note_ref: string | null;
  credit_note_date: string | null;
  credit_note_file_url: string | null;
  refund_proof_file_url: string | null;
  captured_refund_amount_abs_gbp: number | string | null;
  expected_exception_amount_abs_gbp: number | string | null;
  variance_abs_gbp: number | string | null;
  amount_balance_status: string | null;
  supplier_approval_status: string | null;
  supplier_control_status: string | null;
  supplier_approved_at: string | null;
  match_status: string | null;
};
type DisputeRow = { id: string; order_id: string | null; desired_outcome: string | null; status: string | null; amount_impact_gbp: number | string | null };
type OrderRow = { id: string; order_ref: string | null; importer_id: string | null; retailer_id: string | null; status: string | null };
type ImporterRow = { id: string; company_name: string | null; trading_name: string | null };
type RetailerRow = { id: string; name: string | null };
type SupplierInvoiceRow = { id: string; invoice_ref: string | null; invoice_pdf_url: string | null; review_status: string | null; retailer_id: string | null };
type RefundLineRow = {
  id: string;
  refund_evidence_submission_id: string;
  line_order: number | string | null;
  line_source: string | null;
  description: string | null;
  qty: number | string | null;
  amount_gbp: number | string | null;
  progressed_to_supplier_control_yn: boolean | string | null;
};
type LineCodeRow = {
  refund_document_line_id: string;
  description_override: string | null;
  sku_override: string | null;
  size_override: string | null;
  sage_ledger_account_id: string | null;
  nominal_code: string | null;
  tax_rate_id: string | null;
  tax_rate_label: string | null;
  vat_rate_percent: number | string | null;
  net_amount_gbp: number | string | null;
  vat_amount_gbp: number | string | null;
  gross_amount_gbp: number | string | null;
  admin_review_required_yn: boolean | string | null;
  review_reason: string | null;
};
type AdjustmentRow = {
  refund_evidence_submission_id: string;
  description: string | null;
  sku: string | null;
  size: string | null;
  sage_ledger_account_id: string | null;
  nominal_code: string | null;
  tax_rate_id: string | null;
  tax_rate_label: string | null;
  vat_rate_percent: number | string | null;
  net_amount_gbp: number | string | null;
  vat_amount_gbp: number | string | null;
  gross_amount_gbp: number | string | null;
};
type TotalsRow = {
  refund_evidence_submission_id: string;
  accepted_document_gross_gbp: number | string | null;
  total_coded_net_gbp: number | string | null;
  total_coded_vat_gbp: number | string | null;
  total_coded_gross_gbp: number | string | null;
  adjustment_gross_gbp: number | string | null;
  progressed_line_count: number | string | null;
  coded_line_count: number | string | null;
  all_progressed_lines_coded_yn: boolean | string | null;
  gross_reconciled_to_document_yn: boolean | string | null;
  gross_variance_gbp: number | string | null;
};
type AllocationRow = { dispute_id: string | null; allocation_type: string | null; allocation_status: string | null; allocated_gbp_amount: number | string | null };

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function round2(value: number) {
  return Math.round(value * 100) / 100;
}

function shortId(value: string | null | undefined) {
  return (value ?? "").slice(0, 8);
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function groupBy<T>(rows: T[], keyFn: (row: T) => string) {
  const map = new Map<string, T[]>();
  for (const row of rows) {
    const key = keyFn(row);
    if (!key) continue;
    map.set(key, [...(map.get(key) ?? []), row]);
  }
  return map;
}

function keyBy<T>(rows: T[], keyFn: (row: T) => string) {
  const map = new Map<string, T>();
  for (const row of rows) {
    const key = keyFn(row);
    if (key) map.set(key, row);
  }
  return map;
}

function statusClass(ok: boolean) {
  return ok ? "border-emerald-200 bg-emerald-50 text-emerald-800" : "border-amber-200 bg-amber-50 text-amber-900";
}

function linePayload(line: RefundLineRow, code?: LineCodeRow) {
  return {
    source_refund_document_line_id: line.id,
    line_order: Number(line.line_order ?? 0),
    line_source: line.line_source,
    description: code?.description_override || line.description || "Supplier credit line",
    sku: code?.sku_override || null,
    size: code?.size_override || null,
    nominal_code: code?.nominal_code || null,
    sage_ledger_account_id: code?.sage_ledger_account_id || null,
    tax_rate_id: code?.tax_rate_id || null,
    tax_rate_label: code?.tax_rate_label || null,
    vat_rate_percent: num(code?.vat_rate_percent),
    net_credit_gbp: round2(num(code?.net_amount_gbp)),
    vat_credit_gbp: round2(num(code?.vat_amount_gbp)),
    gross_credit_gbp: round2(num(code?.gross_amount_gbp || line.amount_gbp)),
    posting_sign: "credit",
  };
}

function adjustmentPayload(row: AdjustmentRow) {
  return {
    description: row.description || "Supplier credit adjustment",
    sku: row.sku || null,
    size: row.size || null,
    nominal_code: row.nominal_code || null,
    sage_ledger_account_id: row.sage_ledger_account_id || null,
    tax_rate_id: row.tax_rate_id || null,
    tax_rate_label: row.tax_rate_label || null,
    vat_rate_percent: num(row.vat_rate_percent),
    net_credit_gbp: round2(num(row.net_amount_gbp)),
    vat_credit_gbp: round2(num(row.vat_amount_gbp)),
    gross_credit_gbp: round2(num(row.gross_amount_gbp)),
    posting_sign: "credit",
  };
}

function buildPreview(args: {
  submission: SubmissionRow;
  dispute?: DisputeRow;
  order?: OrderRow;
  importer?: ImporterRow;
  retailer?: RetailerRow;
  invoice?: SupplierInvoiceRow;
  lines: RefundLineRow[];
  codeByLineId: Map<string, LineCodeRow>;
  adjustments: AdjustmentRow[];
  totals?: TotalsRow;
  allocations: AllocationRow[];
}) {
  const { submission, dispute, order, importer, retailer, invoice, lines, codeByLineId, adjustments, totals, allocations } = args;
  const progressedLines = lines.filter((line) => bool(line.progressed_to_supplier_control_yn));
  const codedLines = progressedLines.filter((line) => codeByLineId.has(line.id));
  const acceptedGross = Math.max(num(totals?.accepted_document_gross_gbp), num(submission.captured_refund_amount_abs_gbp), num(submission.expected_exception_amount_abs_gbp), num(dispute?.amount_impact_gbp));
  const codedGross = round2(num(totals?.total_coded_gross_gbp));
  const refundInAllocated = round2(
    allocations
      .filter((row) => text(row.dispute_id) === submission.dispute_id && text(row.allocation_type) === "retailer_refund" && text(row.allocation_status) === "confirmed")
      .reduce((sum, row) => sum + num(row.allocated_gbp_amount), 0),
  );

  const blockers: string[] = [];
  const warnings: string[] = [];
  if (submission.document_mode !== "refund_proof_no_credit_note") blockers.push("thin preview currently covers refund proof / no credit note only");
  if (submission.supplier_approval_status !== "approved_current") blockers.push("supplier refund evidence is not approved current");
  if (submission.supplier_control_status !== "approved_current") blockers.push("supplier control status is not approved current");
  if (!bool(totals?.gross_reconciled_to_document_yn)) blockers.push("coded gross does not reconcile to accepted refund document gross");
  if (progressedLines.length === 0) blockers.push("no refund document lines released to supplier control");
  if (codedLines.length !== progressedLines.length) blockers.push("not all released refund document lines are coded");
  if (refundInAllocated + 0.01 < acceptedGross) blockers.push("confirmed refund-IN allocation is below accepted refund amount");

  for (const line of progressedLines) {
    const code = codeByLineId.get(line.id);
    if (!code?.nominal_code && !code?.sage_ledger_account_id) warnings.push(`Line ${line.line_order} has no nominal or Sage ledger reference`);
    if (bool(code?.admin_review_required_yn)) warnings.push(`Line ${line.line_order} was marked for admin review`);
  }

  const ready = blockers.length === 0;
  const orderRef = order?.order_ref || shortId(dispute?.order_id ?? submission.id);
  const documentDate = (submission.supplier_approved_at || submission.credit_note_date || submission.submitted_at || new Date().toISOString()).slice(0, 10);
  const payload = {
    preview_version: "supplier_credit_equivalent_preview_v0",
    preview_only_not_posted: true,
    payload_family: "supplier_credit_or_refund_adjustment",
    document_mode: submission.document_mode,
    posting_intent: "supplier_credit_equivalent",
    accounting_effect_summary: "Reduce supplier-side cost/creditor position and reverse the coded net/VAT/gross amounts using credit-note-equivalent treatment. Exact Sage object mapping remains for the final Sage adapter.",
    source_ids: {
      refund_evidence_submission_id: submission.id,
      dispute_id: submission.dispute_id,
      order_id: order?.id || dispute?.order_id || null,
      original_supplier_invoice_id: submission.original_supplier_invoice_id,
    },
    header: {
      document_reference: submission.credit_note_ref || `REFUND-${orderRef}-${shortId(submission.id)}`,
      document_date: documentDate,
      currency: "GBP",
      order_ref: orderRef,
      importer_name: importer?.trading_name || importer?.company_name || null,
      retailer_name: retailer?.name || null,
      original_supplier_invoice_ref: invoice?.invoice_ref || null,
      gross_credit_gbp: round2(acceptedGross),
      refund_in_allocated_gbp: refundInAllocated,
    },
    lines: progressedLines.map((line) => linePayload(line, codeByLineId.get(line.id))),
    adjustments: adjustments.map(adjustmentPayload),
    controls: {
      supplier_approval_status: submission.supplier_approval_status,
      supplier_control_status: submission.supplier_control_status,
      match_status: submission.match_status,
      amount_balance_status: submission.amount_balance_status,
      accepted_gross_gbp: round2(acceptedGross),
      coded_gross_gbp: codedGross,
      gross_variance_gbp: round2(num(totals?.gross_variance_gbp ?? codedGross - acceptedGross)),
      all_released_lines_coded: codedLines.length === progressedLines.length && progressedLines.length > 0,
      refund_in_allocation_covers_approved_amount: refundInAllocated + 0.01 >= acceptedGross,
    },
    evidence: {
      refund_proof_file_url: submission.refund_proof_file_url || null,
      credit_note_file_url: submission.credit_note_file_url || null,
    },
  };

  return { ready, blockers, warnings, payload, acceptedGross, codedGross, refundInAllocated, progressedLines, codedLines };
}

export default async function SupplierCreditPayloadPreviewPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const submissionId = firstParam(params.submission_id);
  const disputeId = firstParam(params.dispute_id);
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  const activeStaff = staff as StaffRow | null;
  if (!activeStaff || !["admin", "supervisor"].includes(text(activeStaff.role_type))) redirect("/internal");

  let submissionQuery = supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, original_order_id, original_supplier_invoice_id, submitted_at, document_mode, credit_note_ref, credit_note_date, credit_note_file_url, refund_proof_file_url, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, variance_abs_gbp, amount_balance_status, supplier_approval_status, supplier_control_status, supplier_approved_at, match_status")
    .eq("document_mode", "refund_proof_no_credit_note")
    .eq("supplier_approval_status", "approved_current")
    .eq("supplier_control_status", "approved_current")
    .order("supplier_approved_at", { ascending: false })
    .limit(25);

  if (submissionId) submissionQuery = submissionQuery.eq("id", submissionId);
  if (disputeId) submissionQuery = submissionQuery.eq("dispute_id", disputeId);

  const { data: submissionsRaw, error: submissionsError } = await submissionQuery;
  const submissions = (submissionsRaw ?? []) as unknown as SubmissionRow[];

  if (submissionsError) {
    return (
      <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
        <div className="mx-auto max-w-5xl rounded-3xl border border-rose-200 bg-rose-50 p-6 text-rose-900">
          <h1 className="text-2xl font-semibold">Could not load supplier credit preview</h1>
          <p className="mt-2 text-sm">{submissionsError.message}</p>
        </div>
      </main>
    );
  }

  const submissionIds = submissions.map((row) => row.id);
  const disputeIds = Array.from(new Set(submissions.map((row) => row.dispute_id).filter(Boolean)));
  const originalInvoiceIds = Array.from(new Set(submissions.map((row) => row.original_supplier_invoice_id).filter(Boolean) as string[]));

  const [linesResult, totalsResult, disputesResult, invoicesResult, allocationsResult] = await Promise.all([
    submissionIds.length
      ? supabase
          .from("dispute_refund_document_lines")
          .select("id, refund_evidence_submission_id, line_order, line_source, description, qty, amount_gbp, progressed_to_supplier_control_yn")
          .in("refund_evidence_submission_id", submissionIds)
          .order("line_order", { ascending: true })
      : { data: [] as RefundLineRow[], error: null },
    submissionIds.length
      ? supabase
          .from("dispute_refund_document_accounting_totals_vw")
          .select("refund_evidence_submission_id, accepted_document_gross_gbp, total_coded_net_gbp, total_coded_vat_gbp, total_coded_gross_gbp, adjustment_gross_gbp, progressed_line_count, coded_line_count, all_progressed_lines_coded_yn, gross_reconciled_to_document_yn, gross_variance_gbp")
          .in("refund_evidence_submission_id", submissionIds)
      : { data: [] as TotalsRow[], error: null },
    disputeIds.length
      ? supabase
          .from("disputes")
          .select("id, order_id, desired_outcome, status, amount_impact_gbp")
          .in("id", disputeIds)
      : { data: [] as DisputeRow[], error: null },
    originalInvoiceIds.length
      ? supabase
          .from("supplier_invoices")
          .select("id, invoice_ref, invoice_pdf_url, review_status, retailer_id")
          .in("id", originalInvoiceIds)
      : { data: [] as SupplierInvoiceRow[], error: null },
    disputeIds.length
      ? supabase
          .from("dva_statement_line_allocation_detail_vw")
          .select("dispute_id, allocation_type, allocation_status, allocated_gbp_amount")
          .in("dispute_id", disputeIds)
      : { data: [] as AllocationRow[], error: null },
  ]);

  const firstError = linesResult.error || totalsResult.error || disputesResult.error || invoicesResult.error || allocationsResult.error;
  if (firstError) {
    return (
      <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
        <div className="mx-auto max-w-5xl rounded-3xl border border-rose-200 bg-rose-50 p-6 text-rose-900">
          <h1 className="text-2xl font-semibold">Could not load preview detail rows</h1>
          <p className="mt-2 text-sm">{firstError.message}</p>
        </div>
      </main>
    );
  }

  const lines = (linesResult.data ?? []) as unknown as RefundLineRow[];
  const lineIds = lines.map((line) => line.id);
  const [codesResult, adjustmentsResult] = await Promise.all([
    lineIds.length
      ? supabase
          .from("dispute_refund_document_line_accounting_codes")
          .select("refund_document_line_id, description_override, sku_override, size_override, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp, admin_review_required_yn, review_reason")
          .in("refund_document_line_id", lineIds)
      : { data: [] as LineCodeRow[], error: null },
    submissionIds.length
      ? supabase
          .from("dispute_refund_document_accounting_adjustment_lines")
          .select("refund_evidence_submission_id, description, sku, size, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp")
          .in("refund_evidence_submission_id", submissionIds)
      : { data: [] as AdjustmentRow[], error: null },
  ]);

  if (codesResult.error || adjustmentsResult.error) {
    return (
      <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
        <div className="mx-auto max-w-5xl rounded-3xl border border-rose-200 bg-rose-50 p-6 text-rose-900">
          <h1 className="text-2xl font-semibold">Could not load coding rows</h1>
          <p className="mt-2 text-sm">{codesResult.error?.message || adjustmentsResult.error?.message}</p>
        </div>
      </main>
    );
  }

  const disputes = (disputesResult.data ?? []) as unknown as DisputeRow[];
  const disputeById = keyBy(disputes, (row) => row.id);
  const orderIds = Array.from(new Set(disputes.map((row) => row.order_id).filter(Boolean) as string[]));
  const { data: ordersRaw } = orderIds.length
    ? await supabase.from("orders").select("id, order_ref, importer_id, retailer_id, status").in("id", orderIds)
    : { data: [] as OrderRow[] };

  const orders = (ordersRaw ?? []) as unknown as OrderRow[];
  const orderById = keyBy(orders, (row) => row.id);
  const importerIds = Array.from(new Set(orders.map((row) => row.importer_id).filter(Boolean) as string[]));
  const retailerIds = Array.from(new Set(orders.map((row) => row.retailer_id).filter(Boolean) as string[]));

  const [importersResult, retailersResult] = await Promise.all([
    importerIds.length ? supabase.from("importers").select("id, company_name, trading_name").in("id", importerIds) : { data: [] as ImporterRow[] },
    retailerIds.length ? supabase.from("retailers").select("id, name").in("id", retailerIds) : { data: [] as RetailerRow[] },
  ]);

  const importerById = keyBy((importersResult.data ?? []) as unknown as ImporterRow[], (row) => row.id);
  const retailerById = keyBy((retailersResult.data ?? []) as unknown as RetailerRow[], (row) => row.id);
  const invoiceById = keyBy((invoicesResult.data ?? []) as unknown as SupplierInvoiceRow[], (row) => row.id);
  const linesBySubmissionId = groupBy(lines, (row) => row.refund_evidence_submission_id);
  const codesByLineId = keyBy((codesResult.data ?? []) as unknown as LineCodeRow[], (row) => row.refund_document_line_id);
  const adjustmentsBySubmissionId = groupBy((adjustmentsResult.data ?? []) as unknown as AdjustmentRow[], (row) => row.refund_evidence_submission_id);
  const totalsBySubmissionId = keyBy((totalsResult.data ?? []) as unknown as TotalsRow[], (row) => row.refund_evidence_submission_id);
  const allocations = (allocationsResult.data ?? []) as unknown as AllocationRow[];

  const previews = submissions.map((submission) => {
    const dispute = disputeById.get(submission.dispute_id);
    const order = dispute?.order_id ? orderById.get(dispute.order_id) : undefined;
    const importer = order?.importer_id ? importerById.get(order.importer_id) : undefined;
    const retailer = order?.retailer_id ? retailerById.get(order.retailer_id) : undefined;
    const invoice = submission.original_supplier_invoice_id ? invoiceById.get(submission.original_supplier_invoice_id) : undefined;
    return buildPreview({
      submission,
      dispute,
      order,
      importer,
      retailer,
      invoice,
      lines: linesBySubmissionId.get(submission.id) ?? [],
      codeByLineId: codesByLineId,
      adjustments: adjustmentsBySubmissionId.get(submission.id) ?? [],
      totals: totalsBySubmissionId.get(submission.id),
      allocations,
    });
  });

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-[1500px] flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/status-control/pre-sage-financial-readiness" className="text-sm font-semibold text-sky-700">← Back to pre-Sage readiness</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Payload preview / read only</p>
          <div className="mt-3 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Supplier credit-equivalent payload preview</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Thin preview for the proven refund-proof/no-credit-note path only. This validates the accounting shape from approved refund evidence, coded supplier-credit lines, and confirmed DVA/card refund-IN allocation. It does not post to Sage.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{activeStaff.full_name}</div>
              <div>{activeStaff.role_type}</div>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-lg font-semibold">Filters</h2>
          <div className="mt-3 grid gap-3 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
              <p className="text-xs font-bold uppercase text-slate-500">Submission filter</p>
              <p className="mt-2 font-mono text-xs break-all">{submissionId || "all approved refund-proof submissions"}</p>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
              <p className="text-xs font-bold uppercase text-slate-500">Dispute filter</p>
              <p className="mt-2 font-mono text-xs break-all">{disputeId || "none"}</p>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
              <p className="text-xs font-bold uppercase text-slate-500">Rows</p>
              <p className="mt-2 text-2xl font-semibold">{previews.length}</p>
            </div>
          </div>
        </section>

        {previews.length === 0 ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-6 text-sm text-amber-900">
            No approved refund-proof/no-credit-note submissions are available for this filter.
          </section>
        ) : null}

        {previews.map((preview) => {
          const payload = preview.payload;
          return (
            <section key={payload.source_ids.refund_evidence_submission_id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={`rounded-full border px-3 py-1 text-xs font-bold ${statusClass(preview.ready)}`}>
                      {preview.ready ? "payload shape ready" : "blocked"}
                    </span>
                    <span className="rounded-full border border-slate-200 bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">
                      {payload.document_mode?.replaceAll("_", " ")}
                    </span>
                  </div>
                  <h2 className="mt-3 text-2xl font-semibold">{payload.header.order_ref}</h2>
                  <p className="mt-1 text-sm text-slate-600">
                    {payload.header.retailer_name ?? "Retailer unknown"} · {payload.header.importer_name ?? "Importer unknown"} · Submission {shortId(payload.source_ids.refund_evidence_submission_id)}
                  </p>
                </div>
                <div className="grid gap-3 text-sm md:grid-cols-3 xl:w-[680px]">
                  <div className="rounded-2xl border bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Accepted gross</p><p className="text-xl font-semibold">{gbp(preview.acceptedGross)}</p></div>
                  <div className="rounded-2xl border bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Coded gross</p><p className="text-xl font-semibold">{gbp(preview.codedGross)}</p></div>
                  <div className="rounded-2xl border bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Refund IN allocated</p><p className="text-xl font-semibold">{gbp(preview.refundInAllocated)}</p></div>
                </div>
              </div>

              {preview.blockers.length > 0 ? (
                <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
                  <p className="font-semibold">Blockers</p>
                  <ul className="mt-2 list-disc pl-5">
                    {preview.blockers.map((item) => <li key={item}>{item}</li>)}
                  </ul>
                </div>
              ) : null}

              {preview.warnings.length > 0 ? (
                <div className="mt-4 rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-sky-900">
                  <p className="font-semibold">Warnings</p>
                  <ul className="mt-2 list-disc pl-5">
                    {preview.warnings.map((item) => <li key={item}>{item}</li>)}
                  </ul>
                </div>
              ) : null}

              <div className="mt-5 grid gap-5 xl:grid-cols-[1fr_1.2fr]">
                <div className="rounded-2xl border border-slate-200">
                  <div className="border-b bg-slate-100 px-4 py-3 font-semibold">Supplier credit preview lines</div>
                  <div className="overflow-x-auto">
                    <table className="min-w-full text-left text-sm">
                      <thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Line</th><th className="p-3">Description</th><th className="p-3">Nominal</th><th className="p-3 text-right">Net</th><th className="p-3 text-right">VAT</th><th className="p-3 text-right">Gross</th></tr></thead>
                      <tbody>
                        {payload.lines.map((line) => (
                          <tr key={line.source_refund_document_line_id} className="border-t">
                            <td className="p-3">{line.line_order}</td>
                            <td className="p-3 font-medium">{line.description}</td>
                            <td className="p-3">{line.nominal_code || line.sage_ledger_account_id || "—"}</td>
                            <td className="p-3 text-right">{gbp(line.net_credit_gbp)}</td>
                            <td className="p-3 text-right">{gbp(line.vat_credit_gbp)}</td>
                            <td className="p-3 text-right font-semibold">{gbp(line.gross_credit_gbp)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>

                <div className="rounded-2xl border border-slate-200 bg-slate-950 p-4 text-xs text-slate-100">
                  <div className="mb-3 flex items-center justify-between gap-3">
                    <h3 className="font-semibold text-white">Read-only payload JSON</h3>
                    <span className="rounded-full bg-slate-800 px-2 py-1 text-[11px] text-slate-300">not posted</span>
                  </div>
                  <pre className="max-h-[520px] overflow-auto whitespace-pre-wrap break-words">{JSON.stringify(payload, null, 2)}</pre>
                </div>
              </div>
            </section>
          );
        })}
      </div>
    </main>
  );
}
