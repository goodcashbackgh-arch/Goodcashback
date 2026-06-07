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
    step: "2A",
    title: "Importer match workspace",
    href: "/internal/dva-reconciliation/workspace",
    description: "Use for importer DVA/card statement lines matched to supplier invoices, refunds, exceptions, holds and FX/card differences.",
  },
  {
    step: "2B",
    title: "Main bank / shipper match",
    href: "/internal/dva-reconciliation/main-bank",
    description: "Use for main company bank OUT lines matched to posted shipper AP invoices. This branch does not touch importer matching.",
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
    title: "Delivery allocation / value apportionment",
    href: "/internal/shipping-control?focus=delivery-allocation",
    description: "Open the shipment batch, then use Review delivery allocation to allocate progressed invoice lines to packages and trigger delivery/discount apportionment.",
  },
  {
    step: "3",
    title: "Review shipper docs",
    href: "/internal/shipping-control/shipper-documents",
    description: "Supervisor reviews uploaded shipper charge documents and accepts/rejects the current money source.",
  },
  {
    step: "4",
    title: "Customer invoice release queue",
    href: "/internal/shipping-control/customer-invoice-release",
    description: "Create controlled customer sales invoice drafts from stable shipment/customer invoice intents.",
  },
  {
    step: "5",
    title: "Accounting Command Centre",
    href: "/internal/accounting-command-centre",
    description: "Single accounting cockpit for live-ready rows, mapping signals, freeze, revalidation, frozen snapshots and posting readiness.",
  },
];

