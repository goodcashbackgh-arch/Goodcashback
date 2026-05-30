import Link from "next/link";

const actions = [
  {
    title: "Generate VAT Return Pack",
    href: "/internal/accounting-vat?tab=runs",
    description: "Create the next permitted return pack only when no earlier return pack is still open.",
  },
  {
    title: "Open Current Draft",
    href: "/internal/accounting-vat/current-draft",
    description: "Open the earliest unlocked return pack that must be reviewed first.",
  },
  {
    title: "View Blockers",
    href: "/internal/accounting-vat/blockers",
    description: "See what prevents approval, journal posting, submission, or lock.",
  },
  {
    title: "View Prior Returns",
    href: "/internal/accounting-vat?tab=runs",
    description: "Review return history and open an older return pack from the list.",
  },
];

export default function VatWorkflowPreview() {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold tracking-tight">VAT dashboard actions</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            This dashboard is the control room. The detailed VAT work happens inside the return pack. Sage posting and Sage/MTD submission stay locked until the pack is clean.
          </p>
        </div>
        <Link href="/internal/accounting-vat/current-draft" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-slate-800">
          Open current draft →
        </Link>
      </div>

      <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        {actions.map((action) => (
          <Link key={action.title} href={action.href} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 transition hover:border-sky-300 hover:bg-sky-50">
            <h3 className="font-semibold text-slate-950">{action.title}</h3>
            <p className="mt-2 text-xs leading-5 text-slate-600">{action.description}</p>
          </Link>
        ))}
      </div>
    </section>
  );
}
