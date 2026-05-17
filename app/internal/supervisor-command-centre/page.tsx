import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "complete" | "progress" | "action" | "blocked" | "review" | "muted";

type Lane = {
  label: string;
  detail: string;
  tone: Tone;
  href: string;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const terminalDisputeStatuses = new Set(["closed", "resolved", "refunded", "replaced", "closed_no_action"]);

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
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

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 72) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function lane(label: string, detail: string, tone: Tone, href: string): Lane {
  return { label, detail, tone, href };
}

function indexById(rows: Row[]) {
  const indexed = new Map<string, Row>();
  for (const row of rows) {
    const id = text(row.id);
    if (id) indexed.set(id, row);
  }
  return indexed;
}

function groupByKey(rows: Row[], key: string) {
  const grouped = new Map<string, Row[]>();
  for (const row of rows) {
    const value = text(row[key]);
    if (!value) continue;
    grouped.set(value, [...(grouped.get(value) ?? []), row]);
  }
  return grouped;
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "progress") return "border-sky-200 bg-sky-50 text-sky-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function chipClass(tone: Tone) {
  if (tone === "complete") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (tone === "progress") return "bg-sky-100 text-sky-800 ring-sky-200";
  if (tone === "action") return "bg-amber-100 text-amber-800 ring-amber-200";
  if (tone === "blocked") return "bg-rose-100 text-rose-800 ring-rose-200";
  if (tone === "review") return "bg-violet-100 text-violet-800 ring-violet-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function orderRefsFromShipping(row: Row) {
  return text(row.order_refs_preview).split(",").map((value) => value.trim()).filter(Boolean);
}

function shippingForOrder(order: Row, shippingRows: Row[]) {
  const orderRef = text(order.order_ref);
  return shippingRows.find((row) => orderRefsFromShipping(row).includes(orderRef));
}

function queueRowsForOrder(order: Row, queueRows: Row[]) {
  const orderId = text(order.id);
  const orderRef = text(order.order_ref);
  return queueRows.filter((row) => {
    const refs = text(row.order_ref).split(",").map((value) => value.trim()).filter(Boolean);
    return text(row.order_id) === orderId || text(row.reference_text) === orderRef || refs.includes(orderRef);
  });
}

function releaseRowsForOrder(order: Row, releaseRows: Row[]) {
  const orderRef = text(order.order_ref);
  return releaseRows.filter((row) => {
    const refs = text(row.order_refs).split(",").map((value) => value.trim()).filter(Boolean);
    return refs.includes(orderRef) || text(row.first_order_ref) === orderRef;
  });
}

function payloadValue(payload: unknown, first: string, second: string) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return "";
  const parent = (payload as Row)[first];
  if (!parent || typeof parent !== "object" || Array.isArray(parent)) return "";
  return text((parent as Row)[second]);
}

function fundingLane(order: Row, funding?: Row) {
  if (!funding) return lane("Not checked", "No funding position row visible", "review", "/internal/funding");
  const gap = num(funding.gap_remaining_gbp);
  const funded = num(funding.funded_total_gbp);
  const required = num(funding.purchase_funding_threshold_gbp || order.order_total_gbp_declared);
  if (gap <= 0 || bool(funding.threshold_met_yn) || bool(funding.already_funded_yn)) return lane("Complete", `Funded ${gbp(funded)} / required ${gbp(required)}`, "complete", "/internal/funding");
  if (funded > 0) return lane("Part funded", `Gap ${gbp(gap)}`, "action", "/internal/funding");
  return lane("Funding gap", `Required ${gbp(required)}`, "blocked", "/internal/funding");
}

function supplierLane(invoices: Row[]) {
  if (invoices.length === 0) return lane("Missing", "No supplier goods invoice found", "action", "/internal/invoice-review");
  const approved = invoices.find((invoice) => text(invoice.review_status) === "approved_current" && !bool(invoice.blocked_from_sage_yn));
  if (approved) return lane("Approved current", `${text(approved.invoice_ref) || "Supplier invoice"} · ${gbp(approved.ocr_invoice_total_gbp || approved.reconciliation_gbp_total)}`, "complete", "/internal/supplier-draft-ready");
  const blocked = invoices.find((invoice) => bool(invoice.blocked_from_sage_yn) || ["pending_review", "needs_action", "duplicate_blocked", "rejected_resubmit_required"].includes(text(invoice.review_status)));
  if (blocked) return lane("Review needed", `${text(blocked.invoice_ref) || "Supplier invoice"} · ${pretty(blocked.review_status)}`, "review", "/internal/invoice-review");
  return lane("In progress", `${invoices.length} invoice record(s)`, "progress", "/internal/invoice-review");
}

