import type { ReactNode } from "react";

export default function PostingBatchDetailTemplate({ children }: { children: ReactNode }) {
  return (
    <>
      <div className="bg-slate-50 px-4 pt-4 text-slate-950 sm:px-6 lg:px-8">
        <section className="mx-auto max-w-[1900px] rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm">
          <p className="text-sm font-bold text-emerald-950">Additional posting controls are available for this batch.</p>
        </section>
      </div>
      {children}
    </>
  );
}
