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
    .from("dispute_refund_evidence_submissions")
    .select("supervisor_review_status, evidence_control_status, supplier_readiness_route, supplier_approval_status, supplier_control_status")
    .eq("id", submissionId)
    .maybeSingle();

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  if (!data) {
    return NextResponse.json({ error: "Refund evidence submission not found" }, { status: 404 });
  }

  const auditOnly =
    data.supervisor_review_status === "rejected" ||
    data.evidence_control_status === "staff_rejected_resubmission_required" ||
    data.supplier_readiness_route === "operator_resubmission_required";

  return NextResponse.json({
    auditOnly,
    supervisor_review_status: data.supervisor_review_status,
    evidence_control_status: data.evidence_control_status,
    supplier_readiness_route: data.supplier_readiness_route,
    supplier_approval_status: data.supplier_approval_status,
    supplier_control_status: data.supplier_control_status,
  });
}
