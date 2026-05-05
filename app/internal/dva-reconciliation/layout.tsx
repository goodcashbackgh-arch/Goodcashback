import DvaSupervisorFlowNav from "../DvaSupervisorFlowNav";

export default function DvaReconciliationLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <DvaSupervisorFlowNav />
      {children}
    </>
  );
}
