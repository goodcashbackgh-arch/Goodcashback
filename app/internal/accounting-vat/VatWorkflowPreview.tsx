import Link from "next/link";

const steps = [
  {
    no: "1",
    title: "Generate VAT Return Pack",
    status: "Active",
    href: "/internal/accounting-vat?tab=runs",
    tone: "sky",
    detail: "Creates the platform source pack and draft VAT run. No HMRC pull, Sage post, journal approval or return lock.",
  },
  {
    no: "2",
    title: "Open Current Draft",
    status: "Active",
    href: "/internal/accounting-vat/current-draft",
    tone: "sky",
    detail: "Opens the latest unlocked return pack detail route required by the saved contract.",
  },
  {
    no: "3",
    title: "Review source lines and blockers",
    status: "Active",
    href: "/internal/accounting-vat/current-draft",
    tone: "sky",
    detail: "Use the contract tabs for Summary, Source Lines, Box 6 Timing, Export Evidence, Purchases, Journals and Submission Evidence.",
  },
  {
    no: "4",
    title: "Sage natural extraction",
    status: "Active",
    href: "/internal/accounting-vat/sage-diagnostics",
    tone: "sky",
    detail: "Read-only Sage reconstruction with status-audited included/excluded documents and Box 1/4/6/7 checks.",
  },
  {
    no: "5",
    title: "Sage adjustment journals",
    status: "Locked",
    href: "/internal/accounting-vat/current-draft?tab=journals",
    tone: "slate",
    detail: "No posting yet. Journal only the Sage gap after return pack, blockers and statutory comparison are clean.",
  },
  {
    no: "6",
    title: "Submit in Sage, match and lock",
    status: "Locked",
    href: "/internal/accounting-vat/current-draft?tab=submission",
    tone: "slate",
    detail: "Manual Sage/MTD submission and platform lock only after Sage submitted values match the platform pack.",
  },
];

function classes(tone: string) {
  if (tone === "sky") return "border-sky-200 bg-sky-50 hover:border-sky-300";
  if (tone === "amber") return "border-amber-200 bg-amber-50 hover:border-amber-300";
  return "border-slate-200 bg-slate-50 hover:border-slate-300";
}

function badgeClasses(tone: string) {
  if (tone === "sky") return "bg-sky-100 text-sky-800 ring-sky-200";
  if (tone === "amber") return "bg-amber-100 text-amber-800 ring-amber-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

export default function VatWorkflowPreview() {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold tracking-tight">VAT return contract workflow</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Dashboard stays as a command overview. Detailed VAT working sits under the contract return-pack route. Sage journals and MTD submission stay locked until the pack, blockers and Sage coverage agree.
          </p>
        </div>
        <Link href="/internal/accounting-vat/current-draft" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-slate-800">
          Open current draft pack →
        </Link>
      </div>

      <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {steps.map((step) => (
          <Link key={step.no} href={step.href} className={`rounded-2xl border p-4 transition ${classes(step.tone)}`}>
            <div className="flex items-center gap-2">
              <span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-white px-2 text-xs font-extrabold text-slate-800 ring-1 ring-slate-200">
                {step.no}
              </span>
              <div>
                <h3 className="font-semibold text-slate-950">{step.title}</h3>
                <span className={`mt-1 inline-flex rounded-full px-2 py-0.5 text-[11px] font-bold ring-1 ${badgeClasses(step.tone)}`}>{step.status}</span>
              </div>
            </div>
            <p className="mt-3 text-xs leading-5 text-slate-700">{step.detail}</p>
          </Link>
        ))}
      </div>
    </section>
  );
}
