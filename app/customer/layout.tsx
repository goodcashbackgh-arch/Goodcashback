import type { ReactNode } from "react";
import CustomerReviewCardCountdownOverlay from "./CustomerReviewCardCountdownOverlay";

export default function CustomerLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <CustomerReviewCardCountdownOverlay />
      {children}
    </>
  );
}
