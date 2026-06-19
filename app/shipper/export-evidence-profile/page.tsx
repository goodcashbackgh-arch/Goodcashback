import Link from "next/link";

export default function ShipperExportEvidenceProfilePage() {
  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-3xl rounded-3xl border border-amber-200 bg-amber-50 p-6 shadow-sm">
        <p className="text-sm font-medium uppercase tracking-[0.2em] text-amber-700">Goodcashback Shipper</p>
        <h1 className="mt-2 text-2xl font-semibold tracking-tight text-amber-950">Export evidence profile is onboarding-owned</h1>
        <p className="mt-3 text-sm leading-6 text-amber-900">
          Exporter, movement consignee, receiving hub and notify-party details are source profile records captured during tenant/shipper onboarding and maintained by admin/onboarding controls. Shippers do not maintain those source records here.
        </p>
        <p className="mt-3 text-sm leading-6 text-amber-900">
          Groupage Movements should only pull and snapshot those database records into the movement/export pack.
        </p>
        <div className="mt-5 flex flex-wrap gap-3">
          <Link href="/shipper/groupage-movements" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Back to Groupage Movements</Link>
        </div>
      </div>
    </main>
  );
}
