import Link from "next/link";

type Lane = {
  title: string;
  owner: string;
  visibleTo: string;
  builtState: string;
  purpose: string;
  statuses: string[];
  blockers: string[];
};

const lanes: Lane[] = [
  {
    title: "Funding",
    owner: "Supervisor / admin",
    visibleTo: "Supervisor, admin, limited operator/importer headline",
    builtState: "Partly built",
    purpose: "Confirms importer/customer money received against the order funding threshold. Separate from card/DVA supplier charge reconciliation.",
    statuses: ["not_started", "part_funded", "funded", "overfunded_credit_created", "funding_exception"],
    blockers: ["Funding threshold not met", "Unapplied importer credit", "Overfunding not classified"],
  },
  {
    title: "Invoice / OCR / reconciliation",
    owner: "Operator first, supervisor for review/coding",
    visibleTo: "Operator, supervisor, admin",
    builtState: "Mostly built",
    purpose: "Tracks supplier invoice upload, OCR/header review, line reconciliation, progressed lines and supplier invoice readiness.",
    statuses: ["invoice_missing", "ocr_pending", "ocr_review_needed", "reconciliation_needed", "part_progressed", "fully_progressed", "exception_split", "supplier_invoice_ready_for_review"],
    blockers: ["Invoice missing", "OCR mismatch", "Unprogressed lines", "Duplicate blocked invoice", "Coding/current approval missing"],
  },
  {
    title: "Commercial exception: refund/replacement",
    owner: "Operator logs retailer evidence; supervisor accepts outcomes",
    visibleTo: "Operator, supervisor, admin; importer only simplified headline if relevant",
    builtState: "Partly built; status integrity now being hardened",
    purpose: "Handles retailer-side commercial truth: not charged, refund, replacement, refund + repurchase and replacement child order creation.",
    statuses: ["raised", "under_review", "approved_refund", "awaiting_refund_credit", "approved_replacement", "replaced", "refunded", "closed"],
    blockers: ["Retailer conversation not logged", "Header/line status mismatch", "Refund accepted but no IN statement match", "Replacement accepted but child order missing"],
  },
  {
    title: "DVA/card financial reconciliation",
    owner: "Supervisor / admin",
    visibleTo: "Supervisor, admin",
    builtState: "Partly built",
    purpose: "Explains bank/card statement lines against supplier charges, refunds, fees, FX/card residuals and exception holds.",
    statuses: ["statement_missing", "statement_imported", "unmatched", "part_allocated", "balanced", "refund_match_needed", "supplier_charge_match_needed", "fx_fee_classification_needed", "held"],
    blockers: ["Statement line unmatched", "Line part allocated", "Refund expected but IN line missing", "Supplier invoice charge not matched", "Generic hold not resolved"],
  },
  {
    title: "Shipper intake / physical discrepancy",
    owner: "Shipper raises, supervisor triages, operator acts if commercial exception needed",
    visibleTo: "Shipper, supervisor, admin; operator only where query is pushed to them",
    builtState: "Not yet built",
    purpose: "Handles missing/damaged/wrong/not-received goods when the shipper receives or expects goods. This can reopen an order and trigger operator exception creation.",
    statuses: ["not_handed_to_shipper", "awaiting_shipper_receipt", "shipper_received_clean", "shipper_received_partial", "shipper_discrepancy_raised", "supervisor_reviewing_shipper_query", "operator_exception_required", "shipper_query_resolved", "shipper_liability_review"],
    blockers: ["Shipper receipt missing", "Shipper discrepancy open", "Supervisor has not triaged query", "Operator has not created required refund/replacement exception"],
  },
  {
    title: "Shipping quote / shipment",
    owner: "Shipper with supervisor oversight",
    visibleTo: "Shipper, supervisor, importer/operator simplified headline",
    builtState: "Not yet built",
    purpose: "Tracks quote, approval, shipment readiness, in-transit movement and arrival. Separate from export evidence review.",
    statuses: ["not_ready", "awaiting_shipping_quote", "quote_issued", "awaiting_importer_quote_approval", "quote_approved", "shipment_ready", "in_transit", "arrived_destination"],
    blockers: ["Quote missing", "Quote not approved", "Shipment not created", "Shipment not dispatched", "Arrival not confirmed"],
  },
  {
    title: "Export evidence / VAT document pack",
    owner: "Supervisor/admin drafts and reviews; shipper uploads final version",
    visibleTo: "Supervisor, admin, shipper; importer/operator only high-level export complete/pending signal",
    builtState: "Not yet built",
    purpose: "Controls draft and final export documents that can cover multiple sales invoices, multiple orders and one consolidated shipment/export batch.",
    statuses: ["not_required_yet", "draft_export_doc_needed", "draft_export_doc_uploaded", "sent_to_shipper_for_finalisation", "final_export_doc_requested", "final_export_doc_uploaded", "export_doc_under_review", "export_doc_accepted", "export_doc_rejected_query_shipper", "export_evidence_complete", "export_evidence_overdue"],
    blockers: ["Draft export doc missing", "Final shipper export doc missing", "Export doc rejected", "Sales invoice/export pack link missing", "Evidence deadline at risk"],
  },
  {
    title: "Destination delivery / importer receipt",
    owner: "Shipper for delivery; importer/customer confirms receipt; supervisor resolves disputes",
    visibleTo: "Shipper, supervisor, importer/operator headline",
    builtState: "Not yet built",
    purpose: "Confirms local delivery and catches non-delivery, damaged/missing delivery or importer receipt disputes.",
    statuses: ["awaiting_destination_delivery", "delivered_to_importer", "importer_confirmation_pending", "delivery_failed", "delivery_dispute_open", "delivery_resolved"],
    blockers: ["Delivery not completed", "Importer confirmation missing", "Delivery dispute open", "Supervisor resolution missing"],
  },
  {
    title: "Accounting / Sage / VAT readiness",
    owner: "Supervisor / admin / accounting",
    visibleTo: "Supervisor, admin",
    builtState: "Not yet built as final readiness; components partly built",
    purpose: "Combines invoice approval, DVA/card truth, exception outcomes, export evidence, VAT timing and Sage payload checks.",
    statuses: ["not_ready", "supplier_invoice_ready", "sales_invoice_draft_ready", "sage_payload_ready", "posted_to_sage", "vat_evidence_pending", "vat_ready", "closed"],
    blockers: ["Open exception", "Unmatched statement line", "Export evidence missing", "Supplier invoice not approved", "Payload not idempotency-safe"],
  },
];

