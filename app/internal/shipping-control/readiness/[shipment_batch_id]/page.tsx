import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type ReadinessRow = {
  shipment_batch_id: string;
  booking_ref: string | null;
  shipper_id: string;
  shipper_name: string | null;
  importer_id: string | null;
  importer_name: string | null;
  shipping_document_id: string | null;
  shipping_document_kind: string | null;
  shipping_document_ref: string | null;
  shipping_document_date: string | null;
  shipping_document_currency: string | null;
  shipping_document_total: number | string | null;
  shipping_document_review_status: string | null;
  shipping_cost_allocation_id: string | null;
  shipping_apportionment_status: string | null;
  shipping_apportionment_approved_at: string | null;
  order_id: string | null;
  order_ref: string | null;
  tracking_submission_id: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  adjusted_goods_basis_gbp: number | string | null;
  allocated_shipping_amount: number | string | null;
  ap_document_route: string | null;
  customer_recharge_route: string | null;
  sales_invoice_state: string | null;
  readiness_status: string | null;
  blocker: string | null;
};

type CustomerInvoicePreviewRow = {
  shipment_batch_id: string;
  booking_ref: string | null;
  proposed_invoice_type: string | null;
  proposed_invoice_status: string | null;
  customer_recharge_route: string | null;
  sales_invoice_state: string | null;
  proposed_amount_gbp: number | string | null;
  proposed_goods_amount_gbp: number | string | null;
  proposed_shipping_amount_gbp: number | string | null;
  order_id: string | null;
  order_ref: string | null;
  tracking_submission_id: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  goods_amount_gbp: number | string | null;
  shipping_amount_gbp: number | string | null;
  total_line_amount_gbp: number | string | null;
  readiness_status: string | null;
  blocker: string | null;
};

type CustomerStatus = {
  label: string;
  shortLabel: string;
  className: string;
  chipClassName: string;
  detail: string;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined, currency = "GBP") {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: currency || "GBP" }).format(n(value));
}

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function shortDate(value: string | null | undefined) {
  if (!value) return "—";
  return value.includes("T") ? value.slice(0, 10) : value;
}

function routeLabel(value: string | null | undefined) {
  if (value === "include_shipping_in_main_sales_invoice_release") return "Main invoice";
  if (value === "already_bundled_in_main_sales_invoice") return "Already billed in main invoice";
  if (value === "supplementary_shipping_recharge_invoice") return "Supplementary invoice";
  if (value === "supplementary_shipping_recharge_invoice_review_required") return "Supplementary review";
  if (value === "main_goods_invoice_release") return "Main invoice release";
  if (value === "sales_invoice_route_not_resolved") return "Route unresolved";
  return friendly(value);
}

function invoiceStateLabel(value: string | null | undefined) {
  if (value === "no_main_sales_invoice_found") return "No main sales invoice found";
  if (value === "main_sales_invoice_posted") return "Main sales invoice posted";
  if (value === "main_sales_invoice_posted_bundled") return "Main sales invoice posted with goods + shipping";
  if (value === "main_sales_invoice_draft_exists") return "Main sales invoice draft exists";
  if (value === "main_sales_invoice_void_ignored") return "Main sales invoice void ignored";
  if (value === "main_sales_invoice_exists_sage_status_unavailable") return "Main invoice exists — Sage status unavailable";
  if (value === "main_sales_invoice_exists") return "Main sales invoice exists";
  if (value === "main_sales_invoice_exists_status_unknown") return "Main invoice exists — status unknown";
  if (value === "sales_invoice_exists_type_unknown") return "Sales invoice exists — type unknown";
  if (value === "sales_invoice_table_not_available") return "Sales invoice table unavailable";
  return friendly(value);
}

function readinessLabel(value: string | null | undefined) {
  if (value === "ready_for_ap_and_customer_recharge_payload_preview") return "Ready";
  if (!value) return "—";
  if (value.startsWith("blocked_")) return "Blocked";
  return friendly(value);
}

function statusClass(status: string | null | undefined) {
  if (!status) return "bg-slate-100 text-slate-700";
  if (status.startsWith("ready_") || [
    "accepted_current",
    "approved",
    "include_shipping_in_main_sales_invoice_release",
    "already_bundled_in_main_sales_invoice",
    "main_sales_invoice_posted_bundled",
    "supplementary_shipping_recharge_invoice",
  ].includes(status)) {
    return "bg-emerald-100 text-emerald-800";
  }
  if (status.startsWith("blocked_") || status.includes("missing") || status.includes("not_approved") || status.includes("not_accepted")) {
    return "bg-rose-100 text-rose-800";
  }
  return "bg-amber-100 text-amber-800";
}

