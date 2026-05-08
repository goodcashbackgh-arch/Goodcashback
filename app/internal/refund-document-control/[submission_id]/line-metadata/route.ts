import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ submission_id: string }> },
) {
  const { submission_id: submissionId } = await params;
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });
  }

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) {
    return NextResponse.json({ error: "Forbidden" }, { status: 403 });
  }

  const { data, error } = await supabase
    .from("dispute_refund_document_lines")
    .select("id, retailer_sku, size, qty")
    .eq("refund_evidence_submission_id", submissionId)
    .order("line_order", { ascending: true });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  return NextResponse.json({ lines: data ?? [] });
}
