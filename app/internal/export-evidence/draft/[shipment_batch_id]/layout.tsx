import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type ApRow = {
  blocker?: string | null;
};

type FinalEvidenceRow = {
  review_status?: string | null;
};

type CompletionRow = {
  completion_status?: string | null;
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

export default async function InternalDraftExportEvidenceLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ shipment_batch_id: string }>;
}) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const supabase = await createClient();

  const [apResult, finalEvidenceResult, completionResult] = await Promise.all([
    (supabase as any).rpc("internal_shipping_ap_recharge_readiness_preview_v1", { p_shipment_batch_id: shipmentBatchId }),
    (supabase as any).rpc("internal_final_export_evidence_documents_v1", { p_shipment_batch_id: shipmentBatchId }),
    (supabase as any).rpc("internal_shipment_export_evidence_completion_fields_v1", { p_shipment_batch_id: shipmentBatchId }),
  ]);

  const apRows = ((apResult.data ?? []) as ApRow[]);
  const finalRows = ((finalEvidenceResult.data ?? []) as FinalEvidenceRow[]);
  const completionRows = ((completionResult.data ?? []) as CompletionRow[]);
  const apBlockers = Array.from(new Set(apRows.map((row) => row.blocker).filter(Boolean))) as string[];
  const completionStatus = completionRows[0]?.completion_status ?? null;
  const completionReady = completionStatus === "completion_fields_ready";
  const hasFinalAccepted = finalRows.some((row) => row.review_status === "accepted_current");
  const hasFinalSubmitted = finalRows.some((row) => row.review_status === "submitted_for_review");
  const hasFinalRejected = finalRows.some((row) => row.review_status === "rejected_resubmit_required");

  const draftStatusTone = completionReady && apBlockers.length === 0 ? "ready" : "blocked";
  const draftStatusText = draftStatusTone === "ready" ? "Draft pack basis ready" : "Draft pack basis blocked";
  const finalTone = hasFinalAccepted ? "ready" : hasFinalSubmitted ? "review" : hasFinalRejected ? "blocked" : "muted";
  const finalText = hasFinalAccepted
    ? "Final evidence accepted"
    : hasFinalSubmitted
      ? "Final evidence awaiting supervisor review"
      : hasFinalRejected
        ? "Final evidence rejected / resubmission required"
        : "Final evidence not uploaded yet";

  const blockerText = apBlockers.length > 0
    ? apBlockers.map((blocker) => blocker === "shipper_document_requires_supervisor_acceptance" ? "Shipping AP document requires supervisor acceptance" : friendly(blocker)).join("; ")
    : completionReady ? "No shipping-document blocker detected" : friendly(completionStatus ?? "shipper completion fields not ready");

  return (
    <>
      <style>{`
        main button:disabled,
        main section.border-amber-200.bg-amber-50,
        main section.border-rose-300.bg-rose-50,
        main div.border-rose-200.bg-rose-50 {
          display: none !important;
        }
      `}</style>

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
      <div className="fixed inset-x-0 bottom-4 z-40 flex justify-center px-4 print:hidden">
        <div className="flex max-w-4xl flex-wrap items-center justify-center gap-3 rounded-2xl border border-sky-200 bg-white/95 p-3 shadow-lg backdrop-blur">
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
        </div>
      </div>
    </>
  );
}
