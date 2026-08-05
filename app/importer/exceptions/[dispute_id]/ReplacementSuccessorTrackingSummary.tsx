type SuccessorTrackingSummaryProps = {
  courierName: string | null;
  trackingRef: string | null;
  trackingDate: string | null;
  trackingAllocatedAt: string | null;
  receiptStatus: string | null;
  bookingRef: string | null;
};

function formatDate(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleDateString("en-GB", { dateStyle: "medium" });
}

function formatDateTime(value: string | null) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" });
}

function receiptLabel(value: string | null) {
  if (value === "received_clean") return "Package received clean";
  if (value === "received_damaged") return "Package received damaged";
  if (value === "held_query") return "Package held / query";
  if (value === "not_received") return "Package not received";
  return "Awaiting package receipt";
}

export default function ReplacementSuccessorTrackingSummary({
  courierName,
  trackingRef,
  trackingDate,
  trackingAllocatedAt,
  receiptStatus,
  bookingRef,
}: SuccessorTrackingSummaryProps) {
  return (
    <div className="bg-slate-50 px-6 pb-8 text-slate-950">
      <div className="mx-auto max-w-6xl">
        <section className="rounded-3xl border border-sky-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-600">Same-order replacement</p>
          <h2 className="mt-2 text-xl font-semibold">Successor tracking</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">
            Read-only tracking, receipt and shipment facts for the replacement allocation retained on the original order.
          </p>

          <dl className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Courier / tracking</dt>
              <dd className="mt-2 break-words font-semibold text-slate-950">
                {courierName ?? "Courier"} · {trackingRef ?? "Reference unavailable"}
              </dd>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Tracking date</dt>
              <dd className="mt-2 font-semibold text-slate-950">{formatDate(trackingDate)}</dd>
              <dd className="mt-1 text-xs text-slate-500">Allocated {formatDateTime(trackingAllocatedAt)}</dd>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Package receipt</dt>
              <dd className="mt-2 font-semibold text-slate-950">{receiptLabel(receiptStatus)}</dd>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">Shipment booking</dt>
              <dd className="mt-2 font-semibold text-slate-950">{bookingRef ? `Added to ${bookingRef}` : "Not yet added"}</dd>
            </div>
          </dl>
        </section>
      </div>
    </div>
  );
}
