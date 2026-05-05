import DvaSupervisorFlowNav from "../DvaSupervisorFlowNav";

export default function DvaStatementImportLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <DvaSupervisorFlowNav />
      {children}
    </>
  );
}
