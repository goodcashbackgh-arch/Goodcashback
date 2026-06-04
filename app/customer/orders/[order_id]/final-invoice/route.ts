import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { sageApiFetch } from "@/lib/sage/server-token";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";

const BUCKET = "invoice-evidence";

type OrderRow = { id: string; order_ref: string | null; importer_id: string };
type InvoiceRow = {
  id: string;
  amount_gbp: number | string | null;
  invoice_type: string | null;
  sage_invoice_date: string | null;
  sage_invoice_id: string | null;
  sage_posted_at: string | null;
  sage_status: string | null;
};

function safeName(value: string | null | undefined) {
  return (value || "final-invoice").replace(/[^a-z0-9._-]+/gi, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "final-invoice";
}

async function getOrderForCustomer(orderId: string): Promise<OrderRow | NextResponse> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Sign in required", { status: 401 });

  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) return new NextResponse("Customer account required", { status: 403 });

  const { data: orderData } = await supabase.from("orders").select("id, order_ref, importer_id").eq("id", orderId).maybeSingle();
  const order = orderData as OrderRow | null;
  if (!order) return new NextResponse("Order not found", { status: 404 });

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (!access) return new NextResponse("No access to this order", { status: 403 });
  return order;
}

async function fetchSagePdf(sageInvoiceId: string, origin: string) {
  const response = await sageApiFetch(`/sales_invoices/${encodeURIComponent(sageInvoiceId)}`, { method: "GET", headers: { Accept: "application/pdf" } }, { origin });
  const contentType = response.headers.get("content-type") ?? "";
  if (!response.ok) throw new Error(`Sage PDF fetch failed (${response.status} ${response.statusText})`);
  if (!contentType.toLowerCase().includes("application/pdf")) throw new Error(`Sage returned ${contentType || "unknown content-type"}, not application/pdf.`);
  return Buffer.from(await response.arrayBuffer());
}

function servePdf(pdf: Buffer, filename: string, source: "stored" | "sage") {
  return new NextResponse(pdf, {
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="${filename}"`,
      "Cache-Control": "private, no-store",
      "X-GCB-Invoice-Source": source,
    },
  });
}

export async function GET(request: Request, { params }: { params: Promise<{ order_id: string }> }) {
  const { order_id: orderId } = await params;
  const orderOrResponse = await getOrderForCustomer(orderId);
  if (orderOrResponse instanceof NextResponse) return orderOrResponse;
  const order = orderOrResponse;

  const { data, error } = await (supabaseAdmin as any)
    .from("sales_invoices")
    .select("id, amount_gbp, invoice_type, sage_invoice_date, sage_invoice_id, sage_posted_at, sage_status")
    .eq("order_id", orderId)
    .eq("sage_status", "posted")
    .not("sage_invoice_id", "is", null)
    .in("invoice_type", ["main", "supplementary"])
    .order("sage_posted_at", { ascending: false });

  if (error) return new NextResponse(`Unable to find final invoice: ${error.message}`, { status: 400 });
  const invoices = (data ?? []) as InvoiceRow[];
  const invoice = invoices.find((row) => row.invoice_type === "main") ?? invoices[0];
  const sageInvoiceId = String(invoice?.sage_invoice_id ?? "").trim();
  if (!invoice || !sageInvoiceId) return new NextResponse("Final invoice is not available yet", { status: 404 });

  const filename = `${safeName(order.order_ref || orderId)}-${safeName(invoice.id)}-final-invoice.pdf`;
  const objectPath = `customer-final-invoices/${order.importer_id}/${orderId}/${invoice.id}.pdf`;
  const bucket = supabaseAdmin.storage.from(BUCKET);

  const stored = await bucket.download(objectPath);
  if (stored.data) return servePdf(Buffer.from(await stored.data.arrayBuffer()), filename, "stored");

  let pdf: Buffer;
  try {
    pdf = await fetchSagePdf(sageInvoiceId, new URL(request.url).origin);
  } catch (err) {
    return new NextResponse(err instanceof Error ? err.message : "Unable to retrieve final invoice", { status: 502 });
  }

  await bucket.upload(objectPath, pdf, { contentType: "application/pdf", upsert: true });
  return servePdf(pdf, filename, "sage");
}
