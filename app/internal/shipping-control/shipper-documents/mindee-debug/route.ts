import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

const MINDEE_V2_API_BASE = "https://api-v2.mindee.net/v2";

function cleanText(value: unknown) {
  return String(value ?? "").trim();
}

function getMindeeKey() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

async function fetchMindee(path: string, apiKey: string) {
  const response = await fetch(`${MINDEE_V2_API_BASE}${path}`, {
    method: "GET",
    headers: { Accept: "application/json", Authorization: apiKey },
    cache: "no-store",
  });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  return {
    url: `${MINDEE_V2_API_BASE}${path}`,
    status: response.status,
    ok: response.ok,
    raw,
  };
}

export async function GET(request: Request) {
  const url = new URL(request.url);
  const shippingDocumentId = cleanText(url.searchParams.get("shipping_document_id"));

  if (!shippingDocumentId) {
    return NextResponse.json({ error: "shipping_document_id query parameter is required" }, { status: 400 });
  }

  const apiKey = getMindeeKey();
  if (!apiKey) {
    return NextResponse.json({ error: "MINDEE_V2_API_KEY is not configured" }, { status: 500 });
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "not authenticated" }, { status: 401 });

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return NextResponse.json({ error: "admin/supervisor staff required" }, { status: 403 });
  }

  const { data: contextData, error: contextError } = await (supabase as any).rpc("internal_shipping_mindee_polling_context_v1", {
    p_shipping_document_id: shippingDocumentId,
  });

  if (contextError) return NextResponse.json({ error: contextError.message }, { status: 500 });
  const doc = Array.isArray(contextData) ? contextData[0] : null;
  if (!doc) return NextResponse.json({ error: "shipping document not found" }, { status: 404 });

  const jobId = cleanText(doc.mindee_job_id);
  const inferenceId = cleanText(doc.mindee_inference_id);
  const output: Record<string, unknown> = {
    ok: true,
    route: "shipping_mindee_raw_debug",
    note: "This endpoint does not send the document to Mindee. It only reads stored ids and fetches raw Mindee job/inference responses for debugging.",
    shipping_document: {
      shipping_document_id: doc.shipping_document_id,
      ocr_status: doc.ocr_status,
      review_status: doc.review_status,
      mindee_model_id: doc.mindee_model_id,
      mindee_job_id: doc.mindee_job_id,
      mindee_inference_id: doc.mindee_inference_id,
      polling_url: doc.polling_url,
      result_url: doc.result_url,
    },
    mindee: {},
  };

  const mindee: Record<string, unknown> = {};
  if (jobId) mindee.job = await fetchMindee(`/jobs/${encodeURIComponent(jobId)}`, apiKey);
  if (inferenceId) mindee.inference = await fetchMindee(`/inferences/${encodeURIComponent(inferenceId)}`, apiKey);
  output.mindee = mindee;

  return NextResponse.json(output, { status: 200 });
}
