import type { ReactNode } from "react";
import { requirePortalAccess } from "@/utils/platform-access/portal-guard";
import CustomerReviewCardCountdownOverlay from "./CustomerReviewCardCountdownOverlay";

export default async function CustomerLayout({ children }: { children: ReactNode }) {
  await requirePortalAccess("customer");

  return (
    <>
      <CustomerReviewCardCountdownOverlay />
      {children}
    </>
  );
}
