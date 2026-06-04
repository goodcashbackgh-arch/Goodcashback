import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { sageApiFetch } from "@/lib/sage/server-token";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";

const FINAL_INVOICE_BUCKET = "invoice-evidence";

type SalesInvoiceRow = {
  id: string;
  order_id: string;
  amount_gbp: number | string | null;
  invoice_type: string | null;
  sage_invoice_date: string | null;
  sage_invoice_id: string | null;
  sage_posted_at: string | null;
  sage_reference?: string | null;
  sage_status: string | null;
};

function safeName(value: string | null | undefined) {
  return (value || "final-invoice")
    .replace(/[^a-z0-9._-]+/gi, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "final-invoice";
}

async function requireCustomerOrderAccess(orderId: string) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: new NextResponse("Unauthenticated", { status: 401 }) };

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!operator) return { error: new NextResponse("Active customer account required", { status: 403 }) };

  const { data: order } = await supabase
    .from("orders")
    .select("id, order_ref, importer_id")
    .eq("id", orderId)
    .maybeSingle();
  if (!order) return { error: new NextResponse("Order not found", { status: 404 }) };

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", (order as any).importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!access) return { error: new NextResponse("You do not have access to this order", { status: 403 }) };

  return { supabase, order };
}

async function fetchSageInvoicePdf(sageInvoiceId: string, origin: string) {
  const response = await sageApiFetch(`/sales_invoices/${encodeURIComponent(sageInvoiceId)}`, {
    method: "GET",
    headers: { Accept: "application/pdf" },
  }, { origin });

  const contentType = response.headers.get("content-type") ?? "";
  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`Sage PDF fetch failed (${response.status} ${response.statusText}): ${body.slice(0, 300)}`);
  }

  if (!contentType.toLowerCase().includes("application/pdf")) {
    const body = await response.text().catch(() => "");
    throw new Error(`Sage returned ${contentType || "unknown content-type"}, not application/pdf. Body: ${body.slice(0, 300)}`);
  }

  return Buffer.from(await response.arrayBuffer());
}

function pdfResponse(pdf: Buffer, filename: string, source: "stored" | "sage", storageStatus?: string) {
  const headers: Record<string, string> = {
    "Content-Type": "application/pdf",
    "Content-Disposition": `attachment; filename="${filename}"`,
    "Cache-Control": "private, no-store",
    "X-GCB-Invoice-Source": source,
  };
  if (storageStatus) headers["X-GCB-Invoice-Storage"] = storageStatus;
  return new NextResponse(pdf, { headers });
}

export async function GET(request: Request, { params }: { params: Promise<{ order_id: string }> }) {
  const { order_id: orderId } = await params;
  const access = await requireCustomerOrderAccess(orderId);
  if ("error" in access && access.error) return access.error;

  const { order } = access as { order: any };
  const origin = new URL(request.url).origin;

  const { data: invoiceRows, error: invoiceError } = await supabaseAdmin
    .from("sales_invoices")
    .select("id, order_id, amount_gbp, invoice_type, sage_invoice_date, sage_invoice_id, sage_posted_at, sage_reference, sage_status")
    .eq("order_id", orderId)
    .eq("sage_status", "posted")
    .not("sage_invoice_id", "is", null)
    .in("invoice_type", ["main", "supplementary"])
    .order("sage_posted_at", { ascending: false });

  if (invoiceError) return new NextResponse(`Unable to find final invoice: ${invoiceError.message}`, { status: 400 });

  const invoices = (invoiceRows ?? []) as SalesInvoiceRow[];
  const invoice = invoices.find((row) => row.invoice_type === "main") ?? invoices[0];
  const sageInvoiceId = String(invoice?.sage_invoice_id ?? "").trim();
  if (!invoice || !sageInvoiceId) return new NextResponse("Final invoice is not available yet", { status: 404 });

  const invoiceRef = String(invoice.sage_reference ?? invoice.id).trim();
  const filename = `${safeName(order.order_ref || orderId)}-${safeName(invoiceRef)}-final-invoice.pdf`;
  const objectPath = `customer-final-invoices/${order.importer_id}/${orderId}/${invoice.id}.pdf`;
  const bucket = supabaseAdmin.storage.from(FINAL_INVOICE_BUCKET);

  const stored = await bucket.download(objectPath);
  if (stored.data) {
    const storedPdf = Buffer.from(await stored.data.arrayBuffer());
    return pdfResponse(storedPdf, filename, "stored");
  }

  let pdf: Buffer;
  try {
    pdf = await fetchSageInvoicePdf(sageInvoiceId, origin);
  } catch (error) {
    return new NextResponse(error instanceof Error ? error.message : "Unable to retrieve final invoice from Sage", { status: 502 });
  }

  const upload = await bucket.upload(objectPath, pdf, {
    contentType: "application/pdf",
    upsert: true,
  });

  return pdfResponse(pdf, filename, "sage", upload.error ? `store_failed: ${upload.error.message}` : "stored");
}
