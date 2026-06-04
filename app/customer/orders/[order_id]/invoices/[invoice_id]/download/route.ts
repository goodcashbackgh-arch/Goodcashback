import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";

type InvoicePayloadLine = Record<string, unknown>;

function money(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function formatDate(value: string | null | undefined) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(date);
}

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function invoiceTypeLabel(value: string | null | undefined) {
  if (value === "main") return "Main invoice";
  if (value === "supplementary") return "Supplementary invoice";
  if (value === "credit_note") return "Credit note";
  return String(value ?? "Invoice").replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function invoiceNumber(orderRef: string | null | undefined, invoiceType: string | null | undefined, index = 1) {
  const base = (orderRef || "order").replace(/^ORD-/i, "");
  const suffix = invoiceType === "supplementary" ? `SUP-${index}` : invoiceType === "credit_note" ? `CN-${index}` : "MAIN";
  return `GCB-${base}-${suffix}`;
}

function safeFilename(value: string) {
  return value.replace(/[^a-z0-9._-]+/gi, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "invoice";
}

function extractLines(payload: unknown, amountGbp: unknown): InvoicePayloadLine[] {
  const candidate = payload && typeof payload === "object" && !Array.isArray(payload) ? (payload as Record<string, unknown>).lines : null;
  if (Array.isArray(candidate) && candidate.length > 0) return candidate.filter((line) => line && typeof line === "object") as InvoicePayloadLine[];
  return [{ description: "Customer invoice", quantity: 1, total_line_amount_gbp: amountGbp }];
}

export async function GET(_request: Request, { params }: { params: Promise<{ order_id: string; invoice_id: string }> }) {
  const { order_id: orderId, invoice_id: invoiceId } = await params;
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

  const { data: invoice, error } = await (supabaseAdmin as any)
    .from("sales_invoices")
    .select("id, order_id, amount_gbp, invoice_type, sage_status, sage_invoice_id, sage_invoice_date, sage_posted_at, line_items_json, orders(order_ref, importer_id, importers(company_name, trading_name))")
    .eq("id", invoiceId)
    .eq("order_id", orderId)
    .eq("sage_status", "posted")
    .not("sage_invoice_id", "is", null)
    .maybeSingle();

  if (error || !invoice) return new NextResponse("Invoice not found", { status: 404 });

  const order = Array.isArray(invoice.orders) ? invoice.orders[0] : invoice.orders;
  const importer = Array.isArray(order?.importers) ? order.importers[0] : order?.importers;
  const importerId = order?.importer_id;
  const orderRef = order?.order_ref ?? orderId;
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

  const displayNumber = invoiceNumber(orderRef, invoice.invoice_type);
  const customerName = importer?.trading_name || importer?.company_name || "Customer";
  const lines = extractLines(invoice.line_items_json, invoice.amount_gbp);
  const rows = lines.map((line) => {
    const description = line.description ?? line.source_description ?? "Invoice line";
    const quantity = Number(line.quantity ?? 1);
    const lineTotal = line.total_line_amount_gbp ?? line.line_amount_gbp ?? line.amount_gbp ?? invoice.amount_gbp;
    return `<tr><td>${escapeHtml(description)}</td><td class="num">${escapeHtml(Number.isFinite(quantity) ? quantity : 1)}</td><td class="num">${escapeHtml(money(lineTotal))}</td></tr>`;
  }).join("");

  const html = `<!doctype html>
<html><head><meta charset="utf-8" /><title>${escapeHtml(displayNumber)}</title><style>
body{font-family:Arial,sans-serif;color:#0f172a;margin:40px;line-height:1.5}.top{border-bottom:4px solid #38bdf8;padding-bottom:16px;margin-bottom:24px}.label{color:#64748b;text-transform:uppercase;font-size:12px;font-weight:700;letter-spacing:.12em}h1{font-size:34px;margin:6px 0 0}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin:24px 0}.card{border:1px solid #e2e8f0;border-radius:16px;padding:16px;background:#f8fafc}table{width:100%;border-collapse:collapse;margin-top:24px}th,td{border-bottom:1px solid #e2e8f0;padding:12px;text-align:left}th{background:#f8fafc}.num{text-align:right}.total{margin-top:24px;text-align:right;font-size:24px;font-weight:800}.muted{color:#64748b;font-size:12px;margin-top:28px}
</style></head><body>
<div class="top"><div class="label">Goodcashback customer invoice</div><h1>${escapeHtml(displayNumber)}</h1></div>
<div class="grid"><div class="card"><div class="label">Customer</div><strong>${escapeHtml(customerName)}</strong></div><div class="card"><div class="label">Order</div><strong>${escapeHtml(orderRef)}</strong></div><div class="card"><div class="label">Invoice type</div><strong>${escapeHtml(invoiceTypeLabel(invoice.invoice_type))}</strong></div><div class="card"><div class="label">Issued</div><strong>${escapeHtml(formatDate(invoice.sage_invoice_date ?? invoice.sage_posted_at))}</strong></div></div>
<table><thead><tr><th>Description</th><th class="num">Qty</th><th class="num">Amount</th></tr></thead><tbody>${rows}</tbody></table>
<div class="total">Total ${escapeHtml(money(invoice.amount_gbp))}</div>
<p class="muted">Generated from the posted Goodcashback customer invoice for this order.</p>
</body></html>`;

  return new NextResponse(html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Disposition": `attachment; filename="${safeFilename(displayNumber)}.html"`,
      "Cache-Control": "private, no-store",
    },
  });
}
