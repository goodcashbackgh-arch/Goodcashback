import RefundDocumentGridCalculator from "./RefundDocumentGridCalculator";

export default function RefundDocumentControlDetailLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <RefundDocumentGridCalculator />
      {children}
    </>
  );
}
