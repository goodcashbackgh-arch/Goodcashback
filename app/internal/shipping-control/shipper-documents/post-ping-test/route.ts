import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

export async function GET(request: Request) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ ok: false, error: "not authenticated" }, { status: 401 });

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return NextResponse.json({ ok: false, error: "admin/supervisor staff required" }, { status: 403 });
  }

  const origin = new URL(request.url).origin;
  const target = `${origin}/api/mindee/shipping-webhook?ping=1`;
  const response = await fetch(target, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ ping: true }),
    cache: "no-store",
  });
  const body = await response.json().catch(() => null);

  return NextResponse.json({
    ok: response.ok,
    route: "shipping_ocr_post_ping_test",
    note: "No Mindee call, no OCR credit, no OCR result processing. This only proves the POST handler is reachable.",
    target,
    status: response.status,
    response: body,
  });
}
