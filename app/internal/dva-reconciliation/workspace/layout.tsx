import AllocationResultToast from "./AllocationResultToast";
import CandidateDirectionGuard from "./CandidateDirectionGuard";
import CompletedTargetGuard from "./CompletedTargetGuard";
import SafeWorkspaceSelectionController from "./SafeWorkspaceSelectionController";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <AllocationResultToast />
      {children}
      <CompletedTargetGuard />
      <CandidateDirectionGuard />
      <SafeWorkspaceSelectionController />
    </>
  );
}
