import Link from "next/link";

export default function InternalAccountingVatPage() {
  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <Link href="/internal" className="text-sm font-semibold text-sky-600">
          ← Back to internal dashboard
        </Link>
        <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">
          Admin-only VAT Return Workbench
        </p>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight">
          VAT return control dashboard
        </h1>
        <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">
          The active implementation lives in the top-level app route. This fallback keeps the src tree stable and points future work to the canonical VAT contract.
        </p>
        <div className="mt-6 rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm leading-6 text-sky-900">
          Controlling contract: docs/governing-pack/ui/VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1.md. Live VAT controls are admin-only. No Sage posting controls are exposed from this fallback page.
        </div>
      </div>
    </main>
  );
}