const roleViews = [
  {
    role: "Operator / importer worker",
    sees: "Their next action only: upload invoice/tracking, reconcile invoice lines, respond to supervisor query, create retailer exception, log retailer replies.",
  },
  {
    role: "Supervisor",
    sees: "Every lane, every blocker, status contradictions, DVA/card truth, exception gates, shipper queries, export evidence and accounting readiness.",
  },
  {
    role: "Shipper",
    sees: "Goods expected/received, discrepancies, quote/shipment, final export document upload, delivery status. Not retailer refund internals unless a query is assigned back.",
  },
  {
    role: "Admin",
    sees: "Full status spine, overrides, audit, accounting/VAT, export evidence and integrity warnings.",
  },
];

function pill(value: string) {
  return <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700 ring-1 ring-slate-200">{value.replaceAll("_", " ")}</span>;
}

export default function StatusLaneMapPage() {
  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal/status-control" className="text-sm font-semibold text-sky-600">← Back to status control</Link>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.25em] text-sky-600">Status spine lane map</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight sm:text-4xl">Read-only lane ownership map</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600 sm:text-base">
            This page protects the build from status drift. It shows the required status lanes, who owns them, who should see them, what is already built and which blockers must prevent order closure, Sage readiness or VAT evidence completion.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <Link href="/internal/status-control" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Live status control</Link>
            <Link href="/internal/dva-reconciliation/review-pack" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">DVA review pack</Link>
            <Link href="/internal/dva-reconciliation/exception-actions" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">Exception actions</Link>
          </div>
        </section>

        <section className="grid gap-3 md:grid-cols-4">
          {roleViews.map((role) => (
            <div key={role.role} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <p className="text-sm font-bold text-slate-950">{role.role}</p>
              <p className="mt-2 text-sm leading-6 text-slate-600">{role.sees}</p>
            </div>
          ))}
        </section>

        <section className="grid gap-4">
          {lanes.map((lane, index) => (
            <article key={lane.title} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
              <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-start">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="inline-flex h-8 min-w-8 items-center justify-center rounded-full bg-sky-50 px-2 text-sm font-extrabold text-sky-700 ring-1 ring-sky-200">{index + 1}</span>
                    <h2 className="text-xl font-extrabold text-slate-950">{lane.title}</h2>
                    <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">{lane.builtState}</span>
                  </div>
                  <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">{lane.purpose}</p>
                  <div className="mt-4 flex flex-wrap gap-2">{lane.statuses.map((status) => pill(status))}</div>
                </div>

                <aside className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
                  <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Owner</p>
                  <p className="mt-1 text-sm font-bold text-slate-950">{lane.owner}</p>
                  <p className="mt-4 text-xs font-bold uppercase tracking-wide text-slate-500">Visible to</p>
                  <p className="mt-1 text-sm leading-5 text-slate-700">{lane.visibleTo}</p>
                </aside>
              </div>

              <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4">
                <p className="text-sm font-bold text-amber-950">Blockers that must stop closure/readiness</p>
                <ul className="mt-2 grid gap-1 text-sm leading-6 text-amber-900 sm:grid-cols-2">
                  {lane.blockers.map((blocker) => (
                    <li key={blocker}>• {blocker}</li>
                  ))}
                </ul>
              </div>
            </article>
          ))}
        </section>
      </div>
    </main>
  );
}
