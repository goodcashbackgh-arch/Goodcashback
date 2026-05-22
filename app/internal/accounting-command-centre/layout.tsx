import Link from "next/link";

export default function AccountingCommandCentreLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <div className="bg-slate-50 px-4 pt-4 sm:px-6 lg:px-8">
        <section className="mx-auto max-w-[1600px] rounded-2xl border border-violet-200 bg-violet-50 p-3 text-sm text-violet-950 shadow-sm">
          <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
            <div>
              <p className="font-bold">Supplier credit note lane</p>
              <p className="text-xs leading-5 text-violet-900">
                Uses the same Accounting Command Centre freeze, revalidate, batch, dry-run and posting route. Source evidence remains upstream refund/credit-note evidence; no fresh accounting upload.
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Link href="/internal/accounting-command-centre?queue=actionable&lane=supplier_credit_note" className="rounded-lg bg-violet-700 px-3 py-2 text-xs font-bold text-white hover:bg-violet-800">
                Open supplier credit note lane
              </Link>
              <form action="/internal/accounting-command-centre/freeze-supplier-credit-note" method="post">
                <input type="hidden" name="bulk_queue" value="actionable" />
                <input type="hidden" name="bulk_lane" value="supplier_credit_note" />
                <input type="hidden" name="bulk_posting_gate" value="all" />
                <input type="hidden" name="bulk_q" value="" />
                <input type="hidden" name="bulk_page_size" value="50" />
                <button className="rounded-lg bg-amber-700 px-3 py-2 text-xs font-bold text-white hover:bg-amber-800" type="submit">
                  Freeze all matching supplier credit notes
                </button>
              </form>
            </div>
          </div>
        </section>
      </div>
      {children}
    </>
  );
}
