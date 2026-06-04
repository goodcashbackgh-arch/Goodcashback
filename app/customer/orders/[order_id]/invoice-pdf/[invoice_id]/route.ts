import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { sageApiFetch } from "@/lib/sage/server-token";

function safeName(value: string | null | undefined) {
  return String(value || "invoice")
    .replace(/[^a-z0-9._-]+/gi, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "invoice";
}

function customerFileName(orderRef: string | null | undefined, invoiceType: string | null | undefined) {
  const base = safeName(String(orderRef || "order").replace(/^ORD-/i, ""));
  if (invoiceType === "supplementary") return `GCB-${base}-supplementary-invoice.pdf`;
  if (invoiceType === "credit_note") return `GCB-${base}-credit-note.pdf`;
  return `GCB-${base}-invoice.pdf`;
}

async function fetchSageInvoicePdf(sageInvoiceId: string, origin: string) {
  const response = await sageApiFetch(`/sales_invoices/${encodeURIComponent(sageInvoiceId)}`, {
    method: "GET",
    headers: { Accept: "application/pdf" },
  }, { origin });

  const contentType = response.headers.get("content-type") ?? "";
  if (!response.ok) return null;
  if (!contentType.toLowerCase().includes("application/pdf")) return null;
  return Buffer.from(await response.arrayBuffer());
}

export async function GET(request: Request, { params }: { params: Promise<{ order_id: string; invoice_id: string }> }) {
  const { order_id: orderId, invoice_id: invoiceId } = await params;
  const origin = new URL(request.url).origin;
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Unauthenticated", { status: 401 });

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!operator) return new NextResponse("Forbidden", { status: 403 });

  const { data: invoice } = await (supabaseAdmin as any)
    .from("sales_invoices")
    .select("id, invoice_type, sage_invoice_id, sage_status, orders(order_ref, importer_id)")
    .eq("id", invoiceId)
    .eq("order_id", orderId)
    .eq("sage_status", "posted")
    .not("sage_invoice_id", "is", null)
    .maybeSingle();
  if (!invoice) return new NextResponse("Invoice not found", { status: 404 });

  const order = Array.isArray(invoice.orders) ? invoice.orders[0] : invoice.orders;
  const importerId = order?.importer_id;
  if (!importerId) return new NextResponse("Invoice order not found", { status: 404 });

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", importerId)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!access) return new NextResponse("Forbidden", { status: 403 });

  const pdf = await fetchSageInvoicePdf(String(invoice.sage_invoice_id), origin);
  if (!pdf) return new NextResponse("Unable to fetch Sage PDF", { status: 502 });

  return new NextResponse(pdf, {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="${customerFileName(order?.order_ref, invoice.invoice_type)}"`,
      "Cache-Control": "private, no-store",
    },
  });
}