function lineKey(row: {
  order_id?: string | null;
  tracking_submission_id?: string | null;
  supplier_invoice_line_id?: string | null;
}) {
  return [row.order_id ?? "", row.tracking_submission_id ?? "", row.supplier_invoice_line_id ?? ""].join("::");
}

function isAlreadyBilled(row: CustomerInvoicePreviewRow | null | undefined) {
  return row?.readiness_status === "already_bundled_in_main_sales_invoice" ||
    row?.customer_recharge_route === "already_bundled_in_main_sales_invoice" ||
    row?.sales_invoice_state === "main_sales_invoice_posted_bundled";
}

function customerLineStatus(row: CustomerInvoicePreviewRow | null | undefined): CustomerStatus {
  if (!row) {
    return {
      label: "Customer review",
      shortLabel: "Review",
      className: "border-amber-200 bg-amber-50",
      chipClassName: "bg-amber-100 text-amber-800",
      detail: "Customer invoice readiness row not matched to this AP line",
    };
  }

  if (row.blocker || row.proposed_invoice_status === "blocked" || row.readiness_status === "blocked") {
    return {
      label: "Customer blocked",
      shortLabel: "Blocked",
      className: "border-rose-200 bg-rose-50",
      chipClassName: "bg-rose-100 text-rose-800",
      detail: row.blocker ? friendly(row.blocker) : "Customer invoice readiness is blocked",
    };
  }

  if (isAlreadyBilled(row)) {
    return {
      label: "Already billed",
      shortLabel: "Already billed",
      className: "border-emerald-200 bg-emerald-50",
      chipClassName: "bg-emerald-100 text-emerald-800",
      detail: "Main invoice includes goods + shipping",
    };
  }

  if (row.readiness_status === "ready_for_main_invoice_release_preview") {
    return {
      label: "Main invoice ready",
      shortLabel: "Main ready",
      className: "border-emerald-200 bg-emerald-50",
      chipClassName: "bg-emerald-100 text-emerald-800",
      detail: "Ready for customer final invoice release",
    };
  }

  if (row.readiness_status === "ready_for_supplementary_invoice_preview") {
    return {
      label: "Supplementary ready",
      shortLabel: "Supplementary ready",
      className: "border-emerald-200 bg-emerald-50",
      chipClassName: "bg-emerald-100 text-emerald-800",
      detail: "Supplementary shipping charge can be reviewed",
    };
  }

  return {
    label: "Customer review",
    shortLabel: "Review",
    className: "border-amber-200 bg-amber-50",
    chipClassName: "bg-amber-100 text-amber-800",
    detail: "Inspect customer invoice preview",
  };
}

function customerInvoiceStatus(rows: CustomerInvoicePreviewRow[]): CustomerStatus {
  if (!rows.length) {
    return {
      label: "Customer review",
      shortLabel: "Review",
      className: "border-amber-200 bg-amber-50",
      chipClassName: "bg-amber-100 text-amber-800",
      detail: "Customer invoice preview unavailable",
    };
  }

  const statuses = rows.map(customerLineStatus);

  if (statuses.some((status) => status.shortLabel === "Blocked")) {
    return {
      label: "Customer blocked",
      shortLabel: "Blocked",
      className: "border-rose-200 bg-rose-50",
      chipClassName: "bg-rose-100 text-rose-800",
      detail: "Resolve customer invoice readiness blockers",
    };
  }

  if (statuses.every((status) => status.shortLabel === "Already billed")) {
    return {
      label: "Already billed",
      shortLabel: "Already billed",
      className: "border-emerald-200 bg-emerald-50",
      chipClassName: "bg-emerald-100 text-emerald-800",
      detail: "Main invoice includes goods + shipping",
    };
  }

  if (statuses.every((status) => status.shortLabel === "Main ready")) {
    return {
      label: "Main invoice ready",
      shortLabel: "Main ready",
      className: "border-emerald-200 bg-emerald-50",
      chipClassName: "bg-emerald-100 text-emerald-800",
      detail: "Ready for customer final invoice release",
    };
  }

  if (statuses.every((status) => status.shortLabel === "Supplementary ready")) {
    return {
      label: "Supplementary ready",
      shortLabel: "Supplementary ready",
      className: "border-emerald-200 bg-emerald-50",
      chipClassName: "bg-emerald-100 text-emerald-800",
      detail: "Supplementary shipping charge can be reviewed",
    };
  }

  return {
    label: "Customer review",
    shortLabel: "Review",
    className: "border-amber-200 bg-amber-50",
    chipClassName: "bg-amber-100 text-amber-800",
    detail: "Mixed or unresolved customer billing state",
  };
}

