import { NextResponse } from "next/server";

export async function GET(request: Request, { params }: { params: Promise<{ order_id: string; invoice_id: string }> }) {
  const { order_id: orderId, invoice_id: invoiceId } = await params;
  const url = new URL(request.url);
  url.pathname = `/customer/orders/${orderId}/invoice-pdf/${invoiceId}`;
  return NextResponse.redirect(url);
}
