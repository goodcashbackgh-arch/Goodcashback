"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function FundingLifecycleNav() {
  const pathname = usePathname();
  const isFundingMain = pathname === "/internal/funding";
  const isSurplusReview = pathname === "/internal/funding/surplus-evidence";

  return (
    <div className="mt-4 flex flex-wrap gap-2">
      {!isFundingMain ? (
        <Link href="/internal/funding" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-black text-slate-800">
          ← Funding overview
        </Link>
      ) : null}
      {!isSurplusReview ? (
        <Link href="/internal/funding/surplus-evidence" className="rounded-xl bg-cyan-700 px-4 py-2 text-sm font-black text-white">
          Surplus review →
        </Link>
      ) : null}
    </div>
  );
}
