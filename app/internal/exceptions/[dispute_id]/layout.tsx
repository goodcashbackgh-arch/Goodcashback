import type { ReactNode } from "react";
import { createClient } from "@/utils/supabase/server";
import ExceptionStatusGuard from "./ExceptionStatusGuard";
import ExceptionTimelinePolishEnhancer from "./ExceptionTimelinePolishEnhancer";
import RefundResubmissionNoteEnhancer from "./RefundResubmissionNoteEnhancer";
import ReplacementReturnEvidenceReviewPanel from "./ReplacementReturnEvidenceReviewPanel";
import ReturnEvidenceReviewEnhancer from "./ReturnEvidenceReviewEnhancer";
import ReturnEvidenceSupervisorDetailsEnhancer from "./ReturnEvidenceSupervisorDetailsEnhancer";
import SupervisorDisputeSummaryEnhancer from "./SupervisorDisputeSummaryEnhancer";

type ReturnTrackingRow = {
  id: string;
  courier_id: string | null;
  couriers?: { name?: string | null } | { name?: string | null }[] | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  tracking_evidence_url: string | null;
  retailer_return_instructions_file_url: string | null;
  return_label_file_url: string | null;
  return_proof_file_url: string | null;
  submitted_at: string | null;
  is_final_return_yn: boolean | null;
  review_status: string | null;
  note: string | null;
};

type ShipperConfirmationRow = {
  id: string;
  return_tracking_submission_id: string;
  outcome: string | null;
  proof_file_url: string | null;
  proof_url: string | null;
  note: string | null;
  submitted_at: string | null;
  review_status: string | null;
  review_notes: string | null;
};

export default async function InternalExceptionReviewLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ dispute_id: string }>;
}) {
  const { dispute_id: disputeId } = await params;
  const supabase = await createClient();

  const { data: dispute } = await supabase
    .from("disputes")
    .select("id, desired_outcome, amount_impact_gbp")
    .eq("id", disputeId)
    .maybeSingle();

  const { data: disputeLines } = await supabase
    .from("dispute_lines")
    .select("id, resolved_at")
    .eq("dispute_id", disputeId);

  const affectedLineCount = (disputeLines ?? []).length;
  const unresolvedLineCount = (disputeLines ?? []).filter((line) => line.resolved_at === null).length;

  let replacementReturnSubmissions: Array<{
    id: string;
    courierName: string;
    trackingRef: string | null;
    trackingDate: string | null;
    trackingEvidenceUrl: string | null;
    retailerInstructionsUrl: string | null;
    returnLabelUrl: string | null;
    returnProofUrl: string | null;
    submittedAt: string | null;
    isFinalReturn: boolean | null;
    reviewStatus: string | null;
    note: string | null;
    latestShipperConfirmation: {
      outcome: string | null;
      proofUrl: string | null;
      note: string | null;
      submittedAt: string | null;
      reviewStatus: string | null;
      reviewNotes: string | null;
    } | null;
  }> = [];

  if (dispute?.desired_outcome === "replacement") {
    const { data } = await supabase
      .from("dispute_return_tracking_submissions")
      .select("id, courier_id, tracking_ref, tracking_date, tracking_evidence_url, retailer_return_instructions_file_url, return_label_file_url, return_proof_file_url, submitted_at, is_final_return_yn, review_status, note, couriers(name)")
      .eq("dispute_id", disputeId)
      .order("submitted_at", { ascending: false });

    const trackingRows = (data ?? []) as ReturnTrackingRow[];
    const trackingIds = trackingRows.map((row) => row.id);
    const { data: confirmationsRaw } = trackingIds.length
      ? await supabase
          .from("shipper_return_task_confirmations")
          .select("id, return_tracking_submission_id, outcome, proof_file_url, proof_url, note, submitted_at, review_status, review_notes")
          .in("return_tracking_submission_id", trackingIds)
          .order("submitted_at", { ascending: false })
      : { data: [] };

    const latestBySubmission = new Map<string, ShipperConfirmationRow>();
    for (const row of (confirmationsRaw ?? []) as ShipperConfirmationRow[]) {
      if (!latestBySubmission.has(row.return_tracking_submission_id)) {
        latestBySubmission.set(row.return_tracking_submission_id, row);
      }
    }

    replacementReturnSubmissions = trackingRows.map((row) => {
      const courier = Array.isArray(row.couriers) ? row.couriers[0] : row.couriers;
      const confirmation = latestBySubmission.get(row.id) ?? null;
      return {
        id: row.id,
        courierName: courier?.name ?? row.courier_id ?? "Not provided",
        trackingRef: row.tracking_ref,
        trackingDate: row.tracking_date,
        trackingEvidenceUrl: row.tracking_evidence_url,
        retailerInstructionsUrl: row.retailer_return_instructions_file_url,
        returnLabelUrl: row.return_label_file_url,
        returnProofUrl: row.return_proof_file_url,
        submittedAt: row.submitted_at,
        isFinalReturn: row.is_final_return_yn,
        reviewStatus: row.review_status,
        note: row.note,
        latestShipperConfirmation: confirmation
          ? {
              outcome: confirmation.outcome,
              proofUrl: confirmation.proof_file_url ?? confirmation.proof_url,
              note: confirmation.note,
              submittedAt: confirmation.submitted_at,
              reviewStatus: confirmation.review_status,
              reviewNotes: confirmation.review_notes,
            }
          : null,
      };
    });
  }

  return (
    <>
      {children}
      {dispute ? (
        <SupervisorDisputeSummaryEnhancer
          disputeId={disputeId}
          disputeAmount={Number(dispute.amount_impact_gbp ?? 0)}
          affectedLineCount={affectedLineCount}
          unresolvedLineCount={unresolvedLineCount}
        />
      ) : null}
      {replacementReturnSubmissions.length > 0 ? (
        <div className="bg-slate-50 px-6 pb-8 text-slate-950">
          <div className="mx-auto max-w-6xl">
            <ReplacementReturnEvidenceReviewPanel
              disputeId={disputeId}
              submissions={replacementReturnSubmissions}
            />
          </div>
        </div>
      ) : null}
      <RefundResubmissionNoteEnhancer />
      <ReturnEvidenceReviewEnhancer />
      <ReturnEvidenceSupervisorDetailsEnhancer />
      <ExceptionTimelinePolishEnhancer />
      <ExceptionStatusGuard />
    </>
  );
}
