import Link from "next/link";

export default function ShipperImporterDeliveryProfilesPage() {
  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-3xl rounded-3xl border border-amber-200 bg-amber-50 p-6 shadow-sm">
        <p className="text-sm font-medium uppercase tracking-[0.2em] text-amber-700">Goodcashback Shipper</p>
        <h1 className="mt-2 text-2xl font-semibold tracking-tight text-amber-950">Importer delivery profiles are not shipper-owned</h1>
        <p className="mt-3 text-sm leading-6 text-amber-900">
          Final recipient and delivery details are captured during importer/customer onboarding and then snapshotted into Groupage Movements. Shippers should not maintain those source records here.
        </p>
        <div className="mt-5 flex flex-wrap gap-3">
          <Link href="/shipper/groupage-movements" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Back to Groupage Movements</Link>
        </div>
      </div>
    </main>
  );
}
