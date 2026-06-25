"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export default function RetireControlBanner({ batchId }: { batchId: string }) {
  const pathname = usePathname();
  if (pathname.endsWith("/retire")) return null;

  return (
    <div className="bg-slate-50 px-4 pt-4 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] rounded-2xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-900 shadow-sm">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <p className="font-semibold">
            Failed before any Sage object posted? Use the controlled retire page instead of a DB reset.
          </p>
          <Link
            href={`/internal/accounting-command-centre/loyalty-controls/batches/${batchId}/retire`}
            className="inline-flex rounded-xl border border-rose-300 bg-white px-3 py-2 text-xs font-bold text-rose-700 hover:bg-rose-100"
          >
            Open retire control
          </Link>
        </div>
      </div>
    </div>
  );
}
