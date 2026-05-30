import Link from "next/link";

const steps = [
  {
    no: "1",
    title: "Generate platform VAT pack",
    status: "Active",
    href: "/internal/accounting-vat?tab=runs",
    tone: "sky",
    detail: "Creates the platform source pack and draft VAT run. No HMRC pull, Sage post, journal approval or return lock.",
  },
  {
    no: "2",
    title: "Sage natural extraction",
    status: "Active",
    href: "/internal/accounting-vat/sage-diagnostics",
    tone: "sky",
    detail: "Read-only Sage reconstruction with status-audited included/excluded documents and Box 1/4/6/7 checks.",
  },
  {
    no: "3",
    title: "Platform statutory overlay",
    status: "Active",
    href: "/internal/accounting-vat/platform-overlay",
    tone: "sky",
    detail: "Prepayment Box 6 timing, anti-duplicate Box 6, and export-evidence Box 1 breach/reinstatement preview.",
  },
  {
    no: "4",
    title: "Compare and adjustment pack",
    status: "Next build",
    href: "/internal/accounting-vat?tab=journals",
    tone: "amber",
    detail: "Calculate required adjustment = platform statutory position minus Sage natural position. Read-only before any journal queue.",
  },
  {
    no: "5",
    title: "Sage journal / MTD readiness",
    status: "Locked",
    href: "/internal/accounting-command-centre",
    tone: "slate",
    detail: "No posting yet. Only opens after generation, Sage extraction, platform overlay and adjustment pack all tie.",
  },
  {
    no: "6",
    title: "Submit, reconcile and lock",
    status: "Locked",
    href: "/internal/accounting-vat?tab=blockers",
    tone: "slate",
    detail: "Manual Sage/MTD submission and platform lock only after Sage and platform agree with no open blockers.",
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
          <h2 className="text-xl font-semibold tracking-tight">VAT workflow control path</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            The platform position must be built in layers: generate the platform pack, tie the Sage natural extraction, then apply the statutory VAT overlay. Sage journals and MTD submission stay locked until those layers agree.
          </p>
        </div>
        <Link href="/internal/accounting-vat/platform-overlay" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-slate-800">
          Open platform overlay →
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
