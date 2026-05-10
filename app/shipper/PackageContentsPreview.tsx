import { createClient } from "@/utils/supabase/server";

type PackageContentsRow = {
  tracking_submission_id: string;
  order_id: string;
  order_ref: string | null;
  retailer_name: string | null;
  courier_name: string | null;
  tracking_ref: string | null;
  supplier_invoice_line_id: string;
  item_description: string | null;
  qty_allocated: number | string | null;
  allocation_status: string | null;
};

function qtyNumber(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function formatQty(value: number | string | null | undefined) {
  const n = qtyNumber(value);
  return n % 1 === 0 ? String(Math.trunc(n)) : n.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function formatTotalQty(value: number) {
  return value % 1 === 0 ? String(Math.trunc(value)) : value.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function statusLabel(value: string | null | undefined) {
  return (value ?? "allocated").replaceAll("_", " ");
}

function firstItemLabel(rows: PackageContentsRow[]) {
  const first = rows[0]?.item_description?.trim();
  if (!first) return "Contents allocated";
  return first.length > 52 ? `${first.slice(0, 49)}…` : first;
}

export async function PackageContentsPreview({
  trackingSubmissionId,
  compact = false,
}: {
  trackingSubmissionId: string | null | undefined;
  compact?: boolean;
}) {
  if (!trackingSubmissionId) return null;

  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("shipper_package_contents_preview_v1", {
    p_tracking_submission_id: trackingSubmissionId,
  });

  const rows = (data ?? []) as PackageContentsRow[];
  const totalQty = rows.reduce((sum, row) => sum + qtyNumber(row.qty_allocated), 0);
  const visibleRows = rows.slice(0, compact ? 3 : 5);
  const hiddenCount = Math.max(rows.length - visibleRows.length, 0);

  if (error) {
    return (
      <div className={compact ? "rounded-xl border border-amber-200 bg-amber-50 p-2" : "rounded-2xl border border-amber-200 bg-amber-50 p-3"}>
        <p className="text-xs font-semibold text-amber-950">Contents preview unavailable</p>
        <p className="mt-1 text-xs text-amber-900">{error.message}</p>
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className={compact ? "rounded-xl border border-amber-200 bg-amber-50 p-2" : "rounded-2xl border border-amber-200 bg-amber-50 p-3"}>
        <p className="text-xs font-semibold text-amber-950">Contents not allocated yet</p>
        <p className="mt-1 text-xs text-amber-900">Package can be received, but export evidence/COS review will require operator/supervisor allocation.</p>
      </div>
    );
  }

  return (
    <details className={compact ? "rounded-xl border border-slate-200 bg-white p-2" : "rounded-2xl border border-slate-200 bg-white p-3"}>
      <summary className="cursor-pointer list-none text-xs font-semibold text-sky-700">
        <span className="inline-flex flex-col gap-1">
          <span>View contents</span>
          <span className="font-normal text-slate-600">
            {rows.length} item{rows.length === 1 ? "" : "s"} · {formatTotalQty(totalQty)} unit{totalQty === 1 ? "" : "s"}
          </span>
          <span className="font-normal text-slate-500">{firstItemLabel(rows)}{rows.length > 1 ? ` +${rows.length - 1} more` : ""}</span>
        </span>
      </summary>

      <div className="mt-2 rounded-lg border border-slate-200 bg-slate-50 p-2">
        <div className="space-y-2">
          {visibleRows.map((row) => (
            <div key={`${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${row.allocation_status}`} className="rounded-lg bg-white p-2 text-xs shadow-sm">
              <p className="font-medium text-slate-900">{row.item_description ?? "Unlabelled item"}</p>
              <p className="mt-1 text-slate-600">Qty {formatQty(row.qty_allocated)} · {statusLabel(row.allocation_status)}</p>
            </div>
          ))}
        </div>
        {hiddenCount > 0 ? (
          <p className="mt-2 rounded-lg bg-slate-100 px-2 py-1 text-xs font-semibold text-slate-700">
            +{hiddenCount} more item{hiddenCount === 1 ? "" : "s"}. Full item review belongs in the later supervisor export evidence view.
          </p>
        ) : null}
      </div>
      <p className="mt-2 text-[11px] text-slate-500">Description and quantity only. Values, VAT, margin, Sage and payment data are hidden.</p>
    </details>
  );
}
