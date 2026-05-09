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
      <RefundDocumentGridCalculator />
      <RefundDocumentControlEnhancer submissionId={submissionId} />
      {children}
    </>
  );
}
