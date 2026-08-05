type DivertedSegment = {
  disposition_type?: string | null;
  quantity?: number | string | null;
  condition_note?: string | null;
};

type SavedSplitRow = {
  tracking_line_allocation_id: string;
  item_description: string | null;
  qty_allocated: number | string;
  clean_qty: number | string;
  diverted_qty: number | string;
  diverted_segments: DivertedSegment[] | null;
};

function formatQty(value: number | string | null | undefined) {
  const number = Number(value ?? 0);
  if (!Number.isFinite(number)) return "0";
  return number.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function label(value: string | null | undefined) {
  if (!value) return "Diverted";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

export default function SavedPhysicalReceiptSplit({ rows }: { rows: SavedSplitRow[] }) {
  const cleanTotal = rows.reduce((sum, row) => sum + Number(row.clean_qty ?? 0), 0);
  const divertedTotal = rows.reduce((sum, row) => sum + Number(row.diverted_qty ?? 0), 0);

  return (
    <section className="space-y-5">
      <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
        <h2 className="text-xl font-semibold">Saved receipt split</h2>
        <p className="mt-2 text-sm text-slate-600">
          This is the finalised package truth. Clean quantities remain available to the downstream clean flow; diverted quantities remain outside that flow until their review outcome is resolved.
        </p>
        <div className="mt-4 grid grid-cols-2 gap-3 sm:max-w-md">
          <div className="rounded-2xl bg-emerald-50 p-4">
            <span className="block text-xs font-semibold uppercase tracking-wide text-emerald-700">Clean</span>
            <strong className="mt-1 block text-2xl text-emerald-950">{formatQty(cleanTotal)}</strong>
          </div>
          <div className="rounded-2xl bg-amber-50 p-4">
            <span className="block text-xs font-semibold uppercase tracking-wide text-amber-700">Diverted</span>
            <strong className="mt-1 block text-2xl text-amber-950">{formatQty(divertedTotal)}</strong>
          </div>
        </div>
      </div>

      <div className="space-y-4">
        {rows.map((row, index) => {
          const segments = Array.isArray(row.diverted_segments) ? row.diverted_segments : [];
          return (
            <article key={row.tracking_line_allocation_id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <p className="text-xs uppercase tracking-wide text-slate-500">Line {index + 1}</p>
              <h3 className="mt-1 font-semibold">{row.item_description ?? "Unlabelled supplier invoice line"}</h3>
              <div className="mt-4 grid grid-cols-3 gap-3 text-sm">
                <div className="rounded-xl bg-slate-50 p-3"><span className="block text-xs uppercase tracking-wide text-slate-500">Allocated</span><strong>{formatQty(row.qty_allocated)}</strong></div>
                <div className="rounded-xl bg-emerald-50 p-3"><span className="block text-xs uppercase tracking-wide text-emerald-700">Clean</span><strong>{formatQty(row.clean_qty)}</strong></div>
                <div className="rounded-xl bg-amber-50 p-3"><span className="block text-xs uppercase tracking-wide text-amber-700">Diverted</span><strong>{formatQty(row.diverted_qty)}</strong></div>
              </div>
              {segments.length > 0 ? (
                <div className="mt-4 space-y-2">
                  {segments.map((segment, segmentIndex) => (
                    <div key={`${row.tracking_line_allocation_id}-${segmentIndex}`} className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">
                      <strong>{label(segment.disposition_type)} · {formatQty(segment.quantity)}</strong>
                      {segment.condition_note ? <p className="mt-1">{segment.condition_note}</p> : null}
                    </div>
                  ))}
                </div>
              ) : (
                <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-950">Saved as clean.</p>
              )}
            </article>
          );
        })}
      </div>
    </section>
  );
}
