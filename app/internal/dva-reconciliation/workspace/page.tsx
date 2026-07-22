import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { allocateStatementLineToSupplierInvoiceAction } from "../actions";
import { allocateStatementLineToFinalBalancePaymentAction } from "../finalBalanceActions";

type Row = Record<string, unknown>;
type OperationalKind = "invoice" | "exception" | "final_balance";
type OperationalRow = {
  kind: OperationalKind;
  id: string;
  title: string;
  retailerName: string;
  orderRef: string;
  orderId: string;
  status: string;
  amount: number;
  progressedTotal: number;
  openExceptionTotal: number;
  raw: Row;
};
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
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

function byId(rows: Row[]) {
  const mapped = new Map<string, Row>();
  for (const row of rows) {
    const id = text(row.id);
    if (id) mapped.set(id, row);
  }
  return mapped;
}

function groupBy(rows: Row[], key: string) {
  const grouped = new Map<string, Row[]>();
  for (const row of rows) {
    const id = text(row[key]);
    if (!id) continue;
    grouped.set(id, [...(grouped.get(id) ?? []), row]);
  }
  return grouped;
}

function isFundingConfirmedLine(row: Row) {
  return (
    text(row.match_status) === "confirmed" &&
    !bool(row.confirmed_balanced_yn) &&
    num(row.confirmed_allocated_gbp) <= 0 &&
    num(row.open_allocated_gbp) <= 0
  );
}

function statusFilter(row: Row) {
  if (bool(row.confirmed_balanced_yn)) return "balanced";
  if (num(row.confirmed_allocated_gbp) > 0 || num(row.open_allocated_gbp) > 0) return "part";
  if (isFundingConfirmedLine(row)) return "funding confirmed";
  return "unmatched";
}

function lineTone(row: Row, selectedLineId: string) {
  if (isFundingConfirmedLine(row)) return "border-emerald-300 bg-emerald-50 ring-1 ring-emerald-200";
  if (text(row.dva_statement_line_id) === selectedLineId) return "border-sky-500 bg-sky-50 ring-2 ring-sky-200";
  if (bool(row.confirmed_balanced_yn)) return "border-emerald-200 bg-emerald-50";
  if (num(row.confirmed_allocated_gbp) > 0 || num(row.open_allocated_gbp) > 0) return "border-amber-200 bg-amber-50";
  return "border-slate-200 bg-white";
}

function statusBadgeTone(status: string) {
  if (status === "funding confirmed") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  return "bg-white text-slate-700 ring-slate-200";
}

function opTone(row: OperationalRow, selectedTargetId: string) {
  return row.id === selectedTargetId ? "border-sky-500 bg-sky-50 ring-2 ring-sky-200" : "border-slate-200 bg-white";
}

function workspaceHref(params: Record<string, string>) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value) query.set(key, value);
  }
  return `/internal/dva-reconciliation/workspace?${query.toString()}`;
}

function containsNeedle(value: unknown, needle: string) {
  if (!needle) return true;
  return text(value).toLowerCase().includes(needle.toLowerCase());
}

