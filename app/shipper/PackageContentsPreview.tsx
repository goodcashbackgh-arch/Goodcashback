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

function formatQty(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  if (!Number.isFinite(n)) return "0";
  return n % 1 === 0 ? String(Math.trunc(n)) : n.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function statusLabel(value: string | null | undefined) {
  return (value ?? "allocated").replaceAll("_", " ");
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

  return (
    <details className={compact ? "rounded-xl border border-slate-200 bg-white p-2" : "rounded-2xl border border-slate-200 bg-white p-3"}>
      <summary className="cursor-pointer text-xs font-semibold text-sky-700">View contents</summary>
      {error ? (
        <p className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-2 text-xs text-amber-900">
          Contents preview unavailable: {error.message}
        </p>
      ) : rows.length === 0 ? (
        <p className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-2 text-xs text-amber-900">
          Contents not allocated yet — package can be received, but export evidence/COS review will require operator/supervisor allocation.
        </p>
      ) : (
        <div className="mt-2 overflow-x-auto rounded-lg border border-slate-200">
          <table className="min-w-full divide-y divide-slate-200 text-xs">
            <thead className="bg-slate-50 text-slate-500">
              <tr>
                <th className="px-2 py-1 text-left">Description</th>
                <th className="px-2 py-1 text-right">Qty</th>
                <th className="px-2 py-1 text-left">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 bg-white">
              {rows.map((row) => (
                <tr key={`${row.tracking_submission_id}-${row.supplier_invoice_line_id}-${row.allocation_status}`}>
                  <td className="px-2 py-1 font-medium text-slate-900">{row.item_description ?? "Unlabelled item"}</td>
                  <td className="px-2 py-1 text-right font-semibold text-slate-900">{formatQty(row.qty_allocated)}</td>
                  <td className="px-2 py-1 text-slate-600">{statusLabel(row.allocation_status)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="mt-2 text-[11px] text-slate-500">Description and quantity only. Values, VAT, margin, Sage and payment data are hidden.</p>
    </details>
  );
}
