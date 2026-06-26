import type { ReactNode } from "react";
import Link from "next/link";
import ReleaseGuard from "./ReleaseGuard";

export default function MainBankMatchingLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <ReleaseGuard />
      <div className="bg-slate-50 px-4 pt-4 sm:px-6 lg:px-8">
        <div className="mx-auto flex max-w-7xl flex-wrap gap-2 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-xs font-bold text-amber-950 shadow-sm">
          <span>Completion loyalty:</span>
          <Link href="/internal/completion-loyalty-reversals" className="rounded-xl border border-amber-300 bg-white px-3 py-1 text-amber-900 underline-offset-2 hover:underline">
            Release reversal review
          </Link>
          <Link href="/internal/completion-loyalty-rewards" className="rounded-xl border border-slate-200 bg-white px-3 py-1 text-slate-700 underline-offset-2 hover:underline">
            Reward workbench
          </Link>
        </div>
      </div>
      {children}
    </>
  );
}
