import WorkspaceAllocatedSelectionGuard from "./WorkspaceAllocatedSelectionGuard";
import WorkspaceBalanceChipEnhancer from "./WorkspaceBalanceChipEnhancer";
import WorkspaceSelectionEnhancer from "./WorkspaceSelectionEnhancer";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <WorkspaceBalanceChipEnhancer />
      <WorkspaceAllocatedSelectionGuard />
      <WorkspaceSelectionEnhancer />
    </>
  );
}
