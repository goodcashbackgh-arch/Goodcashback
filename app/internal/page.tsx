import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type QueueCard = {
  title: string;
  href: string;
  description: string;
  proof: string;
};

const cards: QueueCard[] = [
  {
    title: "Funding queue",
    href: "/internal/funding",
    description: "DVA matching, funding gaps, overfunding credit, and importer credit application.",
    proof: "Day 2 regression passed",
  },
  {
    title: "Evidence / OCR queue",
    href: "/internal/evidence",
    description: "Invoice-first, tracking-first, OCR review, progressed subset, and source-line protection.",
    proof: "Day 3 regression passed",
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
    description: "Progressed shipment-ready scope, quote confirmation, booking, dispatch, and delivery evidence.",
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
                Thin working shell for the live-passed Day 2–9 backend. Use this
                to move through funding, evidence, adjustments, exceptions,
                shipping handoff, accounting/VAT, and escalation queues.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{staff.full_name}</div>
              <div>{staff.role_type}</div>
            </div>
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
                Open queue →
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
            and idempotent. Shipper only acts on confirmed progressed shipment scope.
          </p>
        </section>
      </div>
    </main>
  );
}