function exceptionLane(disputes: Row[]) {
  if (disputes.length === 0) return lane("None", "No recorded order exceptions", "complete", "/internal/exceptions");
  const open = disputes.filter((dispute) => !terminalDisputeStatuses.has(text(dispute.status)) && !text(dispute.resolved_at));
  if (open.length === 0) return lane("Controlled", `${disputes.length} exception(s) closed or final-stage`, "complete", "/internal/exceptions");
  return lane("Action needed", `${open.length} open exception(s): ${short(open.map((row) => pretty(row.desired_outcome || row.status)).join(", "))}`, "blocked", "/internal/exceptions");
}

function dvaLane(order: Row, allocations: Row[], supplier: Lane, funding: Lane) {
  const orderId = text(order.id);
  const orderRef = text(order.order_ref);
  const related = allocations.filter((allocation) => {
    if (text(allocation.allocation_status) === "reversed" || bool(allocation.reversed_yn)) return false;
    return text(allocation.order_id) === orderId || text(allocation.order_ref) === orderRef;
  });
  const supplierOut = related.filter((allocation) => text(allocation.allocation_type) === "supplier_invoice");
  const holds = related.filter((allocation) => ["exception_hold", "unmatched_hold"].includes(text(allocation.allocation_type)));
  if (holds.length > 0) return lane("Review hold", `${holds.length} DVA/card hold allocation(s)`, "review", "/internal/dva-reconciliation/workspace");
  if (supplierOut.length > 0) return lane("Explained", `${supplierOut.length} supplier OUT allocation(s)`, "complete", "/internal/dva-reconciliation/workspace");
  if (funding.tone === "complete" && supplier.tone === "complete") return lane("Needs allocation", "Supplier OUT allocation not visible here", "action", "/internal/dva-reconciliation/workspace");
  return lane("Not reached", "Waits on funding/invoice facts", "muted", "/internal/dva-reconciliation/workspace");
}

function shippingLane(shipping?: Row) {
  if (!shipping) return lane("Not reached", "No shipment batch found", "muted", "/internal/shipping-control");
  const receipt = text(shipping.receipt_status_summary);
  const allocation = text(shipping.allocation_status_summary);
  const booking = text(shipping.booking_ref) || text(shipping.shipment_batch_id).slice(0, 8);
  if (receipt === "received_clean" && allocation === "contents_allocated") return lane("Clean / allocated", `${booking} · ${num(shipping.package_count)} package(s) · ${num(shipping.item_qty)} item(s)`, "complete", `/internal/shipping-control/${text(shipping.shipment_batch_id)}`);
  if (receipt === "receipt_issue") return lane("Receipt issue", `${booking} has receipt issue(s)`, "blocked", `/internal/shipping-control/${text(shipping.shipment_batch_id)}`);
  if (allocation === "allocation_missing") return lane("Allocation missing", `${booking} needs content allocation`, "action", `/internal/shipping-control/${text(shipping.shipment_batch_id)}`);
  return lane("In progress", `${booking} · receipt ${pretty(receipt)} · allocation ${pretty(allocation)}`, "progress", `/internal/shipping-control/${text(shipping.shipment_batch_id)}`);
}

