import type { ReactNode } from "react";
import { createClient } from "@/utils/supabase/server";
import RefundAdjustmentGuidance from "./RefundAdjustmentGuidance";
import RejectedRefundDocumentAuditOnlyEnhancer from "./RejectedRefundDocumentAuditOnlyEnhancer";
import ReplacementOriginalItemReturnForm from "./ReplacementOriginalItemReturnForm";

type CourierOption = {
  id: string;
  name: string;
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

  if (
    dispute?.desired_outcome === "replacement"
    && !dispute.replacement_child_order_id
    && !dispute.resolved_at
  ) {
    const [{ data: activeLines }, { count: retailerReplyCount }, { data: couriers }] = await Promise.all([
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
    ]);

    const lines = activeLines ?? [];
    const singleLine = lines.length === 1 ? lines[0] : null;

    // Keep the page-level visibility check to data the importer role can read.
    // The governed RPC remains the authority for disposition eligibility and
    // rejects missing-item or otherwise invalid return submissions.
    canSubmitReplacementReturn = Boolean(
      singleLine
      && singleLine.intended_remedy === "replacement"
      && singleLine.conversation_status === "retailer_response_received"
      && singleLine.physical_remedy_allocation_id
      && Number(retailerReplyCount ?? 0) > 0
    );

    courierOptions = (couriers ?? []) as CourierOption[];
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
            />
          </div>
        </div>
      ) : null}
      <RejectedRefundDocumentAuditOnlyEnhancer />
    </RefundAdjustmentGuidance>
  );
}
