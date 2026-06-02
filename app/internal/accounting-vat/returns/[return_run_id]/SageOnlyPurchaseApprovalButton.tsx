"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";

export function SageOnlyPurchaseApprovalButton({ runId }: { runId: string }) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const expectedPath = `/internal/accounting-vat/returns/${runId}`;
  const isPurchasesTab = pathname === expectedPath && searchParams.get("tab") === "purchases";

  if (!isPurchasesTab) return null;

  return (
    <Link
      href={`/internal/accounting-vat/returns/${runId}/sage-only-purchase-approval`}
      className="fixed bottom-5 right-5 z-50 rounded-2xl border border-sky-200 bg-sky-600 px-4 py-3 text-sm font-extrabold text-white shadow-xl hover:bg-sky-700"
    >
      Review / approve Sage-only purchase differences
    </Link>
  );
}