function customerSalesLane(salesInvoices: Row[], sageRows: Row[], releaseRows: Row[]) {
  const customerRows = sageRows.filter((row) => text(row.document_lane) === "customer_sales");
  const blocked = customerRows.find((row) => text(row.readiness_status).startsWith("blocked"));
  const ready = customerRows.find((row) => text(row.readiness_status).startsWith("ready"));
  const posted = customerRows.find((row) => text(row.sage_status) === "posted" || text(row.readiness_status).includes("posted"));
  const stalePayload = customerRows.find((row) => payloadValue(row.source_payload, "tax_resolution", "sage_tax_rate_resolution_required") === "true" && !payloadValue(row.source_payload, "tax_resolution", "sage_tax_rate_id"));
  const draft = salesInvoices.find((invoice) => text(invoice.sage_status) === "draft");
  const releasable = releaseRows.find((row) => text(row.readiness_status) === "ready_to_create_draft");
  const releaseDraft = releaseRows.find((row) => text(row.readiness_status) === "draft_exists");

  if (posted) return lane("Posted / marked", `${pretty(posted.document_type)} · ${gbp(posted.amount_gbp)}`, "complete", text(posted.detail_href) || "/internal/accounting-command-centre");
  if (blocked) return lane("Payload blocked", text(blocked.blocker) || pretty(blocked.readiness_status), "blocked", text(blocked.detail_href) || "/internal/accounting-command-centre");
  if (ready && stalePayload) return lane("Preview-ready, stale snapshot", "Queue is mapping-aware; old draft JSON still shows unresolved tax fields", "review", text(ready.detail_href) || "/internal/accounting-command-centre");
  if (ready) return lane("Accounting handoff ready", `${pretty(ready.document_type)} · ${gbp(ready.amount_gbp)}`, "complete", text(ready.detail_href) || "/internal/accounting-command-centre");
  if (draft || releaseDraft) return lane("Draft exists", `${draft ? gbp(draft.amount_gbp) : gbp(releaseDraft?.proposed_amount_gbp)} · needs Accounting Command Centre review`, "progress", "/internal/accounting-command-centre");
  if (releasable) return lane("Draft-ready", `${pretty(releasable.proposed_invoice_type)} · ${gbp(releasable.proposed_amount_gbp)}`, "action", "/internal/shipping-control/customer-invoice-release");
  return lane("Not reached", "No customer sales draft/intention visible yet", "muted", "/internal/shipping-control/customer-invoice-release");
}

function shipperApLane(shipping: Row | undefined, sageRows: Row[]) {
  const shipperRows = sageRows.filter((row) => text(row.document_lane) === "shipper_ap");
  const ready = shipperRows.find((row) => text(row.readiness_status).startsWith("ready"));
  const blocked = shipperRows.find((row) => text(row.readiness_status).startsWith("blocked"));
  if (ready) return lane("AP handoff ready", `${text(ready.reference_text) || "Shipper AP"} · ${gbp(ready.amount_gbp)}`, "complete", text(ready.detail_href) || "/internal/accounting-command-centre");
  if (blocked) return lane("AP blocked", text(blocked.blocker) || pretty(blocked.readiness_status), "blocked", text(blocked.detail_href) || "/internal/accounting-command-centre");
  if (!shipping) return lane("Not reached", "No shipment batch found", "muted", "/internal/shipping-control");
  const shipperInvoice = text(shipping.shipper_invoice_status);
  const apportionment = text(shipping.sage_readiness_status);
  if (shipperInvoice === "accepted_current" && apportionment === "shipping_apportionment_approved") return lane("AP source ready", "Accepted shipper document and apportionment approved", "complete", `/internal/shipping-control/readiness/${text(shipping.shipment_batch_id)}`);
  if (shipperInvoice === "accepted_current") return lane("Apportionment needed", "Shipper document accepted; shipping AP apportionment pending", "action", `/internal/shipping-control/readiness/${text(shipping.shipment_batch_id)}`);
  if (shipperInvoice === "not_started" || !shipperInvoice) return lane("Blocked", "Missing shipper invoice or receipt; does not block main goods customer invoice", "blocked", "/internal/shipping-control/shipper-documents");
  return lane("Review", `Shipper invoice status: ${pretty(shipperInvoice)}`, "review", "/internal/shipping-control/shipper-documents");
}

function exportLane(shipping?: Row) {
  if (!shipping) return lane("Not reached", "No shipment batch/export lane yet", "muted", "/internal/shipping-control");
  const exportEvidence = text(shipping.export_evidence_status);
  const masterShipment = text(shipping.master_shipment_status);
  if (["not_started", "not_grouped", "not_ready", ""].includes(exportEvidence)) return lane("Not reached", `Export ${pretty(exportEvidence)} · master ${pretty(masterShipment)}`, "muted", `/internal/shipping-control/${text(shipping.shipment_batch_id)}`);
  return lane("In progress", `Export ${pretty(exportEvidence)} · master ${pretty(masterShipment)}`, "progress", `/internal/shipping-control/${text(shipping.shipment_batch_id)}`);
}

function customerLane(order: Row, importer?: Row, retailer?: Row) {
  const importerName = text(importer?.trading_name) || text(importer?.company_name) || "Importer";
  const retailerName = text(retailer?.name) || "Retailer";
  return lane(text(order.funded_at) ? "Customer funded" : "Customer active", `${importerName} · ${retailerName}`, text(order.funded_at) ? "complete" : "progress", "/internal/funding");
}