function compactSearch(value: unknown) {
  return text(value)
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function merchantTokens(...values: unknown[]) {
  const stop = new Set(["bank", "card", "from", "transfer", "wallet", "statement", "goods", "sales", "leeds", "london", "internet", "europe", "kitchen"]);
  const tokens = new Set<string>();
  for (const value of values) {
    for (const token of compactSearch(value).split(/\s+/)) {
      if (token.length < 4 || /^\d+$/.test(token) || stop.has(token)) continue;
      tokens.add(token);
      if (token === "sharkninja" || token === "shark") tokens.add("ninja");
      if (token === "hennes" || token === "mauritz") tokens.add("hm");
    }
  }
  return [...tokens].slice(0, 6);
}

function merchantScore(row: OperationalRow, tokens: string[]) {
  if (tokens.length === 0) return 0;
  const haystack = compactSearch(`${row.retailerName} ${row.title} ${row.orderRef}`);
  return tokens.reduce((score, token) => score + (haystack.includes(token) ? 1 : 0), 0);
}

function amountScore(statementAmount: number, row: OperationalRow) {
  const targetAmount = row.amount || row.progressedTotal || row.openExceptionTotal;
  if (statementAmount <= 0 || targetAmount <= 0) return 0;
  const diff = Math.abs(statementAmount - targetAmount);
  if (diff < 0.01) return 100;
  if (diff <= 2) return 75;
  if (diff <= 5) return 50;
  if (diff <= 15) return 25;
  return 0;
}

function metric(label: string, value: string, hint: string) {
  return (
    <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</p>
      <p className="mt-2 text-2xl font-semibold text-slate-950">{value}</p>
      <p className="mt-1 text-xs leading-5 text-slate-500">{hint}</p>
    </div>
  );
}

function importerLabel(importer?: Row) {
  return text(importer?.trading_name) || text(importer?.company_name) || text(importer?.id) || "No importer selected";
}

function isUsefulOperationalCandidate(row: OperationalRow) {
  if (row.kind === "final_balance") return row.amount > 0 && row.status === "balance_due";
  if (row.kind === "exception") return row.openExceptionTotal > 0 && row.status !== "resolved" && row.status !== "closed";
  return bool(row.raw.selectable_yn);
}

function targetKindLabel(kind: OperationalKind) {
  if (kind === "invoice") return "Invoice";
  if (kind === "exception") return "Exception";
  return "Final balance payment";
}

export default async function DvaMatchingWorkspacePage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const requestedImporterId = firstParam(params.importer_id);
  const selectedLineId = firstParam(params.line_id);
  const selectedTargetId = firstParam(params.target_id);
  const leftStatus = firstParam(params.left_status) || "unmatched";
  const leftDirection = firstParam(params.left_direction) || "all";
  const leftRetailer = firstParam(params.left_retailer);
  const manualRightRetailer = firstParam(params.right_retailer);
  const rightStatus = firstParam(params.right_status) || "usable";

  const supabase = await createClient();
  const [
    statementLinesResult,
    importersResult,
    ordersResult,
    retailersResult,
    supplierCandidatesResult,
    disputesResult,
    suggestionsResult,
    creditLedgerResult,
  ] = await Promise.all([
    supabase
      .from("dva_statement_line_allocation_summary_vw")
      .select("dva_statement_line_id, dva_statement_id, importer_id, statement_date, reference_raw, direction, amount_local_ccy, local_ccy, fx_rate_applied, card_markup_pct_applied, statement_gbp_amount, auth_id_ref, retailer_name_ref, match_status, confirmed_allocated_gbp, open_allocated_gbp, supplier_invoice_allocated_gbp, retailer_refund_allocated_gbp, fx_card_or_fee_allocated_gbp, exception_or_hold_allocated_gbp, active_allocation_count, confirmed_unallocated_gbp, confirmed_balanced_yn")
      .order("statement_date", { ascending: false })
      .limit(300),
    supabase.from("importers").select("id, company_name, trading_name, gcb_dva_ref, dva_card_last_4").limit(200),
    supabase.from("orders").select("id, order_ref, importer_id, retailer_id, order_total_gbp_declared, status, payment_auth_id, order_type, created_at").order("created_at", { ascending: false }).limit(500),
    supabase.from("retailers").select("id, name").limit(500),
    supabase
      .from("supplier_payment_candidate_status_vw")
      .select("supplier_invoice_id, order_id, order_ref, importer_id, retailer_id, order_type, invoice_ref, review_status, invoice_total_gbp, confirmed_matched_gbp, remaining_unmatched_gbp, funding_required_yn, threshold_met_yn, funding_provenance_ready_yn, supplier_payment_ready_yn, blocker, selectable_yn")
      .order("order_ref", { ascending: false })
      .limit(500),
    supabase.from("disputes").select("id, order_id, desired_outcome, status, amount_impact_gbp, resolved_at, raised_at").order("raised_at", { ascending: false }).limit(500),
    supabase.from("match_suggestions").select("id, dva_statement_line_id, suggested_match_type, suggested_match_id, confidence, variance_gbp, variance_days").limit(500),
    supabase.from("importer_credit_ledger").select("id, importer_id, entry_type, direction, amount_gbp, lock_reason").limit(500),
  ]);

  const allStatementLines = (statementLinesResult.data ?? []) as unknown as Row[];
  const importers = (importersResult.data ?? []) as unknown as Row[];
  const importersById = byId(importers);
  const fallbackImporterId = requestedImporterId || text(allStatementLines[0]?.importer_id) || text(importers[0]?.id);
  const selectedImporterId = fallbackImporterId;
  const statementLines = allStatementLines.filter((row) => !selectedImporterId || text(row.importer_id) === selectedImporterId);
  const orders = ((ordersResult.data ?? []) as unknown as Row[]).filter((row) => !selectedImporterId || text(row.importer_id) === selectedImporterId);
  const orderIds = new Set(orders.map((row) => text(row.id)).filter(Boolean));
  const retailersById = byId((retailersResult.data ?? []) as unknown as Row[]);
  const supplierCandidates = ((supplierCandidatesResult.data ?? []) as unknown as Row[]).filter((row) => orderIds.has(text(row.order_id)));
  const disputes = ((disputesResult.data ?? []) as unknown as Row[]).filter((row) => orderIds.has(text(row.order_id)));
  const suggestionsByLineId = groupBy((suggestionsResult.data ?? []) as unknown as Row[], "dva_statement_line_id");
  const creditLedger = ((creditLedgerResult.data ?? []) as unknown as Row[]).filter((row) => !selectedImporterId || text(row.importer_id) === selectedImporterId);
  const filteredStatementLines = statementLines.filter((row) => {
    const statusOk = leftStatus === "all" || statusFilter(row) === leftStatus;
    const directionOk = leftDirection === "all" || text(row.direction) === leftDirection;
    const retailerOk = containsNeedle(row.retailer_name_ref, leftRetailer) || containsNeedle(row.reference_raw, leftRetailer);
    return statusOk && directionOk && retailerOk;
  });

  const selectedLineFromUrl = statementLines.find((row) => text(row.dva_statement_line_id) === selectedLineId);
  const selectedLineIsVisible =
    !!selectedLineFromUrl &&
    filteredStatementLines.some((row) => text(row.dva_statement_line_id) === selectedLineId);

  const selectedLine = selectedLineIsVisible
    ? selectedLineFromUrl
    : filteredStatementLines[0] ?? statementLines[0];

  const activeLineId = text(selectedLine?.dva_statement_line_id);
  const urlLineStillActive = !!selectedLineId && selectedLineId === activeLineId;
  const activeSelectedTargetId = urlLineStillActive ? selectedTargetId : "";
  const activeManualRightRetailer = urlLineStillActive ? manualRightRetailer : "";

  const selectedImporter = selectedImporterId ? importersById.get(selectedImporterId) : undefined;
  const selectedLineSuggestions = suggestionsByLineId.get(activeLineId) ?? [];
  const selectedStatementAmount = num(selectedLine?.statement_gbp_amount);
  const selectedStatementAllocated = num(selectedLine?.confirmed_allocated_gbp);
  const selectedStatementRemaining = Math.max(0, selectedStatementAmount - selectedStatementAllocated);
  const selectedMerchantTokens = merchantTokens(selectedLine?.retailer_name_ref, selectedLine?.reference_raw);
  const rightRetailer = activeManualRightRetailer || leftRetailer;

  const settlementV2Result = await supabase.rpc("internal_order_final_sale_settlement_v2", { p_order_id: null });
  const settlementRows = ((settlementV2Result.data ?? []) as unknown as Row[]).filter((row) => !selectedImporterId || text(row.importer_id) === selectedImporterId);

  const invoiceRows: OperationalRow[] = supplierCandidates.map((candidate) => {
    const order = orders.find((row) => text(row.id) === text(candidate.order_id));
    const retailer = retailersById.get(text(candidate.retailer_id)) || (order ? retailersById.get(text(order.retailer_id)) : undefined);
    const openExceptionTotal = disputes
      .filter((dispute) => text(dispute.order_id) === text(candidate.order_id) && !text(dispute.resolved_at))
      .reduce((sum, dispute) => sum + num(dispute.amount_impact_gbp), 0);

    return {
      kind: "invoice",
      id: text(candidate.supplier_invoice_id),
      title: text(candidate.invoice_ref) || "Supplier invoice",
      retailerName: text(retailer?.name),
      orderRef: text(candidate.order_ref) || text(order?.order_ref),
      orderId: text(candidate.order_id),
      status: text(candidate.review_status),
      amount: num(candidate.invoice_total_gbp),
      progressedTotal: num(candidate.confirmed_matched_gbp),
      openExceptionTotal,
      raw: candidate,
    };
  });

  const exceptionRows: OperationalRow[] = disputes.map((dispute) => {
    const order = orders.find((row) => text(row.id) === text(dispute.order_id));
    const retailer = order ? retailersById.get(text(order.retailer_id)) : undefined;
    return {
      kind: "exception",
      id: text(dispute.id),
      title: `${text(dispute.desired_outcome) || "Exception"} · ${text(dispute.status)}`,
      retailerName: text(retailer?.name),
      orderRef: text(order?.order_ref),
      orderId: text(order?.id),
      status: text(dispute.status),
      amount: num(dispute.amount_impact_gbp),
      progressedTotal: 0,
      openExceptionTotal: num(dispute.amount_impact_gbp),
      raw: dispute,
    };
  });

  const finalBalanceRows: OperationalRow[] = settlementRows
    .filter((row) => num(row.final_balance_due_gbp) > 0.01 && bool(row.final_sale_value_exists))
    .map((row) => ({
      kind: "final_balance",
      id: `final-balance-${text(row.order_id)}`,
      title: `Final balance payment · ${text(row.order_ref)}`,
      retailerName: "Final sale settlement",
      orderRef: text(row.order_ref),
      orderId: text(row.order_id),
      status: "balance_due",
      amount: num(row.final_balance_due_gbp),
      progressedTotal: num(row.amount_received_gbp),
      openExceptionTotal: 0,
      raw: row,
    }));

  const allOperationalRows = [...finalBalanceRows, ...invoiceRows, ...exceptionRows];
  const hasAutoMerchantMatches = !rightRetailer && selectedMerchantTokens.length > 0 && allOperationalRows.some((row) => merchantScore(row, selectedMerchantTokens) > 0);
  const operationalRows = allOperationalRows
    .filter((row) => {
      const manualRetailerOk = !rightRetailer || row.retailerName.toLowerCase().includes(rightRetailer.toLowerCase()) || row.title.toLowerCase().includes(rightRetailer.toLowerCase()) || row.orderRef.toLowerCase().includes(rightRetailer.toLowerCase());
      const autoRetailerOk = row.kind === "final_balance" || !hasAutoMerchantMatches || merchantScore(row, selectedMerchantTokens) > 0;
      const statusOk =
        rightStatus === "all" ||
        (rightStatus === "usable" ? isUsefulOperationalCandidate(row) : rightStatus === "open" ? row.status !== "resolved" && row.status !== "closed" : row.status === rightStatus);
      return manualRetailerOk && autoRetailerOk && statusOk;
    })
    .sort((a, b) => {
      if (a.kind === "final_balance" && b.kind !== "final_balance") return -1;
      if (b.kind === "final_balance" && a.kind !== "final_balance") return 1;
      const merchantDelta = merchantScore(b, selectedMerchantTokens) - merchantScore(a, selectedMerchantTokens);
      if (merchantDelta !== 0) return merchantDelta;
      const amountDelta = amountScore(selectedStatementAmount, b) - amountScore(selectedStatementAmount, a);
      if (amountDelta !== 0) return amountDelta;
      return Number(isUsefulOperationalCandidate(b)) - Number(isUsefulOperationalCandidate(a)) || b.amount - a.amount;
    });

  const selectedTarget = operationalRows.find((row) => row.id === activeSelectedTargetId && (row.kind !== "invoice" || bool(row.raw.selectable_yn)));
  const selectedTargetAmount = selectedTarget ? selectedTarget.amount || selectedTarget.progressedTotal || selectedTarget.openExceptionTotal : 0;
  const selectedTargetIsSupplierInvoice = selectedTarget?.kind === "invoice";
  const selectedSupplierRemaining = selectedTargetIsSupplierInvoice ? num(selectedTarget.raw.remaining_unmatched_gbp) : 0;
  const supplierAllocationBlocker = (() => {
    if (!selectedTargetIsSupplierInvoice) return "Select a supplier invoice target before supplier allocation.";
    if (text(selectedLine?.direction) !== "out") return "Supplier invoice allocation requires an OUT statement line.";
    if (!bool(selectedTarget.raw.selectable_yn)) return text(selectedTarget.raw.blocker) || "Supplier invoice candidate is not selectable.";
    if (selectedStatementRemaining <= 0) return "Statement line has no remaining balance.";
    if (selectedSupplierRemaining <= 0) return "Supplier invoice has no remaining unmatched balance.";
    return "";
  })();
  const canApplySupplierInvoice = selectedTargetIsSupplierInvoice && !supplierAllocationBlocker;
  const suggestedAllocation = selectedTargetIsSupplierInvoice
    ? (canApplySupplierInvoice ? Math.min(selectedStatementRemaining, selectedSupplierRemaining) : 0)
    : selectedTarget
      ? Math.min(selectedStatementRemaining, selectedTargetAmount || selectedStatementRemaining)
      : 0;
  const remainingAfterSelection = Math.max(0, selectedStatementRemaining - suggestedAllocation);
  const selectedTargetIsFinalBalance = selectedTarget?.kind === "final_balance";
  const finalBalanceFxExcess = selectedTargetIsFinalBalance ? Math.max(0, selectedStatementRemaining - selectedTargetAmount) : 0;
  const finalBalanceAfterSelection = selectedTargetIsFinalBalance ? Math.max(0, selectedTargetAmount - selectedStatementRemaining) : 0;
  const canApplyFinalBalance = selectedTargetIsFinalBalance && text(selectedLine?.direction) === "in" && selectedStatementRemaining > 0 && selectedTargetAmount > 0;
  const activeReturnPath = workspaceHref({
    importer_id: selectedImporterId,
    line_id: activeLineId,
    target_id: activeSelectedTargetId,
    left_status: leftStatus,
    left_direction: leftDirection,
    left_retailer: leftRetailer,
    right_retailer: activeManualRightRetailer,
    right_status: rightStatus,
  });

  const inTotal = statementLines.filter((row) => text(row.direction) === "in").reduce((sum, row) => sum + num(row.statement_gbp_amount), 0);
  const outTotal = statementLines.filter((row) => text(row.direction) === "out").reduce((sum, row) => sum + num(row.statement_gbp_amount), 0);
  const unmatchedCount = statementLines.filter((row) => statusFilter(row) === "unmatched").length;
  const creditBalance = creditLedger.reduce((sum, row) => {
    const direction = text(row.direction).toLowerCase();
    const entryType = text(row.entry_type).toLowerCase();
    const amount = num(row.amount_gbp);
    return direction === "debit" || direction === "out" || entryType.includes("applied") ? sum - amount : sum + amount;
  }, 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6 pb-36">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={selectedImporterId ? `/internal/dva-reconciliation?importer_id=${selectedImporterId}&status=needs` : "/internal/dva-reconciliation"} className="text-sm font-semibold text-sky-600">← Back to control hub</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">DVA/card matching workspace</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Two-pane importer matching cockpit</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            Supervisor allocation workspace for committed DVA/card statement lines. Pick a statement line on the left and the operational target on the right, then use the controlled action bar to allocate supplier purchases, retailer refunds, exception holds, final-balance payments, FX/card residuals, or bank fees. Accepted-estimate IN funding stays in Importer Funding Control.
          </p>
          <form action="/internal/dva-reconciliation/workspace" className="mt-5 flex flex-wrap items-end gap-3">
            <div className="min-w-64 flex-1">
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Importer</label>
              <select name="importer_id" defaultValue={selectedImporterId} className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm">
                {importers.map((importer) => (
                  <option key={text(importer.id)} value={text(importer.id)}>{importerLabel(importer)}</option>
                ))}
              </select>
            </div>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Open importer workspace</button>
          </form>
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {metric("Importer", importerLabel(selectedImporter), "Workspace is now importer-scoped by default.")}
          {metric("IN / OUT", `${gbp(inTotal)} / ${gbp(outTotal)}`, "Committed statement movement visible in this workspace.")}
          {metric("Final balance targets", String(finalBalanceRows.length), "Open final-sale balances available in the right pane.")}
          {metric("Unmatched lines", String(unmatchedCount), "Statement lines still needing funding or allocation route.")}
        </section>

        {hasAutoMerchantMatches ? (
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-950">
            <p className="font-semibold">Auto-filtering right pane using selected statement merchant</p>
            <p className="mt-1">Merchant hints: {selectedMerchantTokens.join(", ")}. Use the right filter to override.</p>
          </section>
        ) : null}

        {selectedLineSuggestions.length > 0 ? (
          <section className="rounded-3xl border border-sky-200 bg-sky-50 p-4 text-sm text-sky-950">
            <p className="font-semibold">Automation signal for selected statement line</p>
            <p className="mt-1">{selectedLineSuggestions.length} suggestion(s) exist. Use the filters to verify before confirming allocation through the controlled action bar.</p>
          </section>
        ) : null}

        {settlementV2Result.error ? (
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950">
            <p className="font-semibold">Final-balance cards are waiting for the settlement v2 migration.</p>
            <p className="mt-1">{settlementV2Result.error.message}</p>
          </section>
        ) : null}

        <section className="grid gap-4 lg:grid-cols-2">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm lg:max-h-[72vh] lg:overflow-y-auto">
            <div className="sticky top-0 z-10 -mx-4 -mt-4 border-b border-slate-200 bg-white/95 p-4 backdrop-blur">
              <h2 className="text-lg font-semibold">Statement lines</h2>
              <form className="mt-3 grid gap-2 sm:grid-cols-2" action="/internal/dva-reconciliation/workspace">
                <input type="hidden" name="importer_id" value={selectedImporterId} />
                <input type="hidden" name="line_id" value={activeLineId} />
                <input type="hidden" name="target_id" value={activeSelectedTargetId} />
                <input type="hidden" name="right_retailer" value={activeManualRightRetailer} />
                <input type="hidden" name="right_status" value={rightStatus} />
                <select name="left_status" defaultValue={leftStatus} className="rounded-xl border border-slate-200 px-3 py-2 text-sm">
                  <option value="unmatched">Unmatched</option>
                  <option value="part">Part allocated</option>
                  <option value="balanced">Matched / balanced</option>
                  <option value="all">All</option>
                </select>
                <select name="left_direction" defaultValue={leftDirection} className="rounded-xl border border-slate-200 px-3 py-2 text-sm">
                  <option value="all">IN + OUT</option>
                  <option value="in">IN only</option>
                  <option value="out">OUT only</option>
                </select>
                <input name="left_retailer" defaultValue={leftRetailer} placeholder="Merchant/ref filter, e.g. Ninja" className="rounded-xl border border-slate-200 px-3 py-2 text-sm sm:col-span-2" />
                <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white sm:col-span-2" type="submit">Apply left filters</button>
              </form>
            </div>

            <div className="mt-4 space-y-3">
              {filteredStatementLines.length === 0 ? <p className="text-sm text-slate-500">No statement lines match the current filters.</p> : null}
              {filteredStatementLines.map((row) => {
  const rowLineId = text(row.dva_statement_line_id);
  const isActiveStatementLine = rowLineId === activeLineId;
  const status = statusFilter(row);

  return (
    <Link
      key={rowLineId}
      href={workspaceHref({
        importer_id: selectedImporterId,
        line_id: rowLineId,
        target_id: isActiveStatementLine ? activeSelectedTargetId : "",
        left_status: leftStatus,
        left_direction: leftDirection,
        left_retailer: leftRetailer,
        right_retailer: isActiveStatementLine ? activeManualRightRetailer : "",
        right_status: rightStatus,
      })}
                    className={`block rounded-2xl border p-4 ${lineTone(row, activeLineId)}`}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="font-semibold">{text(row.statement_date)} · {text(row.direction).toUpperCase()} · {gbp(row.statement_gbp_amount)}</p>
                        <p className="mt-1 break-words text-sm text-slate-600 [overflow-wrap:anywhere]">{text(row.reference_raw) || text(row.retailer_name_ref) || "No statement text"}</p>
                      </div>
                      <span className={`rounded-full px-2 py-1 text-xs font-semibold ring-1 ${statusBadgeTone(status)}`}>{status}</span>
                    </div>
                    <p className="mt-2 text-xs text-slate-500">Allocated {gbp(row.confirmed_allocated_gbp)} · Remaining {gbp(row.confirmed_unallocated_gbp)} · Open/draft {gbp(row.open_allocated_gbp)} · Auth {text(row.auth_id_ref) || "—"}</p>
                  </Link>
                );
              })}
            </div>
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm lg:max-h-[72vh] lg:overflow-y-auto">
            <div className="sticky top-0 z-10 -mx-4 -mt-4 border-b border-slate-200 bg-white/95 p-4 backdrop-blur">
              <h2 className="text-lg font-semibold">Orders / invoices / exceptions</h2>
              <form className="mt-3 grid gap-2 sm:grid-cols-2" action="/internal/dva-reconciliation/workspace">
                <input type="hidden" name="importer_id" value={selectedImporterId} />
                <input type="hidden" name="line_id" value={activeLineId} />
                <input type="hidden" name="target_id" value={activeSelectedTargetId} />
                <input type="hidden" name="left_status" value={leftStatus} />
                <input type="hidden" name="left_direction" value={leftDirection} />
                <input type="hidden" name="left_retailer" value={leftRetailer} />
                <input name="right_retailer" defaultValue={activeManualRightRetailer} placeholder={hasAutoMerchantMatches ? `Auto: ${selectedMerchantTokens.join(", ")}` : "Retailer/order filter, e.g. Ninja"} className="rounded-xl border border-slate-200 px-3 py-2 text-sm" />
                <select name="right_status" defaultValue={rightStatus} className="rounded-xl border border-slate-200 px-3 py-2 text-sm">
                  <option value="usable">Usable candidates</option>
                  <option value="open">Open / active</option>
                  <option value="balance_due">Balance due</option>
                  <option value="approved_current">Approved current</option>
                  <option value="pending_review">Pending review</option>
                  <option value="rejected_resubmit_required">Rejected / resubmit</option>
                  <option value="all">All</option>
                </select>
                <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white sm:col-span-2" type="submit">Apply right filters</button>
              </form>
            </div>

            <div className="mt-4 space-y-3">
              {operationalRows.length === 0 ? <p className="text-sm text-slate-500">No candidate orders, invoices, exceptions, or final-balance targets match the current filters.</p> : null}
              {operationalRows.map((row) => (
                row.kind === "invoice" && !bool(row.raw.selectable_yn) ? (
                  <article
                    key={`${row.kind}-${row.id}`}
                    className="block rounded-2xl border border-amber-200 bg-amber-50/50 p-4"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="font-semibold">{targetKindLabel(row.kind)} · {row.title}</p>
                        <p className="mt-1 text-sm text-slate-600">{row.retailerName || "No retailer"} · {row.orderRef || "No order ref"}</p>
                      </div>
                      <span className="rounded-full bg-white px-2 py-1 text-xs font-semibold text-slate-700 ring-1 ring-slate-200">{row.status || "open"}</span>
                    </div>
                    <div className="mt-2 space-y-1 text-xs text-slate-500">
                      <p>Invoice total {gbp(row.raw.invoice_total_gbp)} · Confirmed matched {gbp(row.raw.confirmed_matched_gbp)} · Remaining unmatched {gbp(row.raw.remaining_unmatched_gbp)}</p>
                      <p>Payment ready {bool(row.raw.supplier_payment_ready_yn) ? "Yes" : "No"} · Selectable {bool(row.raw.selectable_yn) ? "Yes" : "No"}</p>
                      {text(row.raw.blocker) ? <p className="font-semibold text-amber-700">Blocker: {text(row.raw.blocker)}</p> : null}
                    </div>
                    {merchantScore(row, selectedMerchantTokens) > 0 ? <p className="mt-2 rounded-xl bg-emerald-50 px-3 py-2 text-xs font-semibold text-emerald-800">Merchant match score: {merchantScore(row, selectedMerchantTokens)}</p> : null}
                    {amountScore(selectedStatementAmount, row) > 0 ? <p className="mt-2 rounded-xl bg-amber-50 px-3 py-2 text-xs font-semibold text-amber-800">Amount closeness score: {amountScore(selectedStatementAmount, row)}</p> : null}
                    <p className="mt-2 rounded-xl bg-amber-100 px-3 py-2 text-xs font-semibold text-amber-900">Not selectable</p>
                  </article>
                ) : (
                <Link
                  key={`${row.kind}-${row.id}`}
                  href={workspaceHref({
                    importer_id: selectedImporterId,
                    line_id: activeLineId,
                    target_id: row.id,
                    left_status: leftStatus,
                    left_direction: leftDirection,
                    left_retailer: leftRetailer,
                    right_retailer: activeManualRightRetailer,
                    right_status: rightStatus,
                  })}
                  className={`block rounded-2xl border p-4 ${opTone(row, activeSelectedTargetId)}`}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <p className="font-semibold">{targetKindLabel(row.kind)} · {row.title}</p>
                      <p className="mt-1 text-sm text-slate-600">{row.retailerName || "No retailer"} · {row.orderRef || "No order ref"}</p>
                    </div>
                    <span className="rounded-full bg-white px-2 py-1 text-xs font-semibold text-slate-700 ring-1 ring-slate-200">{row.status || "open"}</span>
                  </div>
                  {row.kind === "final_balance" ? (
                    <div className="mt-2 space-y-1 text-xs text-slate-500">
                      <p>Final sale value {gbp(row.raw.signed_final_sale_value_gbp)} · Received so far {gbp(row.raw.amount_received_gbp)} · Balance due {gbp(row.raw.final_balance_due_gbp)}</p>
                      {text(selectedLine?.direction) === "in" ? <p>Selected line preview: apply {gbp(Math.min(selectedStatementRemaining, row.amount))} · balance after {gbp(Math.max(0, row.amount - selectedStatementRemaining))} · FX/card excess {gbp(Math.max(0, selectedStatementRemaining - row.amount))}</p> : <p className="font-semibold text-amber-700">Final-balance payment requires an IN statement line.</p>}
                    </div>
                  ) : row.kind === "invoice" ? (
                    <div className="mt-2 space-y-1 text-xs text-slate-500">
                      <p>Invoice total {gbp(row.raw.invoice_total_gbp)} · Confirmed matched {gbp(row.raw.confirmed_matched_gbp)} · Remaining unmatched {gbp(row.raw.remaining_unmatched_gbp)}</p>
                      <p>Payment ready {bool(row.raw.supplier_payment_ready_yn) ? "Yes" : "No"} · Selectable {bool(row.raw.selectable_yn) ? "Yes" : "No"}</p>
                      {text(row.raw.blocker) ? <p className="font-semibold text-amber-700">Blocker: {text(row.raw.blocker)}</p> : null}
                    </div>
                  ) : (
                    <p className="mt-2 text-xs text-slate-500">Amount {gbp(row.amount)} · Progressed {gbp(row.progressedTotal)} · Open exception {gbp(row.openExceptionTotal)}</p>
                  )}
                  {merchantScore(row, selectedMerchantTokens) > 0 ? <p className="mt-2 rounded-xl bg-emerald-50 px-3 py-2 text-xs font-semibold text-emerald-800">Merchant match score: {merchantScore(row, selectedMerchantTokens)}</p> : null}
                  {amountScore(selectedStatementAmount, row) > 0 ? <p className="mt-2 rounded-xl bg-amber-50 px-3 py-2 text-xs font-semibold text-amber-800">Amount closeness score: {amountScore(selectedStatementAmount, row)}</p> : null}
                  {row.id === activeSelectedTargetId ? <p className="mt-2 rounded-xl bg-sky-100 px-3 py-2 text-xs font-semibold text-sky-900">Selected target</p> : null}
                </Link>
                )
              ))}
            </div>
          </div>
        </section>
      </div>

      <aside className="fixed inset-x-0 bottom-0 z-20 border-t border-slate-200 bg-white/95 px-4 py-3 shadow-2xl backdrop-blur">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 text-sm">
          <div>
            <p className="font-semibold">Selected statement: {selectedLine ? `${text(selectedLine.direction).toUpperCase()} · ${gbp(selectedStatementAmount)}` : "none"}</p>
            <p className="text-slate-600">Current allocated {gbp(selectedStatementAllocated)} · Selected target {selectedTarget ? `${targetKindLabel(selectedTarget.kind)} · ${gbp(selectedTargetAmount)}` : "none"}</p>
          </div>
          <div className="grid gap-1 text-right">
            <p className="font-semibold">Suggested allocation: {gbp(suggestedAllocation)}</p>
            <p className="text-slate-600">Remaining after selection: {gbp(remainingAfterSelection)}</p>
            {selectedTargetIsFinalBalance ? <p className="text-slate-600">Final balance after: {gbp(finalBalanceAfterSelection)} · FX/card excess: {gbp(finalBalanceFxExcess)}</p> : null}
            {!selectedTarget ? <p className="text-xs font-semibold text-amber-700">Select a right-side target before allocation.</p> : null}
            {selectedTargetIsFinalBalance && text(selectedLine?.direction) !== "in" ? <p className="text-xs font-semibold text-amber-700">Final-balance payment requires an IN statement line.</p> : null}
            {selectedTargetIsSupplierInvoice && supplierAllocationBlocker ? <p className="text-xs font-semibold text-amber-700">Supplier allocation unavailable: {supplierAllocationBlocker}</p> : null}
          </div>
          <div className="flex flex-wrap gap-2">
            {selectedTargetIsSupplierInvoice ? (
              <form action={allocateStatementLineToSupplierInvoiceAction}>
                <input type="hidden" name="return_path" value={activeReturnPath} />
                <input type="hidden" name="dva_statement_line_id" value={activeLineId} />
                <input type="hidden" name="supplier_invoice_id" value={selectedTarget?.id ?? ""} />
                <input type="hidden" name="allocated_gbp_amount" value={suggestedAllocation.toFixed(2)} />
                <input type="hidden" name="notes" value="DVA/card workspace supplier invoice allocation." />
                <button className="rounded-xl bg-slate-950 px-4 py-2 font-semibold text-white disabled:bg-slate-200 disabled:text-slate-500" type="submit" disabled={!canApplySupplierInvoice} title={supplierAllocationBlocker || undefined}>Confirm supplier allocation</button>
              </form>
            ) : selectedTargetIsFinalBalance ? (
              <form action={allocateStatementLineToFinalBalancePaymentAction}>
                <input type="hidden" name="return_path" value={activeReturnPath} />
                <input type="hidden" name="dva_statement_line_id" value={activeLineId} />
                <input type="hidden" name="order_id" value={selectedTarget?.orderId ?? ""} />
                <input type="hidden" name="classify_fx_excess" value="true" />
                <input type="hidden" name="notes" value="Final balance allocation from DVA/card workspace." />
                <button className="rounded-xl bg-slate-950 px-4 py-2 font-semibold text-white disabled:bg-slate-200 disabled:text-slate-500" type="submit" disabled={!canApplyFinalBalance}>{finalBalanceFxExcess > 0 ? "Apply balance + FX/card excess" : "Apply to final balance"}</button>
              </form>
            ) : (
              <button className="rounded-xl bg-slate-200 px-4 py-2 font-semibold text-slate-500" type="button" disabled>Confirm allocation next</button>
            )}
            <button className="rounded-xl bg-slate-100 px-4 py-2 font-semibold text-slate-500" type="button" disabled>Add FX/card diff next</button>
          </div>
        </div>
      </aside>
    </main>
  );
}
