import Link from "next/link";

export default function DvaStatementImportLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <div className="pointer-events-none fixed bottom-5 right-4 z-50 sm:bottom-6 sm:right-6">
        <Link
          href="/internal/dva-statement-import/mindee-control"
          className="pointer-events-auto inline-flex items-center justify-center rounded-full bg-slate-950 px-4 py-3 text-sm font-semibold text-white shadow-lg ring-1 ring-slate-800/20"
        >
          Open PDF Mindee control
        </Link>
      </div>
    </>
  );
}