function nextActions(states: Record<string, Lane>) {
  const candidates: { owner: string; label: string; reason: string; href: string; tone: Tone }[] = [];
  const push = (owner: string, label: string, state: Lane) => candidates.push({ owner, label, reason: state.detail, href: state.href, tone: state.tone });

  if (["blocked", "action"].includes(states.funding.tone)) push("Supervisor", "Match/apply funding", states.funding);
  if (["blocked", "action", "review"].includes(states.supplier.tone)) push(states.supplier.label === "Missing" ? "Operator" : "Supervisor", states.supplier.label === "Missing" ? "Upload supplier invoice" : "Resolve supplier invoice", states.supplier);
  if (["blocked", "review"].includes(states.exceptions.tone)) push("Supervisor", "Resolve exception/hold", states.exceptions);
  if (["blocked", "action", "review"].includes(states.dva.tone)) push("Supervisor", "Review DVA/card allocation", states.dva);
  if (["blocked", "action", "review"].includes(states.customerSales.tone)) push("Supervisor", states.customerSales.label.includes("Draft-ready") ? "Create customer sales draft" : "Review customer sales handoff", states.customerSales);
  if (["blocked", "action", "review"].includes(states.shipping.tone)) push("Supervisor/Shipper", "Fix shipping/logistics lane", states.shipping);
  if (["blocked", "action", "review"].includes(states.shipperAp.tone)) push("Supervisor", states.shipperAp.label === "Blocked" ? "Upload/accept shipper document" : "Complete shipper AP readiness", states.shipperAp);
  if (candidates.length === 0 && states.exportDelivery.tone !== "complete") push("Supervisor/Shipper", "Progress export/delivery evidence", states.exportDelivery);
  if (candidates.length === 0) candidates.push({ owner: "Accounting", label: "Review accounting handoff", reason: "Operational lanes show no immediate blocker in this overview", href: "/internal/accounting-command-centre", tone: "complete" });
  return candidates;
}

function progress(states: Record<string, Lane>) {
  const applicable = [states.funding, states.supplier, states.dva, states.exceptions, states.shipping, states.customerSales, states.shipperAp, states.exportDelivery].filter((state) => state.tone !== "muted");
  const complete = applicable.filter((state) => state.tone === "complete").length;
  return { complete, total: applicable.length || 1, pct: Math.round((complete / (applicable.length || 1)) * 100) };
}

function StatusCell({ title, state }: { title: string; state: Lane }) {
  return (
    <div className={`rounded-2xl border p-3 ${toneClass(state.tone)}`}>
      <p className="text-[10px] font-extrabold uppercase tracking-wide opacity-70">{title}</p>
      <p className="mt-2 text-sm font-extrabold">{state.label}</p>
      <p className="mt-1 text-xs leading-5 opacity-90">{state.detail}</p>
      <Link href={state.href} className="mt-2 inline-block text-xs font-bold underline">Open</Link>
    </div>
  );
}

function FoundationCard({ title, value, detail, tone, href }: { title: string; value: string; detail: string; tone: Tone; href: string }) {
  return (
    <Link href={href} className={`block h-full rounded-3xl border p-4 shadow-sm ${toneClass(tone)}`}>
      <p className="text-xs font-bold uppercase tracking-wide opacity-70">{title}</p>
      <p className="mt-2 text-2xl font-extrabold">{value}</p>
      <p className="mt-1 text-xs leading-5 opacity-90">{detail}</p>
    </Link>
  );
}

function rowSearchText(order: Row, importer?: Row, retailer?: Row, shipping?: Row) {
  return [order.order_ref, order.status, importer?.company_name, importer?.trading_name, retailer?.name, shipping?.booking_ref, shipping?.shipper_name, shipping?.order_refs_preview].map(text).join(" ").toLowerCase();
}

