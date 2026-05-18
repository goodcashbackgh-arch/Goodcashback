import { NextResponse } from "next/server";
import { getValidSageAccessToken } from "@/lib/sage/server-token";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorised(request: Request) {
  const secret = process.env.CRON_SECRET?.trim() || "";
  if (!secret) return false;
  const auth = request.headers.get("authorization") || "";
  return auth === `Bearer ${secret}`;
}

export async function GET(request: Request) {
  if (!authorised(request)) {
    return NextResponse.json({ ok: false, error: "Unauthorized" }, { status: 401 });
  }

  try {
    const result = await getValidSageAccessToken({ origin: new URL(request.url).origin, forceRefresh: true });
    return NextResponse.json({ ok: true, connection_id: result.connectionId, refreshed: result.refreshed, access_expires_at: result.expiresAt });
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : "Sage keepalive failed" }, { status: 500 });
  }
}