export default async function ShippingReadinessPreviewPage({ params }: { params: Promise<{ shipment_batch_id: string }> }) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const [apResult, customerResult] = await Promise.all([
    (supabase as any).rpc("internal_shipping_ap_recharge_readiness_preview_v1", {
      p_shipment_batch_id: shipmentBatchId,
    }),
    (supabase as any).rpc("internal_shipping_customer_invoice_readiness_preview_v1", {
      p_shipment_batch_id: shipmentBatchId,
    }),
  ]);

  const rows = (apResult.data ?? []) as ReadinessRow[];
  const customerRows = (customerResult.data ?? []) as CustomerInvoicePreviewRow[];
  const customerRowsByLine = new Map(customerRows.map((row) => [lineKey(row), row]));
  const first = rows[0] ?? null;
  const blockers = Array.from(new Set(rows.map((row) => row.blocker).filter(Boolean))) as string[];
  const currency = first?.shipping_document_currency ?? "GBP";
  const totalShippingAllocated = rows.reduce((sum, row) => sum + n(row.allocated_shipping_amount), 0);
  const totalAdjustedGoods = rows.reduce((sum, row) => sum + n(row.adjusted_goods_basis_gbp), 0);
  const itemQty = rows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const customerRoutes = Array.from(new Set(customerRows.map((row) => row.customer_recharge_route).filter(Boolean))) as string[];
  const fallbackCustomerRoutes = Array.from(new Set(rows.map((row) => row.customer_recharge_route).filter(Boolean))) as string[];
  const customerRouteLabels = customerRoutes.length > 0 ? customerRoutes : fallbackCustomerRoutes;
  const primaryCustomerRoute = customerRouteLabels[0] ?? null;
  const apReady = rows.length > 0 && blockers.length === 0;
  const customerStatus = customerInvoiceStatus(customerRows);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/shipping-control">← Shipping control</Link>
            {first?.shipping_document_id ? <Link href={`/internal/shipping-control/shipper-documents/${first.shipping_document_id}`}>Review shipper document</Link> : null}
            {first?.shipping_document_id ? <Link href={`/internal/shipping-control/apportionment/${first.shipping_document_id}`}>Review apportionment</Link> : null}
            <Link href={`/internal/shipping-control/customer-invoice/${shipmentBatchId}`}>Customer invoice preview</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <div className="mt-2 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Shipping AP & customer route preview</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Split view for the shipment batch. Customer billing status comes from the customer invoice readiness preview; shipper AP/shipping readiness remains separate. This page does not post, create COS/BOL/POD, or clear VAT.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{staff.full_name}</div><div>{staff.role_type}</div></div>
          </div>
          {apResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">AP readiness unavailable: {apResult.error.message}</p> : null}
          {customerResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">Customer invoice readiness unavailable: {customerResult.error.message}</p> : null}
          {!first && !apResult.error ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">No readiness rows found for this shipment batch.</p> : null}
        </section>

        {first ? (
          <>
            <section className="grid gap-4 md:grid-cols-3 xl:grid-cols-6">
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Booking ref</p><p className="mt-1 text-xl font-semibold">{first.booking_ref ?? shipmentBatchId}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer</p><p className="mt-1 text-xl font-semibold">{first.importer_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Shipper</p><p className="mt-1 text-xl font-semibold">{first.shipper_name ?? "—"}</p></div>
              <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Item qty</p><p className="mt-1 text-xl font-semibold">{qty(itemQty)}</p></div>
              <div className={`rounded-3xl border p-4 shadow-sm ${customerStatus.className}`}><p className="text-xs uppercase tracking-wide text-slate-500">Customer invoice</p><p className="mt-1 text-xl font-semibold">{customerStatus.label}</p><p className="mt-1 text-xs text-slate-600">{customerStatus.detail}</p></div>
              <div className={`rounded-3xl border p-4 shadow-sm ${apReady ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Shipper AP / shipping</p><p className="mt-1 text-xl font-semibold">{apReady ? "Ready" : "Blocked"}</p><p className="mt-1 text-xs text-slate-600">{apReady ? "AP/recharge payload can be reviewed" : "Does not block main goods invoice"}</p></div>
            </section>

            {blockers.length > 0 ? (
              <section className="rounded-3xl border border-rose-300 bg-rose-50 p-5 text-sm text-rose-900 shadow-sm">
                <h2 className="text-lg font-semibold">Shipper AP / supplementary shipping blocked</h2>
                <p className="mt-1 text-sm leading-6 text-rose-800">These blockers affect shipper AP and later shipping recharge. They do not stop a ready main goods customer invoice draft.</p>
                <ul className="mt-2 list-disc space-y-1 pl-5">
                  {blockers.map((blocker) => <li key={blocker}>{friendly(blocker)}</li>)}
                </ul>
              </section>
            ) : null}

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Route summary</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">This separates customer billing truth from shipper AP/supplementary shipping readiness.</p>
              <div className="mt-4 grid gap-3 lg:grid-cols-2">
                <div className={`rounded-2xl border p-4 ${apReady ? "border-emerald-200 bg-emerald-50" : "border-rose-200 bg-rose-50"}`}>
                  <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Shipper AP / shipping recharge</p>
                  <p className="mt-1 text-lg font-semibold">Purchase invoice to {first.shipper_name ?? "shipper"}</p>
                  <p className="mt-1 text-sm text-slate-600">{first.shipping_document_ref ?? "No ref"} · {money(first.shipping_document_total, currency)}</p>
                  <p className="mt-2 text-xs font-semibold text-slate-600">{apReady ? "Ready for AP/recharge payload review" : "Blocked until shipper invoice/receipt and apportionment are ready"}</p>
                </div>
                <div className={`rounded-2xl border p-4 ${customerStatus.className}`}>
                  <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Customer billing status</p>
                  <p className="mt-1 text-lg font-semibold">{customerStatus.label}</p>
                  <p className="mt-1 text-sm text-slate-600">{customerStatus.detail}</p>
                  <p className="mt-1 text-sm text-slate-600">{money(totalAdjustedGoods, "GBP")} goods basis · {money(totalShippingAllocated, currency)} current shipping allocation</p>
                  <p className="mt-2 text-xs text-slate-500">Route: {routeLabel(primaryCustomerRoute)}</p>
                  <Link href={`/internal/shipping-control/customer-invoice/${shipmentBatchId}`} className="mt-3 inline-block rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Open customer invoice preview</Link>
                </div>
              </div>
            </section>

            <section className="grid gap-4 lg:grid-cols-2">
              <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <h2 className="text-xl font-semibold">AP side</h2>
                <p className="mt-2 text-sm leading-6 text-slate-600">Future accounting document route for the accepted shipper invoice/receipt. This is separate from customer billing status.</p>
                <div className="mt-4 grid gap-3 sm:grid-cols-2">
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Document route</p><p className="mt-1 font-semibold">AP / purchase invoice</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Payable to</p><p className="mt-1 font-semibold">{first.shipper_name ?? "Shipper"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Document ref</p><p className="mt-1 font-semibold">{first.shipping_document_ref ?? "—"}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Document date</p><p className="mt-1 font-semibold">{shortDate(first.shipping_document_date)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Accepted amount</p><p className="mt-1 font-semibold">{money(first.shipping_document_total, currency)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Status</p><span className={`mt-1 inline-block rounded-full px-2 py-1 text-xs font-semibold ${statusClass(first.shipping_document_review_status)}`}>{friendly(first.shipping_document_review_status)}</span></div>
                </div>
              </div>

              <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <h2 className="text-xl font-semibold">Customer/importer side</h2>
                <p className="mt-2 text-sm leading-6 text-slate-600">Shows customer billing status from the customer invoice readiness preview, not from AP route alone.</p>
                <div className="mt-4 grid gap-3 sm:grid-cols-2">
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Adjusted goods basis</p><p className="mt-1 font-semibold">{money(totalAdjustedGoods, "GBP")}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Shipping allocation</p><p className="mt-1 font-semibold">{money(totalShippingAllocated, currency)}</p></div>
                  <div className="rounded-2xl bg-slate-50 p-3 sm:col-span-2"><p className="text-xs uppercase tracking-wide text-slate-500">Route</p><div className="mt-2 flex flex-wrap gap-2">{customerRouteLabels.length ? customerRouteLabels.map((route) => <span key={route} className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(route)}`}>{routeLabel(route)}</span>) : <span className="text-sm font-semibold">—</span>}</div></div>
                </div>
              </div>
            </section>

            <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <h2 className="text-xl font-semibold">Line-level route preview</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">Each row shows customer billing readiness separately from AP/shipping readiness. COS/export evidence stays separate.</p>

              <div className="mt-4 grid gap-3 md:hidden">
                {rows.map((row, index) => {
                  const customerPreview = customerRowsByLine.get(lineKey(row));
                  const customerLine = customerLineStatus(customerPreview);
                  return (
                    <article key={`${row.order_id}-${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}-card`} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Order / package</p>
                          <p className="mt-1 font-semibold">{row.order_ref ?? row.order_id ?? "—"}</p>
                          <p className="text-sm text-slate-500">{row.tracking_ref ?? row.tracking_submission_id ?? "—"}</p>
                        </div>
                        <div className="flex shrink-0 flex-col items-end gap-1">
                          <span className={`rounded-full px-2 py-1 text-xs font-semibold ${customerLine.chipClassName}`}>Customer: {customerLine.shortLabel}</span>
                          <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.readiness_status)}`}>AP: {readinessLabel(row.readiness_status)}</span>
                        </div>
                      </div>
                      <p className="mt-3 text-sm text-slate-700">{row.item_description ?? "—"}</p>
                      <div className="mt-4 grid grid-cols-3 gap-2 text-sm">
                        <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Qty</p><p className="mt-1 font-semibold">{qty(row.qty_allocated)}</p></div>
                        <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Basis</p><p className="mt-1 font-semibold">{money(row.adjusted_goods_basis_gbp, "GBP")}</p></div>
                        <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Shipping</p><p className="mt-1 font-semibold">{money(row.allocated_shipping_amount, currency)}</p></div>
                      </div>
                      <div className="mt-3 rounded-xl bg-white p-3 text-sm">
                        <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Customer route</p>
                        <div className="mt-2 flex flex-wrap items-center gap-2">
                          <span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(customerPreview?.customer_recharge_route ?? row.customer_recharge_route)}`}>{routeLabel(customerPreview?.customer_recharge_route ?? row.customer_recharge_route)}</span>
                          <span className="text-xs text-slate-500">{invoiceStateLabel(customerPreview?.sales_invoice_state ?? row.sales_invoice_state)}</span>
                        </div>
                      </div>
                    </article>
                  );
                })}
              </div>

              <div className="mt-4 hidden overflow-x-auto rounded-2xl border border-slate-200 md:block">
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="px-3 py-2 text-left">Order / package</th>
                      <th className="px-3 py-2 text-left">Item</th>
                      <th className="px-3 py-2 text-right">Qty</th>
                      <th className="px-3 py-2 text-right">Adjusted basis</th>
                      <th className="px-3 py-2 text-right">Shipping</th>
                      <th className="px-3 py-2 text-left">Customer route</th>
                      <th className="px-3 py-2 text-left">Split status</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100 bg-white">
                    {rows.map((row, index) => {
                      const customerPreview = customerRowsByLine.get(lineKey(row));
                      const customerLine = customerLineStatus(customerPreview);
                      return (
                        <tr key={`${row.order_id}-${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${index}`}>
                          <td className="px-3 py-3 align-top"><p className="font-semibold">{row.order_ref ?? row.order_id ?? "—"}</p><p className="text-xs text-slate-500">{row.tracking_ref ?? row.tracking_submission_id ?? "—"}</p></td>
                          <td className="px-3 py-3 align-top">{row.item_description ?? "—"}</td>
                          <td className="px-3 py-3 text-right align-top">{qty(row.qty_allocated)}</td>
                          <td className="px-3 py-3 text-right align-top">{money(row.adjusted_goods_basis_gbp, "GBP")}</td>
                          <td className="px-3 py-3 text-right align-top font-semibold">{money(row.allocated_shipping_amount, currency)}</td>
                          <td className="px-3 py-3 align-top"><span className={`rounded-full px-2 py-1 text-xs font-semibold ${statusClass(customerPreview?.customer_recharge_route ?? row.customer_recharge_route)}`}>{routeLabel(customerPreview?.customer_recharge_route ?? row.customer_recharge_route)}</span><p className="mt-1 text-xs text-slate-500">{invoiceStateLabel(customerPreview?.sales_invoice_state ?? row.sales_invoice_state)}</p></td>
                          <td className="px-3 py-3 align-top"><div className="flex flex-col gap-2"><span className={`w-fit rounded-full px-2 py-1 text-xs font-semibold ${customerLine.chipClassName}`}>Customer: {customerLine.shortLabel}</span><span className={`w-fit rounded-full px-2 py-1 text-xs font-semibold ${statusClass(row.readiness_status)}`}>AP: {readinessLabel(row.readiness_status)}</span></div></td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            </section>

            <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
              <h2 className="font-semibold">Control rule</h2>
              <p className="mt-2">This page only resolves the next accounting route. Customer billing status, shipper AP invoice posting, supplementary shipping recharge, draft COS review, master shipment grouping and final export evidence clearance remain separate controlled steps.</p>
            </section>
          </>
        ) : null}
      </div>
    </main>
  );
}
