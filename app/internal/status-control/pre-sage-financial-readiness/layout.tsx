import type { ReactNode } from "react";

export default function PreSageFinancialReadinessLayout({ children }: { children: ReactNode }) {
  return (
    <>
      <div className="bg-slate-50 px-4 pt-4 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-7xl rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm leading-6 text-sky-900 shadow-sm">
          <p className="font-bold text-sky-950">Readiness interpretation note</p>
          <p className="mt-1">
            This page is a pre-Sage blocker view. DVA/card open-value warnings are importer-level signals until a statement line is allocated to a specific order, invoice, refund, fee or exception. Funding shown as not proven means the current funding-position view has not proved funding for that order; verify the funding queue before treating it as a final commercial conclusion.
          </p>
        </div>
      </div>
      {children}
    </>
  );
}
