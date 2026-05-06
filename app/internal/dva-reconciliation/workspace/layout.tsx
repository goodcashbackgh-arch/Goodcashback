import AllocationResultToast from "./AllocationResultToast";
import SafeWorkspaceSelectionController from "./SafeWorkspaceSelectionController";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <AllocationResultToast />
      {children}
      <SafeWorkspaceSelectionController />
    </>
  );
}
