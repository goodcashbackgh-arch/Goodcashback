import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;
type Row = Record<string, unknown>;

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

function dateOnly(value: unknown) {
  const raw = text(value);
  return raw ? raw.slice(0, 10) : "";
}

function shortId(value: unknown) {
  return text(value).slice(0, 8);
}

function keyBy(rows: Row[], key: string) {
  const map = new Map<string, Row>();
  for (const row of rows) {
    const value = text(row[key]);
    if (value) map.set(value, row);
  }
  return map;
}

function groupBy(rows: Row[], key: string) {
  const map = new Map<string, Row[]>();
  for (const row of rows) {
    const value = text(row[key]);
    if (!value) continue;
    map.set(value, [...(map.get(value) ?? []), row]);
  }
  return map;
}

function statusClass(ok: boolean) {
  return ok ? "border-emerald-200 bg-emerald-50 text-emerald-800" : "border-amber-200 bg-amber-50 text-amber-900";
}

function confirmedRefundAllocations(allocations: Row[], disputeId: string) {
  return allocations.filter((row) =>
    text(row.dispute_id) === disputeId &&
    text(row.allocation_type) === "retailer_refund" &&
    text(row.allocation_status) === "confirmed"
  );
}

function firstRefundStatementDate(allocations: Row[], disputeId: string) {
  return confirmedRefundAllocations(allocations, disputeId)
    .map((row) => dateOnly(row.statement_date))
    .filter(Boolean)
    .sort()[0] || "";
}

function linePayload(line: Row, code?: Row) {
  return {
    source_refund_document_line_id: text(line.id),
    line_order: num(line.line_order),
    line_source: text(line.line_source) || null,
    description: text(code?.description_override) || text(line.description) || "Supplier credit line",
    sku: text(code?.sku_override) || text(line.retailer_sku) || null,
    size: text(code?.size_override) || text(line.size) || null,
    qty: num(line.qty),
    nominal_code: text(code?.nominal_code) || null,
    sage_ledger_account_id: text(code?.sage_ledger_account_id) || null,
    tax_rate_id: text(code?.tax_rate_id) || null,
    tax_rate_label: text(code?.tax_rate_label) || null,
    vat_rate_percent: num(code?.vat_rate_percent),
    net_credit_gbp: round2(num(code?.net_amount_gbp)),
    vat_credit_gbp: round2(num(code?.vat_amount_gbp)),
    gross_credit_gbp: round2(num(code?.gross_amount_gbp) || num(line.amount_gbp)),
    posting_sign: "credit",
  };
}

function adjustmentPayload(row: Row) {
  return {
    description: text(row.description) || "Supplier credit adjustment",
    sku: text(row.sku) || null,
    size: text(row.size) || null,
    nominal_code: text(row.nominal_code) || null,
    sage_ledger_account_id: text(row.sage_ledger_account_id) || null,
    tax_rate_id: text(row.tax_rate_id) || null,
    tax_rate_label: text(row.tax_rate_label) || null,
    vat_rate_percent: num(row.vat_rate_percent),
    net_credit_gbp: round2(num(row.net_amount_gbp)),
    vat_credit_gbp: round2(num(row.vat_amount_gbp)),
    gross_credit_gbp: round2(num(row.gross_amount_gbp)),
    posting_sign: "credit",
  };
}

