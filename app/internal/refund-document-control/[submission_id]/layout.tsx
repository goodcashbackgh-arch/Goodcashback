import Link from "next/link";
import RefundDocumentControlEnhancer from "./RefundDocumentControlEnhancer";
import RefundDocumentGridCalculator from "./RefundDocumentGridCalculator";

export default async function RefundDocumentControlDetailLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ submission_id: string }>;
}) {
  const { submission_id: submissionId } = await params;

  return (
    <>
      <div className="bg-amber-50 px-6 py-3 text-sm text-amber-950 ring-1 ring-amber-200">
        <div className="mx-auto flex max-w-[1500px] flex-wrap items-center justify-between gap-3">
          <span className="font-semibold">Supervisor refund document control:</span>
          <span className="text-amber-900">
            If the uploaded credit note/refund evidence is wrong, send it back for operator resubmission.
          </span>
          <Link
            href={`/internal/refund-document-control/${submissionId}/request-resubmission`}
            className="rounded-xl bg-amber-700 px-3 py-2 font-semibold text-white hover:bg-amber-600"
          >
            Request resubmission
          </Link>
        </div>
      </div>
      <RefundDocumentGridCalculator />
      <RefundDocumentControlEnhancer submissionId={submissionId} />
      {children}
    </>
  );
}
