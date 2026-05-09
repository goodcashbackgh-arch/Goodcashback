import type { ReactNode } from "react";
import ExceptionStatusGuard from "./ExceptionStatusGuard";
import RefundResubmissionNoteEnhancer from "./RefundResubmissionNoteEnhancer";

export default function InternalExceptionReviewLayout({ children }: { children: ReactNode }) {
  return (
    <>
      {children}
      <RefundResubmissionNoteEnhancer />
      <ExceptionStatusGuard />
    </>
  );
}
