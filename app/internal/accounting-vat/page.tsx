import Link from "next/link";

export default function InternalAccountingVatPage() {
  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
        <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Day 6 / Day 8</p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">Accounting / VAT release</h1>
        <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">Next wiring step: Sage queue, released sales invoices, VAT return workings, VAT adjustments, and export deadline breach reporting.</p>
      </div>
    </main>
  );
}
