import SafeMindeeFetchPatch from "./SafeMindeeFetchPatch";

export default function InvoiceReviewLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <SafeMindeeFetchPatch />
      {children}
    </>
  );
}
