import type { ReactNode } from "react";
import ExceptionStatusGuard from "./ExceptionStatusGuard";
import RefundResubmissionNoteEnhancer from "./RefundResubmissionNoteEnhancer";
import ReturnEvidenceReviewEnhancer from "./ReturnEvidenceReviewEnhancer";

export default function InternalExceptionReviewLayout({ children }: { children: ReactNode }) {
  return (
    <>
      {children}
      <RefundResubmissionNoteEnhancer />
      <ReturnEvidenceReviewEnhancer />
      <ExceptionStatusGuard />
    </>
  );
}
