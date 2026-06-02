import Link from "next/link";
import type { ReactNode } from "react";

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

export default async function VatReturnRunLayout({
  children,
  params,
}: {
  children: ReactNode;
  params: Promise<{ return_run_id?: string }> | { return_run_id?: string };
}) {
  const resolvedParams = await params;
  const runId = text(resolvedParams?.return_run_id);

  return (
    <>
      {children}
      {runId ? (
        <Link
          href={`/internal/accounting-vat/returns/${runId}/sage-only-purchase-approval`}
          className="fixed bottom-5 right-5 z-50 rounded-2xl border border-sky-200 bg-sky-600 px-4 py-3 text-sm font-extrabold text-white shadow-xl hover:bg-sky-700"
        >
          Review / approve Sage-only purchase differences
        </Link>
      ) : null}
    </>
  );
}
