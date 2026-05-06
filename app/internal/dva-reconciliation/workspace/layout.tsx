import WorkspaceAllocatedSelectionGuard from "./WorkspaceAllocatedSelectionGuard";
import WorkspaceBalanceChipEnhancer from "./WorkspaceBalanceChipEnhancer";
import StatementCardSelectionCompatibility from "./StatementCardSelectionCompatibility";
import WorkspaceUrlSelectionHydrator from "./WorkspaceUrlSelectionHydrator";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <WorkspaceBalanceChipEnhancer />
      <WorkspaceAllocatedSelectionGuard />
      <StatementCardSelectionCompatibility />
      <WorkspaceUrlSelectionHydrator />
    </>
  );
}
