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
    label: "PDF statement extraction",
    hint: "Run document read and parse statement",
  },
  {
    href: "/internal/dva-reconciliation",
    step: "3",
    label: "Control hub",
    hint: "See what needs payment, matching, review or exception action",
  },
  {
    href: "/internal/dva-reconciliation/control-summary",
    step: "3A",
    label: "Treasury summary",
    hint: "Effective interpretation, amount-aware position, blockers and governed next action",
  },
  {
    href: "/internal/dva-reconciliation/statement-interpretation",
    step: "3B",
    label: "Interpretation control",
    hint: "Audited direction, classification and display correction while raw evidence remains immutable",
  },
  {
    href: "/internal/dva-reconciliation/workspace",
    step: "4",
    label: "Importer matching",
    hint: "Supplier invoices are applied sequentially in one workspace; FX, fees, refunds and holds use the same statement-line balance",
  },
  {
    href: "/internal/dva-reconciliation/main-bank",
    step: "4A",
    label: "Main bank / shipper",
    hint: "Main-company-bank OUT matched to approved shipper AP or completion-loyalty transfer evidence",
  },
  {
    href: "/internal/funding",
    step: "5",
    label: "Order funding",
    hint: "Apply eligible importer DVA/card IN value to orders or governed credit",
  },
  {
    href: "/internal/dva-reconciliation/allocations",
    step: "6",
    label: "Allocation register",
    hint: "Review active supplier, refund, fee, variance and hold matching records",
  },
  {
    href: "/internal/dva-reconciliation/reversal-control",
    step: "6A",
    label: "Reversal control",
    hint: "Reverse one incorrect economic-use row while preserving statement and allocation history",
  },
  {
    href: "/internal/dva-reconciliation/review-pack",
    step: "7",
    label: "Review pack",
    hint: "Prove each statement line is explained before accounting readiness",
  },
  {
    href: "/internal/dva-reconciliation/exception-actions",
    step: "8",
    label: "Exception actions",
    hint: "Route refund and replacement outcomes to supervisor review",
  },
];

export default function DvaSupervisorFlowNav() {
  return (
    <section className="border-b border-slate-200 bg-white/95 px-4 py-3 shadow-sm backdrop-blur sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="text-[11px] font-bold uppercase tracking-[0.22em] text-sky-600">Supervisor payment flow</p>
            <p className="mt-1 text-xs text-slate-500">
              Import immutable statement truth → audited interpretation → amount-aware treasury control → governed funding, supplier, loyalty, shipper or exception lane → review/reverse → accounting readiness.
            </p>
          </div>
          <Link href="/internal" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50">
            Internal home
          </Link>
        </div>

        <nav className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-5 xl:grid-cols-12" aria-label="Supervisor payment flow">
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
