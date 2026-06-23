import Link from "next/link";

const navItems = [
  {
    title: "Main workbench",
    detail: "AR/AP/CN freeze, revalidate and batch",
    href: "/internal/accounting-command-centre",
  },
  {
    title: "Closure control",
    detail: "Read-only posted vs closed proof pack",
    href: "/internal/accounting-command-centre/closure",
  },
  {
    title: "Cash receipts & payments",
    detail: "DVA/card/bank IN and OUT cash posting",
    href: "/internal/accounting-command-centre/cash-posting",
  },
  {
    title: "Cash allocations",
    detail: "Allocate posted receipts/payments to matched Sage documents",
    href: "/internal/accounting-command-centre/cash-posting/allocations",
  },
  {
    title: "Loyalty controls",
    detail: "Read-only completion-loyalty accounting controls",
    href: "/internal/accounting-command-centre/loyalty-controls",
  },
  {
    title: "Frozen snapshots",
    detail: "Payload drill-down before posting",
    href: "/internal/accounting-command-centre/posting-preview",
  },
  {
    title: "Sage mappings",
    detail: "Contacts, bank, GL and tax mappings",
    href: "/internal/sage-mapping",
  },
];

export default function AccountingCommandCentreLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <div className="border-b border-slate-200 bg-white px-4 py-3 text-slate-950 shadow-sm sm:px-6 lg:px-8">
        <div className="mx-auto flex max-w-[1600px] flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
          <div>
            <p className="text-[11px] font-bold uppercase tracking-[0.2em] text-violet-500">Accounting Command Centre navigation</p>
            <p className="mt-1 text-sm text-slate-600">Use these shortcuts to move between posting, closure, cash, loyalty control and allocation sections without guessing URLs.</p>
          </div>
          <nav className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-7" aria-label="Accounting Command Centre sections">
            {navItems.map((item) => (
              <Link key={item.href} href={item.href} className="rounded-2xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs shadow-sm transition hover:-translate-y-0.5 hover:border-violet-200 hover:bg-violet-50 hover:text-violet-900 hover:shadow-md">
                <span className="block font-extrabold text-slate-950">{item.title}</span>
                <span className="mt-0.5 block leading-4 text-slate-600">{item.detail}</span>
              </Link>
            ))}
          </nav>
        </div>
      </div>
      {children}
    </>
  );
}
