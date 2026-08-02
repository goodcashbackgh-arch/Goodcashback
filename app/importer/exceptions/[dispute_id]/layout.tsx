import type { ReactNode } from "react";
import { createClient } from "@/utils/supabase/server";
import RefundAdjustmentGuidance from "./RefundAdjustmentGuidance";
import RejectedRefundDocumentAuditOnlyEnhancer from "./RejectedRefundDocumentAuditOnlyEnhancer";
import ReplacementOriginalItemReturnForm from "./ReplacementOriginalItemReturnForm";

type CourierOption = {
  id: string;
  name: string;
};

type ReturnHistoryRow = {
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

export default async function ImporterExceptionLayout({
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
    .select("id, desired_outcome, replacement_child_order_id, resolved_at")
    .eq("id", disputeId)
    .maybeSingle();

  let canSubmitReplacementReturn = false;
  let courierOptions: CourierOption[] = [];
  let returnHistory: Array<{
    id: string;
    courier_name: string | null;
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
  }> = [];

  if (
    dispute?.desired_outcome === "replacement"
    && !dispute.replacement_child_order_id
    && !dispute.resolved_at
  ) {
    const [
      { data: activeLines },
      { count: retailerReplyCount },
      { data: couriers },
      { data: returnRows },
    ] = await Promise.all([
      supabase
        .from("dispute_lines")
        .select("id, intended_remedy, conversation_status, physical_remedy_allocation_id")
        .eq("dispute_id", disputeId)
        .is("resolved_at", null),
      supabase
        .from("dispute_messages")
        .select("id", { count: "exact", head: true })
        .eq("dispute_id", disputeId)
        .eq("message_type", "retailer_reply")
        .eq("counterparty", "retailer"),
      supabase
        .from("couriers")
        .select("id, name")
        .order("name", { ascending: true }),
      supabase
        .from("dispute_return_tracking_submissions")
        .select("id, courier_id, tracking_ref, tracking_date, tracking_evidence_url, retailer_return_instructions_file_url, return_label_file_url, return_proof_file_url, submitted_at, is_final_return_yn, review_status, note, couriers(name)")
        .eq("dispute_id", disputeId)
        .order("submitted_at", { ascending: false }),
    ]);

    const lines = activeLines ?? [];
    const singleLine = lines.length === 1 ? lines[0] : null;

    canSubmitReplacementReturn = Boolean(
      singleLine
      && singleLine.intended_remedy === "replacement"
      && singleLine.conversation_status === "retailer_response_received"
      && singleLine.physical_remedy_allocation_id
      && Number(retailerReplyCount ?? 0) > 0
    );

    courierOptions = (couriers ?? []) as CourierOption[];
    returnHistory = ((returnRows ?? []) as ReturnHistoryRow[]).map((row) => {
      const courier = Array.isArray(row.couriers) ? row.couriers[0] : row.couriers;
      return {
        id: row.id,
        courier_name: courier?.name ?? null,
        tracking_ref: row.tracking_ref,
        tracking_date: row.tracking_date,
        tracking_evidence_url: row.tracking_evidence_url,
        retailer_return_instructions_file_url: row.retailer_return_instructions_file_url,
        return_label_file_url: row.return_label_file_url,
        return_proof_file_url: row.return_proof_file_url,
        submitted_at: row.submitted_at,
        is_final_return_yn: row.is_final_return_yn,
        review_status: row.review_status,
        note: row.note,
      };
    });
  }

  return (
    <RefundAdjustmentGuidance>
      {children}
      {canSubmitReplacementReturn ? (
        <div className="bg-slate-50 px-6 pb-8 text-slate-950">
          <div className="mx-auto max-w-6xl">
            <ReplacementOriginalItemReturnForm
              disputeId={disputeId}
              courierOptions={courierOptions}
              returnHistory={returnHistory}
            />
          </div>
        </div>
      ) : null}
      <RejectedRefundDocumentAuditOnlyEnhancer />
    </RefundAdjustmentGuidance>
  );
}
