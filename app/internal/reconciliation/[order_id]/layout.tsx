import Link from "next/link";

export default async function InternalReconciliationOrderLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ order_id: string }>;
}) {
  const { order_id: orderId } = await params;

  return (
    <>
      <div className="bg-amber-50 px-6 py-3 text-sm text-amber-950 ring-1 ring-amber-200">
        <div className="mx-auto flex max-w-[1500px] flex-wrap items-center justify-between gap-3">
          <span className="font-semibold">Staff/supervisor takeover:</span>
          <span className="text-amber-900">If clean invoice lines are not yet confirmed, confirm them before accounting coding.</span>
          <Link
            href={`/internal/reconciliation/${orderId}/staff-confirm-lines`}
            className="rounded-xl bg-amber-700 px-3 py-2 font-semibold text-white hover:bg-amber-600"
          >
            Confirm invoice lines
          </Link>
        </div>
      </div>
      {children}
    </>
  );
}
