import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type QueueCard = {
  title: string;
  href: string;
  description: string;
  proof: string;
};

type FlowStep = {
  step: string;
  title: string;
  href: string;
  description: string;
};

const dvaFlowSteps: FlowStep[] = [
  {
    step: "1",
    title: "Upload / import statement",
    href: "/internal/dva-statement-import",
    description: "Start here for bank, card, DVA and statement uploads. Create the batch, parse/OCR, review, commit or void.",
  },
  {
    step: "2",
    title: "Match workspace",
    href: "/internal/dva-reconciliation/workspace",
    description: "Match committed statement lines to supplier invoices, refund exceptions, replacement holds and FX/card differences.",
  },
  {
    step: "3",
    title: "Allocation review",
    href: "/internal/dva-reconciliation/allocations",
    description: "Review active allocations and reverse a wrong allocation before downstream control.",
  },
  {
    step: "4",
    title: "Control hub",
    href: "/internal/dva-reconciliation",
    description: "Use as a summary and diagnostic view. Not the main matching workspace.",
  },
];

const shippingFlowSteps: FlowStep[] = [
  {
    step: "1",
    title: "Shipping control centre",
    href: "/internal/shipping-control",
    description: "Start here for shipment batches, package truth, receipt status, allocation status and next-lane visibility.",
  },
  {
    step: "2",
    title: "Review shipper docs",
    href: "/internal/shipping-control/shipper-documents",
    description: "Supervisor reviews uploaded shipper charge documents and accepts/rejects the current money source.",
  },
  {
    step: "3",
    title: "Apportionment next",
    href: "/internal/shipping-control",
    description: "Next build lane: accepted charge document → shipping cost apportionment preview and Sage/AP readiness.",
  },
  {
    step: "4",
    title: "Export evidence later",
    href: "/internal/shipping-control",
    description: "COS/BOL/POD/container evidence stays separate from shipper charge document review.",
  },
];

const cards: QueueCard[] = [
  {
    title: "DVA/card statement workflow",
    href: "/internal/dva-statement-import",
    description: "Start here for bank/card/DVA statement upload, OCR or parsing, staging, commit, and safe import voiding.",
    proof: "Statement import → commit → matching",
  },
  {
    title: "DVA/card matching workspace",
    href: "/internal/dva-reconciliation/workspace",
    description: "Two-pane supervisor workspace for matching committed statement lines to supplier invoices, refunds, exceptions, holds, and FX/card differences.",
    proof: "Primary DVA/card matching page",
  },
  {
    title: "Allocation review / reversal",
    href: "/internal/dva-reconciliation/allocations",
    description: "Review active statement-line allocations and reverse only the incorrect allocation row when needed.",
    proof: "Pre-review allocation control",
  },
  {
    title: "DVA/card control hub",
    href: "/internal/dva-reconciliation",
    description: "Summary and diagnostic view for statement-line positions, unmatched signals, and importer control totals. Not the main matching page.",
    proof: "Control summary only",
  },
  {
    title: "Importer funding queue",
    href: "/internal/funding",
    description: "Separate money-received flow: importer funding, funding gaps, overfunding credit, and importer credit application.",
    proof: "Separate from card spend matching",
  },
  {
    title: "Shipping control centre",
    href: "/internal/shipping-control",
    description: "Supervisor spine for importer shipment batches, package receipt truth, allocation status, shipper invoice lane, draft COS lane, master shipment lane and Sage readiness placeholders.",
    proof: "Shipping control read-only v1",
  },
  {
    title: "Shipper invoice / receipt review",
    href: "/internal/shipping-control/shipper-documents",
    description: "Supervisor lane for uploaded shipper charge documents. Accept current document to lock the money source before apportionment.",
    proof: "One active charge document per batch",
  },
  {
    title: "Evidence / OCR queue",
    href: "/internal/evidence",
    description: "Invoice-first, tracking-first, OCR review, progressed subset, and source-line protection.",
    proof: "Day 3 regression passed",
  },
  {
    title: "Invoice exceptions",
    href: "/internal/invoice-review",
    description: "Supervisor queue for wrong invoices, OCR/header issues, total mismatches, unresolved lines, and resubmission problems.",
    proof: "Exceptions-only invoice gate",
  },
  {
    title: "Supplier draft ready",
    href: "/internal/supplier-draft-ready",
    description: "Clean supplier invoices that passed readiness checks and can be bulk approved as current before Sage supplier draft preparation.",
    proof: "Bulk approval lane v1",
  },
  {
    title: "Refund document control",
    href: "/internal/refund-document-control",
    description: "Supplier credit and refund-document queue for credit notes, refund proof without credit note, and no-document evidence. Open the detail page to release, code net/VAT/gross, and approve current.",
    proof: "Supplier credit control lane v1",
  },
  {
    title: "Adjustment review",
    href: "/internal/adjustments",
    description: "Supervisor approval for retailer discounts and over-limit delivery charges before final invoice drafting.",
    proof: "Portal operations addendum v1",
  },
  {
    title: "Child exceptions",
    href: "/internal/exceptions",
    description: "Refund gate, replacement child orders, and unresolved child exception control.",
    proof: "Day 4 regression passed",
  },
  {
    title: "Shipping handoff",
    href: "/internal/shipping",
    description: "Legacy/progressive shipment-ready scope, quote confirmation, booking, dispatch, and delivery evidence. Use Shipping control centre for the new package-batch flow.",
    proof: "Day 5 regression passed",
  },
  {
    title: "Accounting / VAT",
    href: "/internal/accounting-vat",
    description: "Sage queue, released sales invoices, VAT prepayment timing, Box 1 breach and Box 6 reporting.",
    proof: "Day 6/8 regression passed",
  },
  {
    title: "Escalations",
    href: "/internal/escalations",
    description: "Admin governance queue for funding, VAT, release, shipping, and exception anomalies.",
    proof: "Day 7/9 regression passed",
  },
];

