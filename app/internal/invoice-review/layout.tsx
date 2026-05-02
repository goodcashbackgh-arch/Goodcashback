import SafeMindeeFetchPatch from "./SafeMindeeFetchPatch";
import CompactInvoiceReviewPatch from "./CompactInvoiceReviewPatch";

export default function InvoiceReviewLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <SafeMindeeFetchPatch />
      <CompactInvoiceReviewPatch />
      {children}
    </>
  );
}
