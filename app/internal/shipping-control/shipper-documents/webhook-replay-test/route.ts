import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";

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

  const { data: doc, error: docError } = await supabaseAdmin
    .from("shipping_documents")
    .select("id, document_ref, ocr_status, review_status, mindee_job_id, mindee_inference_id, ocr_raw_json")
    .eq("id", shippingDocumentId)
    .eq("active", true)
    .maybeSingle();

  if (docError) return NextResponse.json({ ok: false, error: docError.message }, { status: 500 });
  if (!doc) return NextResponse.json({ ok: false, error: "active shipping document not found" }, { status: 404 });
  if (!doc.ocr_raw_json) {
    return NextResponse.json({
      ok: false,
      error: "shipping document has no saved ocr_raw_json to replay",
      shipping_document_id: shippingDocumentId,
      document_ref: doc.document_ref,
      ocr_status: doc.ocr_status,
    }, { status: 400 });
  }

  const { count: beforeLineCount } = await supabaseAdmin
    .from("shipping_document_ocr_lines")
    .select("id", { count: "exact", head: true })
    .eq("shipping_document_id", shippingDocumentId);

  const origin = new URL(request.url).origin;
  const target = `${origin}/api/mindee/shipping-webhook`;
  const response = await fetch(target, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(doc.ocr_raw_json),
    cache: "no-store",
  });

  const body = await response.json().catch(async () => ({
    non_json_body: await response.text().catch(() => null),
  }));

  const { data: afterDoc } = await supabaseAdmin
    .from("shipping_documents")
    .select("id, document_ref, ocr_status, review_status, ocr_match_status, ocr_document_ref, ocr_document_date, ocr_total_amount, ocr_shipper_name")
    .eq("id", shippingDocumentId)
    .maybeSingle();

  const { count: afterLineCount } = await supabaseAdmin
    .from("shipping_document_ocr_lines")
    .select("id", { count: "exact", head: true })
    .eq("shipping_document_id", shippingDocumentId);

  return NextResponse.json({
    ok: response.ok,
    route: "shipping_ocr_webhook_replay_test",
    note: "No Mindee call and no OCR credit used. This replays the saved raw OCR JSON through the real shipping webhook POST route.",
    target,
    webhook_http_status: response.status,
    webhook_response: body,
    before: {
      shipping_document_id: shippingDocumentId,
      document_ref: doc.document_ref,
      ocr_status: doc.ocr_status,
      review_status: doc.review_status,
      line_count: beforeLineCount ?? 0,
    },
    after: {
      ...afterDoc,
      line_count: afterLineCount ?? 0,
    },
  }, { status: response.ok ? 200 : 500 });
}
