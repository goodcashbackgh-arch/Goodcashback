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
          <span className="text-xs font-medium text-slate-600">
            Uses saved shipper fields and platform packing-list data.
          </span>
        </div>
      </div>
    </>
  );
}