function buildPreview(args: {
  submission: Row;
  dispute?: Row;
  order?: Row;
  importer?: Row;
  retailer?: Row;
  invoice?: Row;
  lines: Row[];
  codesByLineId: Map<string, Row>;
  adjustments: Row[];
  totals?: Row;
  allocations: Row[];
}) {
  const { submission, dispute, order, importer, retailer, invoice, lines, codesByLineId, adjustments, totals, allocations } = args;
  const progressedLines = lines.filter((line) => bool(line.progressed_to_supplier_control_yn));
  const codedLines = progressedLines.filter((line) => codesByLineId.has(text(line.id)));
  const acceptedGross = Math.max(
    num(totals?.accepted_document_gross_gbp),
    num(submission.captured_refund_amount_abs_gbp),
    num(submission.expected_exception_amount_abs_gbp),
    num(dispute?.amount_impact_gbp),
  );
  const codedGross = round2(num(totals?.total_coded_gross_gbp));
  const refundInAllocated = round2(confirmedRefundAllocations(allocations, text(submission.dispute_id)).reduce((sum, row) => sum + num(row.allocated_gbp_amount), 0));
  const refundStatementDate = firstRefundStatementDate(allocations, text(submission.dispute_id));

  const blockers: string[] = [];
  const warnings: string[] = [];
  if (text(submission.supplier_approval_status) !== "approved_current") blockers.push("supplier refund evidence is not approved current");
  if (text(submission.supplier_control_status) !== "approved_current") blockers.push("supplier control status is not approved current");
  if (!bool(totals?.gross_reconciled_to_document_yn)) blockers.push("coded gross does not reconcile to accepted refund document gross");
  if (progressedLines.length === 0) blockers.push("no refund document lines released to supplier control");
  if (codedLines.length !== progressedLines.length) blockers.push("not all released refund document lines are coded");
  if (refundInAllocated + 0.01 < acceptedGross) blockers.push("confirmed refund-IN allocation is below accepted refund amount");
  if (!refundStatementDate) warnings.push("No DVA/card refund-IN statement date found; document date is falling back to approval/submission date");

  for (const line of progressedLines) {
    const code = codesByLineId.get(text(line.id));
    if (!text(code?.nominal_code) && !text(code?.sage_ledger_account_id)) warnings.push(`Line ${text(line.line_order)} has no nominal or Sage ledger reference`);
    if (bool(code?.admin_review_required_yn)) warnings.push(`Line ${text(line.line_order)} was marked for admin review`);
  }

  const orderRef = text(order?.order_ref) || shortId(dispute?.order_id) || shortId(submission.id);
  const documentDate = dateOnly(submission.credit_note_date) || refundStatementDate || dateOnly(submission.supplier_approved_at) || dateOnly(submission.submitted_at) || dateOnly(new Date().toISOString());
  const documentDateSource = dateOnly(submission.credit_note_date)
    ? "credit_note_date"
    : refundStatementDate
      ? "dva_refund_in_statement_date"
      : dateOnly(submission.supplier_approved_at)
        ? "supplier_approved_at_fallback"
        : "submitted_at_fallback";

  const payload = {
    preview_version: "supplier_credit_equivalent_preview_v0",
    preview_only_not_posted: true,
    payload_family: "supplier_credit_or_refund_adjustment",
    document_mode: text(submission.document_mode),
    posting_intent: "supplier_credit_equivalent",
    accounting_effect_summary: "Reduce supplier-side cost/creditor position and reverse the coded net/VAT/gross amounts using credit-note-equivalent treatment. Exact Sage object mapping remains for the final Sage adapter.",
    source_ids: {
      refund_evidence_submission_id: text(submission.id),
      dispute_id: text(submission.dispute_id),
      order_id: text(order?.id) || text(dispute?.order_id) || null,
      original_supplier_invoice_id: text(submission.original_supplier_invoice_id) || null,
    },
    header: {
      document_reference: text(submission.credit_note_ref) || `REFUND-${orderRef}-${shortId(submission.id)}`,
      document_date: documentDate,
      document_date_source: documentDateSource,
      currency: "GBP",
      order_ref: orderRef,
      importer_name: text(importer?.trading_name) || text(importer?.company_name) || null,
      retailer_name: text(retailer?.name) || null,
      original_supplier_invoice_ref: text(invoice?.invoice_ref) || null,
      gross_credit_gbp: round2(acceptedGross),
      refund_in_allocated_gbp: refundInAllocated,
    },
    lines: progressedLines.map((line) => linePayload(line, codesByLineId.get(text(line.id)))),
    adjustments: adjustments.map(adjustmentPayload),
    controls: {
      supplier_approval_status: text(submission.supplier_approval_status),
      supplier_control_status: text(submission.supplier_control_status),
      match_status: text(submission.match_status),
      amount_balance_status: text(submission.amount_balance_status),
      accepted_gross_gbp: round2(acceptedGross),
      coded_gross_gbp: codedGross,
      gross_variance_gbp: round2(num(totals?.gross_variance_gbp ?? codedGross - acceptedGross)),
      all_released_lines_coded: codedLines.length === progressedLines.length && progressedLines.length > 0,
      refund_in_allocation_covers_approved_amount: refundInAllocated + 0.01 >= acceptedGross,
    },
    evidence: {
      refund_proof_file_url: text(submission.refund_proof_file_url) || null,
      credit_note_file_url: text(submission.credit_note_file_url) || null,
    },
  };

  return { ready: blockers.length === 0, blockers, warnings, payload, acceptedGross, codedGross, refundInAllocated };
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

  if (!staff || !["admin", "supervisor"].includes(text(staff.role_type))) redirect("/internal");

  let submissionQuery = supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, original_order_id, original_supplier_invoice_id, submitted_at, document_mode, credit_note_ref, credit_note_date, credit_note_file_url, refund_proof_file_url, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, variance_abs_gbp, amount_balance_status, supplier_approval_status, supplier_control_status, supplier_approved_at, match_status")
    .in("document_mode", ["credit_note", "refund_proof_no_credit_note", "no_document"])
    .eq("supplier_approval_status", "approved_current")
    .eq("supplier_control_status", "approved_current")
    .order("supplier_approved_at", { ascending: false })
    .limit(25);

  if (submissionId) submissionQuery = submissionQuery.eq("id", submissionId);
  if (disputeId) submissionQuery = submissionQuery.eq("dispute_id", disputeId);

  const { data: submissionsData, error: submissionsError } = await submissionQuery;
  if (submissionsError) {
    return <ErrorPanel title="Could not load supplier credit preview" message={submissionsError.message} />;
  }

  const submissions = (submissionsData ?? []) as Row[];
  const submissionIds = submissions.map((row) => text(row.id));
  const disputeIds = Array.from(new Set(submissions.map((row) => text(row.dispute_id)).filter(Boolean)));
  const originalInvoiceIds = Array.from(new Set(submissions.map((row) => text(row.original_supplier_invoice_id)).filter(Boolean)));

  const [linesResult, totalsResult, disputesResult, invoicesResult, allocationsResult] = await Promise.all([
    submissionIds.length
      ? supabase.from("dispute_refund_document_lines").select("id, refund_evidence_submission_id, line_order, line_source, description, retailer_sku, size, qty, amount_gbp, progressed_to_supplier_control_yn").in("refund_evidence_submission_id", submissionIds).order("line_order", { ascending: true })
      : { data: [] as Row[], error: null },
    submissionIds.length
      ? supabase.from("dispute_refund_document_accounting_totals_vw").select("refund_evidence_submission_id, accepted_document_gross_gbp, total_coded_net_gbp, total_coded_vat_gbp, total_coded_gross_gbp, adjustment_gross_gbp, progressed_line_count, coded_line_count, all_progressed_lines_coded_yn, gross_reconciled_to_document_yn, gross_variance_gbp").in("refund_evidence_submission_id", submissionIds)
      : { data: [] as Row[], error: null },
    disputeIds.length
      ? supabase.from("disputes").select("id, order_id, desired_outcome, status, amount_impact_gbp").in("id", disputeIds)
      : { data: [] as Row[], error: null },
    originalInvoiceIds.length
      ? supabase.from("supplier_invoices").select("id, invoice_ref, invoice_pdf_url, review_status, retailer_id").in("id", originalInvoiceIds)
      : { data: [] as Row[], error: null },
    disputeIds.length
      ? supabase.from("dva_statement_line_allocation_detail_vw").select("dispute_id, allocation_type, allocation_status, allocated_gbp_amount, statement_date").in("dispute_id", disputeIds)
      : { data: [] as Row[], error: null },
  ]);

  const firstError = linesResult.error || totalsResult.error || disputesResult.error || invoicesResult.error || allocationsResult.error;
  if (firstError) return <ErrorPanel title="Could not load preview detail rows" message={firstError.message} />;

  const lines = ((linesResult.data ?? []) as Row[]);
  const lineIds = lines.map((line) => text(line.id));
  const [codesResult, adjustmentsResult] = await Promise.all([
    lineIds.length
      ? supabase.from("dispute_refund_document_line_accounting_codes").select("refund_document_line_id, description_override, sku_override, size_override, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp, admin_review_required_yn, review_reason").in("refund_document_line_id", lineIds)
      : { data: [] as Row[], error: null },
    submissionIds.length
      ? supabase.from("dispute_refund_document_accounting_adjustment_lines").select("refund_evidence_submission_id, description, sku, size, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp").in("refund_evidence_submission_id", submissionIds)
      : { data: [] as Row[], error: null },
  ]);

  if (codesResult.error || adjustmentsResult.error) {
    return <ErrorPanel title="Could not load coding rows" message={codesResult.error?.message || adjustmentsResult.error?.message || "Unknown coding error"} />;
  }

  const disputes = (disputesResult.data ?? []) as Row[];
  const disputeById = keyBy(disputes, "id");
  const orderIds = Array.from(new Set(disputes.map((row) => text(row.order_id)).filter(Boolean)));
  const { data: ordersData } = orderIds.length
    ? await supabase.from("orders").select("id, order_ref, importer_id, retailer_id, status").in("id", orderIds)
    : { data: [] as Row[] };

  const orders = (ordersData ?? []) as Row[];
  const orderById = keyBy(orders, "id");
  const importerIds = Array.from(new Set(orders.map((row) => text(row.importer_id)).filter(Boolean)));
  const retailerIds = Array.from(new Set(orders.map((row) => text(row.retailer_id)).filter(Boolean)));
  const [importersResult, retailersResult] = await Promise.all([
    importerIds.length ? supabase.from("importers").select("id, company_name, trading_name").in("id", importerIds) : { data: [] as Row[] },
    retailerIds.length ? supabase.from("retailers").select("id, name").in("id", retailerIds) : { data: [] as Row[] },
  ]);

  const importerById = keyBy((importersResult.data ?? []) as Row[], "id");
  const retailerById = keyBy((retailersResult.data ?? []) as Row[], "id");
  const invoiceById = keyBy((invoicesResult.data ?? []) as Row[], "id");
  const linesBySubmissionId = groupBy(lines, "refund_evidence_submission_id");
  const codesByLineId = keyBy((codesResult.data ?? []) as Row[], "refund_document_line_id");
  const adjustmentsBySubmissionId = groupBy((adjustmentsResult.data ?? []) as Row[], "refund_evidence_submission_id");
  const totalsBySubmissionId = keyBy((totalsResult.data ?? []) as Row[], "refund_evidence_submission_id");
  const allocations = (allocationsResult.data ?? []) as Row[];

  const previews = submissions.map((submission) => {
    const dispute = disputeById.get(text(submission.dispute_id));
    const order = dispute ? orderById.get(text(dispute.order_id)) : undefined;
    const importer = order ? importerById.get(text(order.importer_id)) : undefined;
    const retailer = order ? retailerById.get(text(order.retailer_id)) : undefined;
    const invoice = invoiceById.get(text(submission.original_supplier_invoice_id));
    return buildPreview({
      submission,
      dispute,
      order,
      importer,
      retailer,
      invoice,
      lines: linesBySubmissionId.get(text(submission.id)) ?? [],
      codesByLineId,
      adjustments: adjustmentsBySubmissionId.get(text(submission.id)) ?? [],
      totals: totalsBySubmissionId.get(text(submission.id)),
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
                Preview for approved refund-document submissions: credit notes, refund proof without credit note, and approved no-document refund adjustments. This validates coded supplier-credit lines and confirmed DVA/card refund-IN allocation. It does not post to Sage.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name)}</div>
              <div>{text(staff.role_type)}</div>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-lg font-semibold">Filters</h2>
          <div className="mt-3 grid gap-3 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm"><p className="text-xs font-bold uppercase text-slate-500">Submission filter</p><p className="mt-2 font-mono text-xs break-all">{submissionId || "all approved refund-document submissions"}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm"><p className="text-xs font-bold uppercase text-slate-500">Dispute filter</p><p className="mt-2 font-mono text-xs break-all">{disputeId || "none"}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm"><p className="text-xs font-bold uppercase text-slate-500">Rows</p><p className="mt-2 text-2xl font-semibold">{previews.length}</p></div>
          </div>
        </section>

        {previews.length === 0 ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-6 text-sm text-amber-900">No approved refund-document submissions are available for this filter.</section>
        ) : null}

        {previews.map((preview) => {
          const payload = preview.payload;
          return (
            <section key={payload.source_ids.refund_evidence_submission_id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={`rounded-full border px-3 py-1 text-xs font-bold ${statusClass(preview.ready)}`}>{preview.ready ? "payload shape ready" : "blocked"}</span>
                    <span className="rounded-full border border-slate-200 bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{text(payload.document_mode).replaceAll("_", " ")}</span>
                  </div>
                  <h2 className="mt-3 text-2xl font-semibold">{payload.header.order_ref}</h2>
                  <p className="mt-1 text-sm text-slate-600">{payload.header.retailer_name ?? "Retailer unknown"} · {payload.header.importer_name ?? "Importer unknown"} · Submission {shortId(payload.source_ids.refund_evidence_submission_id)}</p>
                </div>
                <div className="grid gap-3 text-sm md:grid-cols-3 xl:w-[680px]">
                  <div className="rounded-2xl border bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Accepted gross</p><p className="text-xl font-semibold">{gbp(preview.acceptedGross)}</p></div>
                  <div className="rounded-2xl border bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Coded gross</p><p className="text-xl font-semibold">{gbp(preview.codedGross)}</p></div>
                  <div className="rounded-2xl border bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Refund IN allocated</p><p className="text-xl font-semibold">{gbp(preview.refundInAllocated)}</p></div>
                </div>
              </div>

              {preview.blockers.length > 0 ? <Notice title="Blockers" items={preview.blockers} tone="amber" /> : null}
              {preview.warnings.length > 0 ? <Notice title="Warnings" items={preview.warnings} tone="sky" /> : null}

              <div className="mt-5 grid gap-5 xl:grid-cols-[1fr_1.2fr]">
                <div className="rounded-2xl border border-slate-200">
                  <div className="border-b bg-slate-100 px-4 py-3 font-semibold">Supplier credit preview lines</div>
                  <div className="overflow-x-auto">
                    <table className="min-w-full text-left text-sm">
                      <thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Line</th><th className="p-3">Description</th><th className="p-3">SKU</th><th className="p-3">Size</th><th className="p-3 text-right">Qty</th><th className="p-3">Nominal</th><th className="p-3 text-right">Net</th><th className="p-3 text-right">VAT</th><th className="p-3 text-right">Gross</th></tr></thead>
                      <tbody>
                        {payload.lines.map((line) => (
                          <tr key={line.source_refund_document_line_id} className="border-t">
                            <td className="p-3">{line.line_order}</td>
                            <td className="p-3 font-medium">{line.description}</td>
                            <td className="p-3">{line.sku || "—"}</td>
                            <td className="p-3">{line.size || "—"}</td>
                            <td className="p-3 text-right">{line.qty || "—"}</td>
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
                  <div className="mb-3 flex items-center justify-between gap-3"><h3 className="font-semibold text-white">Read-only payload JSON</h3><span className="rounded-full bg-slate-800 px-2 py-1 text-[11px] text-slate-300">not posted</span></div>
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

function Notice({ title, items, tone }: { title: string; items: string[]; tone: "amber" | "sky" }) {
  const classes = tone === "amber" ? "border-amber-200 bg-amber-50 text-amber-900" : "border-sky-200 bg-sky-50 text-sky-900";
  return (
    <div className={`mt-4 rounded-2xl border p-4 text-sm ${classes}`}>
      <p className="font-semibold">{title}</p>
      <ul className="mt-2 list-disc pl-5">{items.map((item) => <li key={item}>{item}</li>)}</ul>
    </div>
  );
}

function ErrorPanel({ title, message }: { title: string; message: string }) {
  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-5xl rounded-3xl border border-rose-200 bg-rose-50 p-6 text-rose-900">
        <h1 className="text-2xl font-semibold">{title}</h1>
        <p className="mt-2 text-sm">{message}</p>
      </div>
    </main>
  );
}