export default async function SupervisorCommandCentrePage({ searchParams }: { searchParams?: Promise<{ q?: string; only_action?: string }> }) {
  const qp = searchParams ? await searchParams : {};
  const search = (qp.q ?? "").trim().toLowerCase();
  const onlyAction = qp.only_action === "true";

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("id, full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");

  const [ordersResult, importersResult, retailersResult, fundingResult, invoicesResult, disputesResult, salesResult, allocationsResult, shippingResult, customerReleaseResult, sageQueueResult, mappingResult] = await Promise.all([
    supabase.from("orders").select("id, order_ref, importer_id, retailer_id, status, order_type, created_at, order_total_gbp_declared, funded_at").order("created_at", { ascending: false }).limit(150),
    supabase.from("importers").select("id, company_name, trading_name").limit(500),
    supabase.from("retailers").select("id, name").limit(500),
    supabase.from("order_funding_position_vw").select("*").limit(1000),
    supabase.from("supplier_invoices").select("id, order_id, invoice_ref, review_status, blocked_from_sage_yn, ocr_invoice_total_gbp, reconciliation_gbp_total").limit(1000),
    supabase.from("disputes").select("id, order_id, desired_outcome, status, amount_impact_gbp, resolved_at, raised_at").limit(1000),
    supabase.from("sales_invoices").select("id, order_id, invoice_type, amount_gbp, sage_status, sage_invoice_id, sage_posted_at, created_at, line_items_json").limit(1000),
    supabase.from("dva_statement_line_allocation_detail_vw").select("allocation_id, importer_id, supplier_invoice_id, supplier_invoice_ref, order_id, order_ref, dispute_id, allocation_type, allocation_status, allocated_gbp_amount, reversed_yn").limit(2000),
    (supabase as any).rpc("internal_shipping_control_v1"),
    (supabase as any).rpc("internal_customer_invoice_release_queue_v1"),
    (supabase as any).rpc("internal_ready_for_sage_queue_v2"),
    (supabase as any).rpc("internal_sage_mapping_control_v1"),
  ]);

  const orders = (ordersResult.data ?? []) as Row[];
  const importersById = indexById((importersResult.data ?? []) as Row[]);
  const retailersById = indexById((retailersResult.data ?? []) as Row[]);
  const fundingByOrderId = new Map<string, Row>();
  for (const row of (fundingResult.data ?? []) as Row[]) {
    const orderId = text(row.order_id) || text(row.id);
    if (orderId) fundingByOrderId.set(orderId, row);
  }

  const invoicesByOrder = groupByKey((invoicesResult.data ?? []) as Row[], "order_id");
  const disputesByOrder = groupByKey((disputesResult.data ?? []) as Row[], "order_id");
  const salesByOrder = groupByKey((salesResult.data ?? []) as Row[], "order_id");
  const allocationRows = (allocationsResult.data ?? []) as Row[];
  const shippingRows = (shippingResult.data ?? []) as Row[];
  const customerReleaseRows = (customerReleaseResult.data ?? []) as Row[];
  const sageQueueRows = (sageQueueResult.data ?? []) as Row[];
  const mappingRows = (mappingResult.data ?? []) as Row[];

  const mappingMissing = mappingRows.filter((row) => text(row.mapping_status) !== "configured").length;
  const configuredMappings = mappingRows.filter((row) => text(row.mapping_status) === "configured").length;
  const activeExceptionCount = ((disputesResult.data ?? []) as Row[]).filter((row) => !terminalDisputeStatuses.has(text(row.status)) && !text(row.resolved_at)).length;
  const blockedSageRows = sageQueueRows.filter((row) => text(row.readiness_status).startsWith("blocked")).length;
  const readySageRows = sageQueueRows.filter((row) => text(row.readiness_status).startsWith("ready")).length;

  const cards = orders.map((order) => {
    const importer = importersById.get(text(order.importer_id));
    const retailer = retailersById.get(text(order.retailer_id));
    const shipping = shippingForOrder(order, shippingRows);
    const sageRows = queueRowsForOrder(order, sageQueueRows);
    const releaseRows = releaseRowsForOrder(order, customerReleaseRows);
    const funding = fundingLane(order, fundingByOrderId.get(text(order.id)));
    const supplier = supplierLane(invoicesByOrder.get(text(order.id)) ?? []);
    const states = {
      customer: customerLane(order, importer, retailer),
      funding,
      supplier,
      exceptions: exceptionLane(disputesByOrder.get(text(order.id)) ?? []),
      shipping: shippingLane(shipping),
      customerSales: customerSalesLane(salesByOrder.get(text(order.id)) ?? [], sageRows, releaseRows),
      shipperAp: shipperApLane(shipping, sageRows),
      exportDelivery: exportLane(shipping),
      dva: dvaLane(order, allocationRows, supplier, funding),
    };
    const actions = nextActions(states);
    const rowProgress = progress(states);
    return { order, importer, retailer, shipping, states, actions, progress: rowProgress };
  }).filter((card) => {
    if (search && !rowSearchText(card.order, card.importer, card.retailer, card.shipping).includes(search)) return false;
    if (!onlyAction) return true;
    return card.actions.some((action) => ["blocked", "action", "review"].includes(action.tone));
  });

  const errorMessages = [
    ordersResult.error ? `Orders: ${ordersResult.error.message}` : "",
    fundingResult.error ? `Funding: ${fundingResult.error.message}` : "",
    invoicesResult.error ? `Supplier invoices: ${invoicesResult.error.message}` : "",
    disputesResult.error ? `Exceptions: ${disputesResult.error.message}` : "",
    salesResult.error ? `Sales invoices: ${salesResult.error.message}` : "",
    allocationsResult.error ? `DVA allocations: ${allocationsResult.error.message}` : "",
    shippingResult.error ? `Shipping control: ${shippingResult.error.message}` : "",
    customerReleaseResult.error ? `Customer invoice release: ${customerReleaseResult.error.message}` : "",
    sageQueueResult.error ? `Accounting handoff: ${sageQueueResult.error.message}` : "",
    mappingResult.error ? `Sage mappings: ${mappingResult.error.message}` : "",
  ].filter(Boolean);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Supervisor operational cockpit</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Order-to-clean-delivery command centre</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">Read-only v4 cockpit for operational truth. It routes funding, DVA/card, supplier goods AP, exceptions, logistics/shipper, customer sales readiness, shipper AP readiness and export/delivery blockers into the correct child task pages. Sage posting controls stay inside Accounting Command Centre only.</p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{text(staff.full_name)}</div><div>{text(staff.role_type)}</div></div>
          </div>
          <div className="mt-4 grid gap-3 text-sm md:grid-cols-3">
            <div className="rounded-2xl border border-sky-200 bg-sky-50 p-3 text-sky-900"><p className="font-bold">Supervisor owns operational readiness</p><p className="mt-1 text-xs leading-5">Resolve blockers in funding, DVA/card, invoice, exception, shipper, customer and delivery lanes.</p></div>
            <div className="rounded-2xl border border-violet-200 bg-violet-50 p-3 text-violet-900"><p className="font-bold">Accounting owns Sage posting</p><p className="mt-1 text-xs leading-5">Freeze, revalidation, posting batches and Sage API posting are not available from this page.</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-slate-700"><p className="font-bold">Process graph, not straight line</p><p className="mt-1 text-xs leading-5">Customer sales and shipper AP can split where the platform has separate readiness gates.</p></div>
          </div>
          {errorMessages.length > 0 ? <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900"><p className="font-bold">Some lanes could not be read</p><ul className="mt-2 list-disc space-y-1 pl-5">{errorMessages.map((message) => <li key={message}>{message}</li>)}</ul></div> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-6">
          <FoundationCard title="Sage settings" value={`${configuredMappings}/${mappingRows.length || 4}`} detail={mappingMissing > 0 ? `${mappingMissing} missing mapping(s)` : "Configured for preview; verify before live posting"} tone={mappingMissing > 0 ? "blocked" : "review"} href="/internal/accounting-command-centre" />
          <FoundationCard title="Accounting handoff" value={`${readySageRows} ready`} detail={`${blockedSageRows} blocked document row(s)`} tone={blockedSageRows > 0 ? "action" : "complete"} href="/internal/accounting-command-centre" />
          <FoundationCard title="DVA/card" value={`${allocationRows.length}`} detail="Visible active/review allocation rows" tone={allocationRows.length > 0 ? "complete" : "review"} href="/internal/dva-reconciliation/workspace" />
          <FoundationCard title="Shipping" value={`${shippingRows.length}`} detail="Shipment batches in control spine" tone={shippingRows.length > 0 ? "complete" : "muted"} href="/internal/shipping-control" />
          <FoundationCard title="Customer drafts" value={`${customerReleaseRows.length}`} detail="Customer invoice release queue rows" tone={customerReleaseRows.length > 0 ? "progress" : "muted"} href="/internal/shipping-control/customer-invoice-release" />
          <FoundationCard title="Exceptions" value={`${activeExceptionCount}`} detail="Open unresolved exception rows" tone={activeExceptionCount > 0 ? "blocked" : "complete"} href="/internal/exceptions" />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm sm:p-5"><form action="/internal/supervisor-command-centre" className="grid gap-3 md:grid-cols-[1fr_auto_auto] md:items-end"><label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">Search orders, importers, retailers, bookings<input name="q" defaultValue={qp.q ?? ""} placeholder="ORD, importer, retailer, booking" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" /></label><label className="flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold text-slate-700"><input type="checkbox" name="only_action" value="true" defaultChecked={onlyAction} />Action rows only</label><div className="flex gap-2"><button type="submit" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Apply</button><Link href="/internal/supervisor-command-centre" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Reset</Link></div></form></section>

        <section className="space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-xl font-semibold">Operational process graph</h2><p className="text-sm text-slate-500">Showing {cards.length} order row(s)</p></div>
          {cards.length === 0 ? <div className="rounded-3xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-500 shadow-sm">No order rows match this filter.</div> : cards.map((card) => {
            const primary = card.actions[0];
            const parallelCount = Math.max(card.actions.length - 1, 0);
            return (
              <article key={text(card.order.id)} className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm sm:p-5">
                <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between"><div className="min-w-0"><div className="flex flex-wrap items-center gap-2"><h3 className="text-xl font-extrabold tracking-tight">{text(card.order.order_ref) || text(card.order.id)}</h3><span className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${chipClass(primary.tone)}`}>{primary.owner}</span>{parallelCount > 0 ? <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">+{parallelCount} parallel action{parallelCount === 1 ? "" : "s"}</span> : null}</div><p className="mt-1 text-sm text-slate-600">{text(card.retailer?.name) || "No retailer"} · {text(card.importer?.trading_name) || text(card.importer?.company_name) || "No importer"} · Raw DB status {pretty(card.order.status)} · Type {pretty(card.order.order_type)}</p></div><div className="min-w-[220px] rounded-2xl border border-slate-200 bg-slate-50 p-3"><div className="flex items-center justify-between gap-3 text-xs font-bold uppercase tracking-wide text-slate-500"><span>Progress</span><span>{card.progress.complete}/{card.progress.total}</span></div><div className="mt-2 h-3 overflow-hidden rounded-full bg-slate-200"><div className="h-full rounded-full bg-slate-950" style={{ width: `${card.progress.pct}%` }} /></div><p className="mt-2 text-xs text-slate-600">{card.progress.pct}% of applicable visible gates complete</p></div></div>
                <div className="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4"><StatusCell title="Customer / importer" state={card.states.customer} /><StatusCell title="Funding" state={card.states.funding} /><StatusCell title="Supplier goods AP" state={card.states.supplier} /><StatusCell title="DVA/card" state={card.states.dva} /><StatusCell title="Exceptions / holds" state={card.states.exceptions} /><StatusCell title="Logistics / shipper" state={card.states.shipping} /><StatusCell title="Customer Sales / AR" state={card.states.customerSales} /><StatusCell title="Shipper AP / freight" state={card.states.shipperAp} /><StatusCell title="Export / delivery" state={card.states.exportDelivery} /></div>
                <div className={`mt-4 rounded-2xl border p-4 ${toneClass(primary.tone)}`}><p className="text-xs font-bold uppercase tracking-wide opacity-70">Next action</p><div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between"><div><p className="text-lg font-extrabold">{primary.owner}: {primary.label}</p><p className="mt-1 text-sm leading-6 opacity-90">{primary.reason}</p></div><Link href={primary.href} className="w-fit rounded-xl bg-white px-4 py-2 text-sm font-bold text-slate-900 shadow-sm ring-1 ring-slate-200">Open action</Link></div>{parallelCount > 0 ? <div className="mt-3 flex flex-wrap gap-2">{card.actions.slice(1).map((action) => <Link key={`${text(card.order.id)}-${action.label}-${action.href}`} href={action.href} className="rounded-full bg-white/70 px-3 py-1 text-xs font-bold underline ring-1 ring-slate-200">{action.owner}: {action.label}</Link>)}</div> : null}</div>
              </article>
            );
          })}
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900"><h2 className="font-bold">v4 control rule</h2><p className="mt-2">This page is the operational map, not the accounting workroom. Existing child task pages remain the controlled places to upload, review, reconcile and approve. Accounting Command Centre is the only place for freeze, revalidation, posting batches and Sage Cloud Accounting API posting. Main goods customer sales can progress independently of shipper AP where split-flow controls allow it.</p></section>
      </div>
    </main>
  );
}