const cards: QueueCard[] = [
  {
    title: "Supervisor command centre",
    href: "/internal/supervisor-command-centre",
    description: "Official operational cockpit: one grid row per order/order-shipment grouping covering funding, DVA/card, supplier invoice, exceptions, logistics, customer sales, shipper AP, export/delivery and next action.",
    proof: "Daily cockpit 1 of 2 — operational readiness",
  },
  {
    title: "Accounting command centre",
    href: "/internal/accounting-command-centre",
    description: "Official accounting/Sage cockpit: live-ready documents, frozen snapshots, revalidation, posting gates, mapping/settings diagnostics and future batch posting control.",
    proof: "Daily cockpit 2 of 2 — accounting execution readiness",
  },
  {
    title: "DVA/card statement workflow",
    href: "/internal/dva-statement-import",
    description: "Start here for bank/card/DVA statement upload, OCR or parsing, staging, commit, and safe import voiding.",
    proof: "Statement import → commit → matching",
  },
  {
    title: "DVA/card importer matching workspace",
    href: "/internal/dva-reconciliation/workspace",
    description: "Two-pane supervisor workspace for matching importer DVA/card statement lines to supplier invoices, refunds, exceptions, holds, and FX/card differences.",
    proof: "Importer DVA/card matching page",
  },
  {
    title: "Main bank / shipper matching",
    href: "/internal/dva-reconciliation/main-bank",
    description: "Separate branch for committed main company bank OUT lines. Match them to posted shipper AP invoices without changing the importer supplier/retailer workflow.",
    proof: "Main bank → shipper AP branch",
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
    description: "Summary and diagnostic view for statement-line positions, unmatched signals, and importer control totals. Not the main matching workspace.",
    proof: "Control summary only",
  },
  {
    title: "Importer funding queue",
    href: "/internal/funding",
    description: "Separate money-received flow: importer funding, funding gaps, overfunding credit, and importer credit application.",
    proof: "Separate from card spend matching",
  },
  {
    title: "Completion loyalty rewards",
    href: "/internal/completion-loyalty-rewards",
    description: "Supervisor lane for completion reward proposals, approval-in-principle, customer DVA/account funding proof and dashboard credit release.",
    proof: "Cash-backed v2 reward control",
  },
  {
    title: "Shipping control centre",
    href: "/internal/shipping-control",
    description: "Supervisor spine for importer shipment batches, package receipt truth, allocation status, shipper invoice lane, customer invoice lane, master shipment lane and accounting-readiness placeholders.",
    proof: "Shipping control task room",
  },
  {
    title: "Delivery allocation / value apportionment",
    href: "/internal/shipping-control?focus=delivery-allocation-card",
    description: "Route to the shipment batch detail, then use Review delivery allocation to allocate progressed invoice lines to packages and recalculate delivery/discount shares on adjusted net values.",
    proof: "Shipping control → batch detail → Review delivery allocation",
  },
  {
    title: "Shipper invoice / receipt review",
    href: "/internal/shipping-control/shipper-documents",
    description: "Supervisor lane for uploaded shipper charge documents. Accept current document to lock the money source before apportionment.",
    proof: "One active charge document per batch",
  },
  {
    title: "Customer invoice release queue",
    href: "/internal/shipping-control/customer-invoice-release",
    description: "Bulk-create controlled customer sales invoice drafts from stable, approved customer invoice intents.",
    proof: "Internal sales invoice draft gate",
  },
  {
    title: "Customer pre-shipment holds",
    href: "/internal/customer-holds",
    description: "Supervisor worklist for customer review links, item/package/order hold requests, approvals, rejections, and narrowing customer holds to exact item lines before shipment.",
    proof: "Customer hold review and approval gate",
  },
  {
    title: "Sage mapping diagnostic",
    href: "/internal/sage-mapping",
    description: "Legacy/drill-down mapping page. Daily accounting users should start from Accounting Command Centre; this page remains for exact mapping edits until the settings tab is fully absorbed.",
    proof: "Demoted under v4 — not a command centre",
  },
  {
    title: "Pre-Sage readiness diagnostic",
    href: "/internal/status-control/pre-sage-financial-readiness",
    description: "Legacy blocker pack for order-level diagnosis. Daily users should start from Supervisor Command Centre or Accounting Command Centre, not this page.",
    proof: "Demoted under v4 — diagnostic only",
  },
  {
    title: "Live-ready queue diagnostic",
    href: "/internal/sage-ready",
    description: "Legacy live-ready queue. Its daily function now belongs inside Accounting Command Centre filters; keep this as a support/diagnostic page only.",
    proof: "Demoted under v4 — use Accounting Command Centre first",
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
    description: "Clean supplier invoices that passed readiness checks and can be bulk approved as current before accounting handoff.",
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
    description: "VAT reporting, released sales invoice reporting, prepayment timing, Box 1 breach and Box 6 reporting. Sage/accounting cockpit sits under Accounting Command Centre.",
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
                v4 operating model: use Supervisor Command Centre for operational readiness and Accounting Command Centre for accounting/Sage execution readiness. Legacy Sage-ready, mapping and pre-Sage readiness pages remain diagnostic drill-downs, not daily command pages.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
          </div>
        </section>

        <section className="grid gap-4 md:grid-cols-2">
          <Link href="/internal/supervisor-command-centre" className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
            <p className="text-xs font-bold uppercase tracking-[0.22em] text-sky-600">Daily cockpit 1</p>
            <h2 className="mt-2 text-2xl font-semibold tracking-tight">Supervisor Command Centre</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">Operational source of truth from order control to clean delivery and accounting handoff. Start here for blockers, owners and child action routing.</p>
            <div className="mt-4 text-sm font-bold text-sky-700">Open operational cockpit →</div>
          </Link>
          <Link href="/internal/accounting-command-centre" className="rounded-3xl border border-violet-200 bg-violet-50 p-5 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md">
            <p className="text-xs font-bold uppercase tracking-[0.22em] text-violet-600">Daily cockpit 2</p>
            <h2 className="mt-2 text-2xl font-semibold tracking-tight">Accounting Command Centre</h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">Single accounting/Sage cockpit for live-ready rows, frozen snapshots, revalidation, posting gates, mapping diagnostics and future batch posting.</p>
            <div className="mt-4 text-sm font-bold text-violet-700">Open accounting cockpit →</div>
          </Link>
        </section>

        <section className="rounded-3xl border border-sky-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.22em] text-sky-600">Start here for DVA/card statements</p>
              <h2 className="mt-2 text-2xl font-semibold tracking-tight">DVA/card statement workflow</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This is the supervisor route for statement uploads, OCR/commit, matching, allocation review, reversal, and later grouped pre-Sage review. Main company bank shipper payments branch separately after commit.
              </p>
            </div>
            <Link href="/internal/dva-statement-import" className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-sky-700">
              Start statement workflow →
            </Link>
          </div>

          <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-5">
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
              <h2 className="mt-2 text-2xl font-semibold tracking-tight">Shipping and accounting readiness workflow</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Use these links after logging in as staff/supervisor. The flow moves from shipping truth to customer invoice draft creation, then accounting handoff through the Accounting Command Centre.
              </p>
            </div>
            <Link href="/internal/accounting-command-centre" className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-emerald-800">
              Open Accounting Command Centre →
            </Link>
          </div>

          <div className="mt-5 grid gap-3 md:grid-cols-2 xl:grid-cols-5">
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
            Stable progressed subsets may move forward. Open children block final whole-order closure, not stable subset release. VAT is prepayment-first and sales-invoice based. Sage posting remains queued and idempotent. Shipper package batches are movement truth only; shipper invoices, export evidence and accounting readiness stay in separate supervisor/accounting lanes. The daily model is two command centres plus child task rooms.
          </p>
        </section>
      </div>
    </main>
  );
}
