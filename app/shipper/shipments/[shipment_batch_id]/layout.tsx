import Link from "next/link";
import { FloatingActionBar } from "@/app/_components/FloatingActionBar";

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
      <div className="h-32 print:hidden" aria-hidden="true" />
      <FloatingActionBar innerClassName="flex max-w-3xl flex-wrap items-center justify-center gap-3 rounded-2xl border border-emerald-200 bg-white/95 p-3 shadow-lg backdrop-blur">
        <Link
          href={`/shipper/shipments/${shipmentBatchId}/draft-cos-pack`}
          className="rounded-xl border border-emerald-300 bg-emerald-50 px-4 py-2 text-sm font-semibold text-emerald-900 hover:bg-emerald-100"
        >
          Download draft COS + EEP pack
        </Link>
        <Link
          href={`/shipper/shipments/${shipmentBatchId}/sales-invoices-zip`}
          className="rounded-xl border border-sky-300 bg-sky-50 px-4 py-2 text-sm font-semibold text-sky-900 hover:bg-sky-100"
        >
          Download shipment document ZIP
        </Link>
        <Link
          href={`/shipper/shipments/${shipmentBatchId}/final-evidence`}
          className="rounded-xl border border-amber-300 bg-amber-50 px-4 py-2 text-sm font-semibold text-amber-900 hover:bg-amber-100"
        >
          Upload final evidence
        </Link>
        <span className="text-xs font-medium text-slate-600">
          Create the draft pack, download supporting shipment documents, then upload the completed final evidence.
        </span>
      </FloatingActionBar>
    </>
  );
}
