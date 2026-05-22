import type { ReactNode } from "react";
import { postSupplierCreditNoteBatchToSageAction } from "../../supplierCreditNotePostingActions";

export default async function PostingBatchDetailTemplate({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ batch_id: string }> | { batch_id: string };
}) {
  const resolvedParams = await Promise.resolve(params);
  const batchId = resolvedParams.batch_id;

  return (
    <>
      <div className="bg-slate-50 px-4 pt-4 text-slate-950 sm:px-6 lg:px-8">
        <section className="mx-auto max-w-[1900px] rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.2em] text-emerald-700">Supplier credit note posting</p>
              <h2 className="mt-1 text-xl font-bold text-emerald-950">Post supplier credit note to Sage</h2>
              <p className="mt-1 text-sm leading-5 text-emerald-900">Server-side guarded. Wrong lane, missing dry-run validation, disabled live flag, or already-posted rows are refused.</p>
            </div>
            <form action={postSupplierCreditNoteBatchToSageAction} className="shrink-0">
              <input type="hidden" name="batch_id" value={batchId} />
              <button type="submit" className="rounded-2xl bg-emerald-700 px-5 py-3 text-sm font-extrabold text-white shadow-sm hover:bg-emerald-800">
                Post supplier credit note to Sage
              </button>
            </form>
          </div>
        </section>
      </div>
      {children}
    </>
  );
}
