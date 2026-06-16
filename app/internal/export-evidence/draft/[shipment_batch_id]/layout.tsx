import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { FloatingActionBar } from "@/app/_components/FloatingActionBar";

type FinalEvidenceRow = {
  review_status?: string | null;
};

type ExportPackRow = {
  total_export_value_gbp?: string | number | null;
  qty_allocated?: string | number | null;
};

function friendly(value: string | null | undefined) {
  if (!value) return "Not available";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function pill(status: "ready" | "review" | "blocked" | "muted") {
  if (status === "ready") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (status === "review") return "border-amber-200 bg-amber-50 text-amber-900";
  if (status === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  return "border-slate-200 bg-white text-slate-700";
}

function n(value: string | number | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

export default async function InternalDraftExportEvidenceLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ shipment_batch_id: string }>;
}) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const supabase = await createClient();

  const [packResult, finalEvidenceResult] = await Promise.all([
    (supabase as any).rpc("shipper_export_evidence_pack_preview_v1", { p_shipment_batch_id: shipmentBatchId }),
    (supabase as any).rpc("internal_final_export_evidence_documents_v1", { p_shipment_batch_id: shipmentBatchId }),
  ]);

  const packRows = ((packResult.data ?? []) as ExportPackRow[]);
  const finalRows = ((finalEvidenceResult.data ?? []) as FinalEvidenceRow[]);
  const totalQty = packRows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const totalValue = packRows.reduce((sum, row) => sum + n(row.total_export_value_gbp), 0);
  const hasFinalAccepted = finalRows.some((row) => row.review_status === "accepted_current");
  const hasFinalSubmitted = finalRows.some((row) => row.review_status === "submitted_for_review");
  const hasFinalRejected = finalRows.some((row) => row.review_status === "rejected_resubmit_required");

  const draftBlockers = [
    packResult.error ? "COS/EEP pack preview unavailable" : null,
    packRows.length === 0 ? "COS/EEP line schedule is empty" : null,
    totalQty <= 0 ? "COS/EEP quantity is missing" : null,
    totalValue <= 0 ? "COS/EEP invoice export value is missing" : null,
  ].filter(Boolean) as string[];

  const draftStatusTone = draftBlockers.length === 0 ? "ready" : "blocked";
  const draftStatusText = draftStatusTone === "ready" ? "Draft pack basis ready" : "Draft pack basis blocked";
  const finalTone = hasFinalAccepted ? "ready" : hasFinalSubmitted ? "review" : hasFinalRejected ? "blocked" : "muted";
  const finalText = hasFinalAccepted
    ? "Final evidence accepted"
    : hasFinalSubmitted
      ? "Final evidence awaiting supervisor review"
      : hasFinalRejected
        ? "Final evidence rejected / resubmission required"
        : "Final evidence not uploaded yet";

  const blockerText = draftBlockers.length > 0
    ? draftBlockers.map((blocker) => friendly(blocker)).join("; ")
    : "COS / EEP line schedule has invoice-backed quantity and value";

  return (
    <>
      <section className="bg-slate-50 px-4 pt-4 sm:px-6">
        <div className="mx-auto grid max-w-7xl gap-3 rounded-3xl border border-slate-200 bg-white p-4 shadow-sm md:grid-cols-2">
          <div className={`rounded-2xl border p-4 ${pill(draftStatusTone)}`}>
            <p className="text-xs font-semibold uppercase tracking-wide opacity-70">Draft COS / EEP status</p>
            <p className="mt-1 text-lg font-semibold">{draftStatusText}</p>
            <p className="mt-2 text-sm leading-5">{blockerText}</p>
          </div>
          <div className={`rounded-2xl border p-4 ${pill(finalTone)}`}>
            <p className="text-xs font-semibold uppercase tracking-wide opacity-70">Final export evidence status</p>
            <p className="mt-1 text-lg font-semibold">{finalText}</p>
            <p className="mt-2 text-sm leading-5">{finalRows.length} uploaded document(s)</p>
          </div>
        </div>
      </section>

      {children}
      <div className="h-32 print:hidden" aria-hidden="true" />
      <FloatingActionBar innerClassName="flex max-w-4xl flex-wrap items-center justify-center gap-3 rounded-2xl border border-sky-200 bg-white/95 p-3 shadow-lg backdrop-blur">
        <Link
          href={`/shipper/shipments/${shipmentBatchId}/draft-cos-pack`}
          className="rounded-xl border border-emerald-300 bg-emerald-50 px-4 py-2 text-sm font-semibold text-emerald-900 hover:bg-emerald-100"
        >
          Download draft COS + EEP pack
        </Link>
        <Link
          href={`/internal/export-evidence/final/${shipmentBatchId}`}
          className="rounded-xl border border-sky-300 bg-sky-50 px-4 py-2 text-sm font-semibold text-sky-900 hover:bg-sky-100"
        >
          Review uploaded final evidence
        </Link>
        <span className="text-xs font-medium text-slate-600">
          Internal actions for this shipment batch.
        </span>
      </FloatingActionBar>
    </>
  );
}
