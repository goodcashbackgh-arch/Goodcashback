import SafeWorkspaceSelectionController from "./SafeWorkspaceSelectionController";

export default function DvaWorkspaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <SafeWorkspaceSelectionController />
    </>
  );
}
