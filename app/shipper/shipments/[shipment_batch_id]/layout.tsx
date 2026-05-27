import Link from "next/link";

export default async function ShipperShipmentBatchLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ shipment_batch_id: string }>;
}) {
  const { shipment_batch_id: shipmentBatchId } = await params;

  return (
    <>
      {children}
      <div className="fixed inset-x-0 bottom-4 z-40 flex justify-center px-4 print:hidden">
        <div className="flex max-w-3xl flex-wrap items-center justify-center gap-3 rounded-2xl border border-emerald-200 bg-white/95 p-3 shadow-lg backdrop-blur">
          <Link
            href={`/shipper/shipments/${shipmentBatchId}/draft-cos-pack`}
            className="rounded-xl border border-emerald-300 bg-emerald-50 px-4 py-2 text-sm font-semibold text-emerald-900 hover:bg-emerald-100"
          >
            Download draft COS + EEP pack
          </Link>
          <Link
            href={`/shipper/shipments/${shipmentBatchId}/final-evidence`}
            className="rounded-xl border border-amber-300 bg-amber-50 px-4 py-2 text-sm font-semibold text-amber-900 hover:bg-amber-100"
          >
            Upload final evidence
          </Link>
          <span className="text-xs font-medium text-slate-600">
            Create the draft pack first, then upload the completed final evidence.
          </span>
        </div>
      </div>
    </>
  );
}
