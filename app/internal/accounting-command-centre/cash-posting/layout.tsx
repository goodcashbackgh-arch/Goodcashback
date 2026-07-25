import type { ReactNode } from "react";
import RefundInLegacyStatusCopyFix from "./RefundInLegacyStatusCopyFix";

export default function CashPostingLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <RefundInLegacyStatusCopyFix />
      {children}
    </>
  );
}
