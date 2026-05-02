import CompactInvoiceLinesPatch from "./CompactInvoiceLinesPatch";

export default function ImporterReconciliationLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <CompactInvoiceLinesPatch />
      {children}
    </>
  );
}
