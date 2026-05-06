import WorkspaceAllocatedSelectionGuard from "./WorkspaceAllocatedSelectionGuard";
import WorkspaceBalanceChipEnhancer from "./WorkspaceBalanceChipEnhancer";
import WorkspaceSelectionEnhancer from "./WorkspaceSelectionEnhancer";
import StatementCardSelectionCompatibility from "./StatementCardSelectionCompatibility";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <WorkspaceBalanceChipEnhancer />
      <WorkspaceAllocatedSelectionGuard />
      <WorkspaceSelectionEnhancer />
      <StatementCardSelectionCompatibility />
    </>
  );
}
