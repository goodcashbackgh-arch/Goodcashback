import AllocationResultToast from "./AllocationResultToast";
import CompletedTargetGuard from "./CompletedTargetGuard";
import SafeWorkspaceSelectionController from "./SafeWorkspaceSelectionController";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <AllocationResultToast />
      {children}
      <CompletedTargetGuard />
      <SafeWorkspaceSelectionController />
    </>
  );
}
