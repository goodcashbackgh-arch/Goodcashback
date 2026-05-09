import type { ReactNode } from "react";
import RejectedRefundDocumentAuditOnlyEnhancer from "./RejectedRefundDocumentAuditOnlyEnhancer";

export default function ImporterExceptionLayout({ children }: { children: ReactNode }) {
  return (
    <>
      {children}
      <RejectedRefundDocumentAuditOnlyEnhancer />
    </>
  );
}
