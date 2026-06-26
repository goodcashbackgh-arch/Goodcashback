import type { ReactNode } from "react";
import Link from "next/link";

export default function CompletionLoyaltyRewardsLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <div className="bg-slate-50 px-4 pt-4 sm:px-6 lg:px-8">
        <div className="mx-auto flex max-w-7xl flex-wrap gap-2 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-xs font-bold text-amber-950 shadow-sm">
          <span>Completion loyalty:</span>
          <Link href="/internal/completion-loyalty-reversals" className="rounded-xl border border-amber-300 bg-white px-3 py-1 text-amber-900 underline-offset-2 hover:underline">
            Release reversal review
          </Link>
          <Link href="/internal/dva-reconciliation/main-bank?target=completion_loyalty" className="rounded-xl border border-sky-200 bg-white px-3 py-1 text-sky-900 underline-offset-2 hover:underline">
            Main-bank loyalty workspace
          </Link>
        </div>
      </div>
      {children}
    </>
  );
}
