import type { ReactNode } from "react";
import ExceptionStatusGuard from "./ExceptionStatusGuard";

export default function InternalExceptionReviewLayout({ children }: { children: ReactNode }) {
  return (
    <>
      {children}
      <ExceptionStatusGuard />
    </>
  );
}
