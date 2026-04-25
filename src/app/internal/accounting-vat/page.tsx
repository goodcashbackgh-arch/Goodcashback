import Link from "next/link";

export default function InternalAccountingVatPage() {
  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <Link href="/internal" className="text-sm font-semibold text-sky-600">
          ← Back to internal dashboard
        </Link>
        <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">
          Day 6 / Day 8
        </p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">
          Accounting / VAT release
        </h1>
        <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">
          Next wiring step: review released sales invoices, Sage posting queue,
          VAT return workings, VAT adjustments, and export deadline breach
          reporting without changing backend SQL.
        </p>
        <div className="mt-6 grid gap-4 md:grid-cols-2">
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
            <h2 className="font-semibold">Core rules</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">
              VAT is prepayment-first for known quoted goods. VAT reporting uses
              released sales invoices, not full order totals. Main and
              supplementary invoices can both feed Box 6.
            </p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
            <h2 className="font-semibold">Protected controls</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">
              Replacement child orders do not own VAT workings. Sage posting is
              queue-driven and idempotent. Box 1 breach adjustments belong to
              the breach period.
            </p>
          </div>
        </div>
      </div>
    </main>
  );
}
