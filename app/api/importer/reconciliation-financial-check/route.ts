import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

function asNumber(value: unknown) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const orderId = searchParams.get("order_id")?.trim();

  if (!orderId) {
    return NextResponse.json({ error: "Missing order_id" }, { status: 400 });
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json({ error: "Not signed in" }, { status: 401 });
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    return NextResponse.json({ error: "Operator account required" }, { status: 403 });
  }

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, importer_id, order_ref, total_qty_declared, order_total_gbp_declared")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) {
    return NextResponse.json({ error: "Order not found" }, { status: 404 });
  }

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (!access) {
    return NextResponse.json({ error: "No access to this order" }, { status: 403 });
  }

  const { data: invoice } = await supabase
    .from("supplier_invoices")
    .select("id, invoice_ref")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!invoice) {
    return NextResponse.json({
      order_id: orderId,
      order_ref: order.order_ref,
      has_invoice: false,
    });
  }

  const [{ data: lines }, { data: adjustments }, { data: summary }] = await Promise.all([
    supabase
      .from("supplier_invoice_lines")
      .select("qty, amount_inc_vat_gbp")
      .eq("supplier_invoice_id", invoice.id),
    supabase
      .from("order_value_adjustments")
      .select("adjustment_type, amount_gbp, approval_status")
      .eq("order_id", orderId)
      .eq("supplier_invoice_id", invoice.id),
    supabase
      .from("supplier_invoice_financial_summary")
      .select("invoice_total_gbp")
      .eq("supplier_invoice_id", invoice.id)
      .maybeSingle(),
  ]);

  const goodsQty = (lines ?? []).reduce((sum, line) => sum + asNumber(line.qty), 0);
  const goodsAmount = (lines ?? []).reduce((sum, line) => sum + asNumber(line.amount_inc_vat_gbp), 0);
  const deliveryTotal = (adjustments ?? [])
    .filter((row) => row.adjustment_type === "retailer_delivery")
    .reduce((sum, row) => sum + asNumber(row.amount_gbp), 0);
  const discountTotal = (adjustments ?? [])
    .filter((row) => row.adjustment_type === "retailer_discount")
    .reduce((sum, row) => sum + asNumber(row.amount_gbp), 0);
  const pendingSupervisorCount = (adjustments ?? []).filter((row) => row.approval_status === "pending_supervisor").length;
  const invoiceTotal = summary ? asNumber(summary.invoice_total_gbp) : null;
  const expectedInvoiceTotal = goodsAmount + deliveryTotal - discountTotal;
  const invoiceVariance = invoiceTotal === null ? null : expectedInvoiceTotal - invoiceTotal;
  const financialMatched = invoiceVariance !== null && Math.abs(invoiceVariance) < 0.01;
  const declaredQty = asNumber(order.total_qty_declared);
  const declaredAmount = asNumber(order.order_total_gbp_declared);

  return NextResponse.json({
    order_id: orderId,
    order_ref: order.order_ref,
    has_invoice: true,
    invoice_id: invoice.id,
    invoice_ref: invoice.invoice_ref,
    declared_qty: declaredQty,
    declared_amount_gbp: declaredAmount,
    goods_qty: goodsQty,
    goods_amount_gbp: goodsAmount,
    order_qty_variance: goodsQty - declaredQty,
    order_value_variance_gbp: goodsAmount - declaredAmount,
    delivery_total_gbp: deliveryTotal,
    discount_total_gbp: discountTotal,
    expected_invoice_total_gbp: expectedInvoiceTotal,
    invoice_total_gbp: invoiceTotal,
    invoice_variance_gbp: invoiceVariance,
    financial_matched: financialMatched,
    pending_supervisor_count: pendingSupervisorCount,
  });
}
