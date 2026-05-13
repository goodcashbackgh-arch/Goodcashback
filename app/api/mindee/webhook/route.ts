import { NextResponse } from "next/server";

// Generic Mindee webhook placeholder kept for supplier/retailer invoice webhook compatibility.
// Shipper document OCR must use /api/mindee/shipping-webhook, not this route.
// The current retailer/supplier invoice OCR flow uses explicit staff fetch/save actions, not this webhook.
export async function POST(request: Request) {
  const secret = process.env.MINDEE_WEBHOOK_SECRET?.trim();
  if (secret) {
    const supplied = request.headers.get("x-goodcashback-webhook-secret")?.trim();
    if (supplied !== secret) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const raw = await request.json().catch(() => null);
  if (!raw || typeof raw !== "object") return NextResponse.json({ error: "invalid json" }, { status: 400 });

  return NextResponse.json({
    ok: true,
    route: "generic_mindee_webhook_noop",
    note: "Supplier invoice OCR uses explicit staff fetch/save. Shipper document OCR uses /api/mindee/shipping-webhook.",
  });
}
