import Link from "next/link";

export default function SageMappingLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <div className="border-b border-slate-200 bg-white px-4 py-3 text-slate-950 shadow-sm sm:px-6">
        <div className="mx-auto flex max-w-7xl flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-500">Sage mapping workflow</p>
            <p className="mt-1 text-sm text-slate-600">One workflow: use the main mapping control for contacts, tax and bank; use the CoA selector only when choosing ledger/GL accounts.</p>
          </div>
          <div className="flex flex-wrap gap-2 text-sm font-bold">
            <Link href="/internal/sage-mapping" className="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-slate-800 hover:bg-slate-100">Mapping control</Link>
            <Link href="/internal/sage-mapping/coa" className="rounded-xl border border-sky-200 bg-sky-50 px-3 py-2 text-sky-900 hover:bg-sky-100">Full CoA / GL selector</Link>
          </div>
        </div>
      </div>
      {children}
    </>
  );
}
