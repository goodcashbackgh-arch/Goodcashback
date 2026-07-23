import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type PackageContentsRow = {
  tracking_submission_id: string;
  qty_allocated: number | string | null;
};

function qtyNumber(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function formatTotalQty(value: number) {
  return value % 1 === 0 ? String(Math.trunc(value)) : value.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

export async function OriginalPackageContentsPreview({
  trackingSubmissionId,
  compact = false,
}: {
  trackingSubmissionId: string | null | undefined;
  compact?: boolean;
}) {
  if (!trackingSubmissionId) return null;

  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("shipper_package_original_contents_preview_v1", {
    p_tracking_submission_id: trackingSubmissionId,
  });

  const rows = (data ?? []) as PackageContentsRow[];
  const totalQty = rows.reduce((sum, row) => sum + qtyNumber(row.qty_allocated), 0);
  const href = `/shipper/package-contents/${trackingSubmissionId}`;

  if (error) {
    return (
      <Link href={href} className={compact ? "block rounded-xl border border-amber-200 bg-amber-50 p-2 text-xs hover:bg-amber-100" : "block rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm hover:bg-amber-100"}>
        <span className="font-semibold text-amber-950">View original contents</span>
        <span className="mt-1 block text-amber-900">Unavailable until latest migration is applied</span>
      </Link>
    );
  }

  if (rows.length === 0) {
    return (
      <Link href={href} className={compact ? "block rounded-xl border border-amber-200 bg-amber-50 p-2 text-xs hover:bg-amber-100" : "block rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm hover:bg-amber-100"}>
        <span className="font-semibold text-amber-950">View original contents</span>
        <span className="mt-1 block text-amber-900">Not allocated</span>
      </Link>
    );
  }

  return (
    <Link href={href} className={compact ? "block rounded-xl border border-sky-200 bg-white p-2 text-xs shadow-sm hover:bg-sky-50" : "block rounded-2xl border border-sky-200 bg-white p-3 text-sm shadow-sm hover:bg-sky-50"}>
      <span className="font-semibold text-sky-700">View original contents</span>
      <span className="mt-1 block text-slate-700">
        {rows.length} item{rows.length === 1 ? "" : "s"} · {formatTotalQty(totalQty)} unit{totalQty === 1 ? "" : "s"}
      </span>
    </Link>
  );
}
