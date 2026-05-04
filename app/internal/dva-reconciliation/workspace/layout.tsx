import WorkspaceAllocatedSelectionGuard from "./WorkspaceAllocatedSelectionGuard";
import WorkspaceSelectionEnhancer from "./WorkspaceSelectionEnhancer";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <WorkspaceAllocatedSelectionGuard />
      <WorkspaceSelectionEnhancer />
    </>
  );
}
