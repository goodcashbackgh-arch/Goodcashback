import { createClient } from "@/utils/supabase/server";
import AllocationResultToast from "./AllocationResultToast";
import CandidateDirectionGuard from "./CandidateDirectionGuard";
import CompletedTargetGuard from "./CompletedTargetGuard";
import DvaWorkspaceActionBarPatch from "./DvaWorkspaceActionBarPatch";
import RefundSettlementTargetSynchronizer from "./RefundSettlementTargetSynchronizer";
import SafeWorkspaceSelectionController from "./SafeWorkspaceSelectionController";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function amount(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

async function acceptedRefundTargets() {
  const supabase = await createClient();
  const [submissionsResult, totalsResult] = await Promise.all([
    supabase
      .from("dispute_refund_evidence_submissions")
      .select("id, dispute_id, supplier_approval_status, supplier_control_status, supplier_approved_at, submitted_at")
      .eq("supplier_approval_status", "approved_current")
      .eq("supplier_control_status", "approved_current")
      .order("supplier_approved_at", { ascending: false })
      .order("submitted_at", { ascending: false })
      .limit(500),
    supabase
      .from("dispute_refund_document_accounting_totals_vw")
      .select("refund_evidence_submission_id, dispute_id, accepted_document_gross_gbp")
      .limit(500),
  ]);

  if (submissionsResult.error || totalsResult.error) return {};

  const totalsBySubmissionId = new Map<string, Row>();
  for (const row of (totalsResult.data ?? []) as unknown as Row[]) {
    const submissionId = text(row.refund_evidence_submission_id);
    if (submissionId) totalsBySubmissionId.set(submissionId, row);
  }

  const acceptedRefundByDisputeId: Record<string, number> = {};
  for (const submission of (submissionsResult.data ?? []) as unknown as Row[]) {
    const disputeId = text(submission.dispute_id);
    if (!disputeId || acceptedRefundByDisputeId[disputeId] !== undefined) continue;

    const totals = totalsBySubmissionId.get(text(submission.id));
    const acceptedSupplierCredit = amount(totals?.accepted_document_gross_gbp);
    if (acceptedSupplierCredit > 0) acceptedRefundByDisputeId[disputeId] = acceptedSupplierCredit;
  }

  return acceptedRefundByDisputeId;
}

export default async function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  const acceptedRefundByDisputeId = await acceptedRefundTargets();

  return (
    <>
      <AllocationResultToast />
      {children}
      <RefundSettlementTargetSynchronizer acceptedRefundByDisputeId={acceptedRefundByDisputeId} />
      <CompletedTargetGuard />
      <CandidateDirectionGuard />
      <DvaWorkspaceActionBarPatch />
      <SafeWorkspaceSelectionController />
    </>
  );
}
