import Link from "next/link";

const flowLinks = [
  {
    href: "/internal/dva-statement-import",
    step: "1",
    label: "Statement import",
    hint: "Upload, stage, commit or void statement batches",
  },
  {
    href: "/internal/dva-statement-import/mindee-control",
    step: "2",
    label: "PDF OCR control",
    hint: "Run, fetch and parse statement OCR",
  },
  {
    href: "/internal/dva-reconciliation",
    step: "3",
    label: "Control hub",
    hint: "See what needs funding, matching, review or exception action",
  },
  {
    href: "/internal/dva-reconciliation/workspace",
    step: "4",
    label: "Importer matching",
    hint: "Importer DVA/card allocation for supplier, refund, FX/card, fee and hold items",
  },
  {
    href: "/internal/dva-reconciliation/main-bank",
    step: "4B",
    label: "Main bank / shipper",
    hint: "Main company bank OUT lines matched to posted shipper AP invoices",
  },
  {
    href: "/internal/funding",
    step: "5",
    label: "Importer funding",
    hint: "Apply customer/importer IN money to orders or credit",
  },
  {
    href: "/internal/dva-reconciliation/allocations",
    step: "6",
    label: "Allocations & reversals",
    hint: "Review or reverse active allocation records",
  },
  {
    href: "/internal/dva-reconciliation/review-pack",
    step: "7",
    label: "Review pack",
    hint: "Prove statement lines are explained before Sage readiness",
  },
  {
    href: "/internal/dva-reconciliation/exception-actions",
    step: "8",
    label: "Exception actions",
    hint: "Route refund/replacement outcomes to supervisor review",
  },
];

export default function DvaSupervisorFlowNav() {
  return (
    <section className="border-b border-slate-200 bg-white/95 px-4 py-3 shadow-sm backdrop-blur sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="text-[11px] font-bold uppercase tracking-[0.22em] text-sky-600">Supervisor DVA/card flow</p>
            <p className="mt-1 text-xs text-slate-500">Import statement truth → OCR/commit → control hub → importer match or main-bank shipper match → fund/review/reverse → review pack → exception actions → pre-Sage readiness.</p>
          </div>
          <Link href="/internal" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50">
            Internal home
          </Link>
        </div>

        <nav className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-5 xl:grid-cols-9" aria-label="DVA supervisor flow">
          {flowLinks.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className="group rounded-2xl border border-slate-200 bg-slate-50 p-3 text-left transition hover:border-sky-200 hover:bg-sky-50"
            >
              <div className="flex items-center gap-2">
                <span className="inline-flex h-7 min-w-7 items-center justify-center rounded-full bg-white px-2 text-[11px] font-extrabold text-sky-700 ring-1 ring-sky-200">
                  {link.step}
                </span>
                <span className="text-sm font-bold text-slate-950 group-hover:text-sky-800">{link.label}</span>
              </div>
              <p className="mt-1 line-clamp-2 text-[11px] leading-4 text-slate-500">{link.hint}</p>
            </Link>
          ))}
        </nav>
      </div>
    </section>
  );
}
