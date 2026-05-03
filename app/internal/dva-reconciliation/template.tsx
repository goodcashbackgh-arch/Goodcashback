import ResidualAllocationUiGuard from "./ResidualAllocationUiGuard";

export default function DvaReconciliationTemplate({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
      <ResidualAllocationUiGuard />
      {children}
    </>
  );
}
