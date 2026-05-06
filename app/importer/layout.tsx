import ReplacementOrdersPanel from "./ReplacementOrdersPanel";

export default function ImporterLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <div className="px-6 pb-8">
        <div className="mx-auto max-w-7xl">
          <ReplacementOrdersPanel />
        </div>
      </div>
    </>
  );
}