export default async function InternalPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-8">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-500">
            Goodcashback Internal
          </p>
          <div className="mt-3 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">
                Staff control dashboard
              </h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Use DVA/card workflow for statement work and Shipping control centre for package/shipment, shipper invoice, export evidence and Sage readiness visibility.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-sky-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.22em] text-sky-600">Start here for DVA/card statements</p>
              <h2 className="mt-2 text-2xl font-semibold tracking-tight">DVA/card statement workflow</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This is the supervisor route for statement uploads, OCR/commit, matching, allocation review, reversal, and later grouped pre-Sage review.
              </p>
            </div>
            <Link href="/internal/dva-statement-import" className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-sky-700">
              Start statement workflow →
            </Link>
          </div>

          <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            {dvaFlowSteps.map((step) => (
              <Link
                key={step.href}
                href={step.href}
                className="rounded-2xl border border-slate-200 bg-slate-50 p-4 transition hover:border-sky-300 hover:bg-sky-50"
              >
                <div className="flex items-center gap-2">
                  <span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-white px-2 text-xs font-extrabold text-sky-700 ring-1 ring-sky-200">
                    {step.step}
                  </span>
                  <h3 className="font-semibold text-slate-950">{step.title}</h3>
                </div>
                <p className="mt-2 text-xs leading-5 text-slate-600">{step.description}</p>
              </Link>
            ))}
          </div>
        </section>

        <section className="rounded-3xl border border-emerald-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.22em] text-emerald-600">Start here for shipper-side testing</p>
              <h2 className="mt-2 text-2xl font-semibold tracking-tight">Shipping control workflow</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Use these links after logging in as staff/supervisor. This avoids manual URL copying when testing uploaded shipper charge documents and acceptance locks.
              </p>
            </div>
            <Link href="/internal/shipping-control/shipper-documents" className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-emerald-800">
              Review shipper docs →
            </Link>
          </div>

          <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            {shippingFlowSteps.map((step) => (
              <Link
                key={`${step.step}-${step.href}-${step.title}`}
                href={step.href}
                className="rounded-2xl border border-slate-200 bg-slate-50 p-4 transition hover:border-emerald-300 hover:bg-emerald-50"
              >
                <div className="flex items-center gap-2">
                  <span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-white px-2 text-xs font-extrabold text-emerald-700 ring-1 ring-emerald-200">
                    {step.step}
                  </span>
                  <h3 className="font-semibold text-slate-950">{step.title}</h3>
                </div>
                <p className="mt-2 text-xs leading-5 text-slate-600">{step.description}</p>
              </Link>
            ))}
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {cards.map((card) => (
            <Link
              key={card.href}
              href={card.href}
              className="group rounded-3xl border border-slate-200 bg-white p-5 shadow-sm transition hover:-translate-y-0.5 hover:border-sky-300 hover:shadow-md"
            >
              <h2 className="text-lg font-semibold text-slate-950">{card.title}</h2>
              <p className="mt-2 text-sm leading-6 text-slate-600">{card.description}</p>
              <p className="mt-5 text-xs font-medium text-slate-500">{card.proof}</p>
              <div className="mt-5 text-sm font-semibold text-sky-600 group-hover:text-sky-700">
                Open →
              </div>
            </Link>
          ))}
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Build guardrails</h2>
          <p className="mt-2">
            Stable progressed subsets may move forward. Open children block final
            whole-order closure, not stable subset release. VAT is
            prepayment-first and sales-invoice based. Sage posting remains queued
            and idempotent. Shipper package batches are movement truth only; shipper invoices, export evidence and Sage readiness stay in separate supervisor lanes.
          </p>
        </section>
      </div>
    </main>
  );
}
