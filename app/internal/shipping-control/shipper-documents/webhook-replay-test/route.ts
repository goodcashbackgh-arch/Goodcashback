import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

export async function GET(request: Request) {
  const url = new URL(request.url);
  const shippingDocumentId = cleanText(url.searchParams.get("shipping_document_id"));

  if (!shippingDocumentId) {
    return NextResponse.json({ ok: false, error: "shipping_document_id is required" }, { status: 400 });
  }

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

  const { data: beforeData, error: beforeError } = await (supabase as any).rpc("internal_shipping_mindee_replay_context_v1", {
    p_shipping_document_id: shippingDocumentId,
  });

  if (beforeError) return NextResponse.json({ ok: false, error: beforeError.message }, { status: 500 });

  const before = Array.isArray(beforeData) ? beforeData[0] : null;
  if (!before) return NextResponse.json({ ok: false, error: "active shipping document not found" }, { status: 404 });
  if (!before.ocr_raw_json) {
    return NextResponse.json({
      ok: false,
      error: "shipping document has no saved ocr_raw_json to replay",
      shipping_document_id: shippingDocumentId,
      document_ref: before.document_ref,
      ocr_status: before.ocr_status,
    }, { status: 400 });
  }

  const origin = new URL(request.url).origin;
  const target = `${origin}/api/mindee/shipping-webhook`;
  const response = await fetch(target, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(before.ocr_raw_json),
    cache: "no-store",
  });

  const body = await response.json().catch(async () => ({
    non_json_body: await response.text().catch(() => null),
  }));

  const { data: afterData, error: afterError } = await (supabase as any).rpc("internal_shipping_mindee_replay_context_v1", {
    p_shipping_document_id: shippingDocumentId,
  });

  const after = Array.isArray(afterData) ? afterData[0] : null;

  return NextResponse.json({
    ok: response.ok && !afterError,
    route: "shipping_ocr_webhook_replay_test",
    note: "No Mindee call and no OCR credit used. This replays the saved raw OCR JSON through the real shipping webhook POST route using staff-secured context only.",
    target,
    webhook_http_status: response.status,
    webhook_response: body,
    before: {
      shipping_document_id: before.shipping_document_id,
      document_ref: before.document_ref,
      ocr_status: before.ocr_status,
      review_status: before.review_status,
      line_count: before.line_count ?? 0,
    },
    after_error: afterError?.message ?? null,
    after: after ? {
      shipping_document_id: after.shipping_document_id,
      document_ref: after.document_ref,
      ocr_status: after.ocr_status,
      review_status: after.review_status,
      line_count: after.line_count ?? 0,
    } : null,
  }, { status: response.ok && !afterError ? 200 : 500 });
}
