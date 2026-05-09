import type { ReactNode } from "react";
import ExceptionStatusGuard from "./ExceptionStatusGuard";
import RefundResubmissionNoteEnhancer from "./RefundResubmissionNoteEnhancer";
import ReturnEvidenceReviewEnhancer from "./ReturnEvidenceReviewEnhancer";
import ReturnEvidenceSupervisorDetailsEnhancer from "./ReturnEvidenceSupervisorDetailsEnhancer";

export default function InternalExceptionReviewLayout({ children }: { children: ReactNode }) {
  return (
    <>
      {children}
      <RefundResubmissionNoteEnhancer />
      <ReturnEvidenceReviewEnhancer />
      <ReturnEvidenceSupervisorDetailsEnhancer />
      <ExceptionStatusGuard />
    </>
  );
}
