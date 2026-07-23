import type { ReactNode } from "react";
import RefundAdjustmentGuidance from "./RefundAdjustmentGuidance";
import RejectedRefundDocumentAuditOnlyEnhancer from "./RejectedRefundDocumentAuditOnlyEnhancer";

export default function ImporterExceptionLayout({ children }: { children: ReactNode }) {
  return (
    <RefundAdjustmentGuidance>
      {children}
      <RejectedRefundDocumentAuditOnlyEnhancer />
    </RefundAdjustmentGuidance>
  );
}
