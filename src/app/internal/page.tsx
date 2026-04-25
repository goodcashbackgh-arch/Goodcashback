import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type QueueCard = {
  title: string;
  href: string;
  description: string;
  countLabel: string;
  count: number | null;
  proof: string;
};

async function safeCount(
  supabase: Awaited<ReturnType<typeof createClient>>,
  relation: string
): Promise<number | null> {
  const { count, error } = await supabase
    .from(relation)
    .select("*", { count: "exact", head: true });

  if (error) return null;
  return count ?? 0;
}

export default async function InternalPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) {
    redirect("/auth/check");
  }

  const [
    fundingCount,
    invoiceCount,
    exceptionCount,
    shippingCount,
    accountingCount,
    escalationCount,
  ] = await Promise.all([
    safeCount(supabase, "order_funding_position_vw"),
    safeCount(supabase, "supplier_invoices"),
    safeCount(supabase, "disputes"),
    safeCount(supabase, "shipping_quotes"),
    safeCount(supabase, "sage_postings"),
    safeCount(supabase, "admin_escalation_queue_vw"),
  ]);

  const cards: QueueCard[] = [
    {
      title: "Funding queue",
      href: "/internal/funding",
      description:
        "DVA/card matching, funding gaps, overfunding credit, and importer credit application.",
      countLabel: "Funding positions",
      count: fundingCount,
      proof: "Day 2 funding regression passed",
    },
    {
      title: "Evidence / OCR queue",
      href: "/internal/evidence",
      description:
        "Invoice-first, tracking-first, OCR review, progressed subset, and protected OCR source lines.",
      countLabel: "Supplier invoices",
      count: invoiceCount,
      proof: "Day 3 evidence/OCR regression passed",
    },
    {
      title: "Child exceptions",
      href: "/internal/exceptions",
      description:
        "Refund approval gate, replacement child orders, and unresolved child exception control.",
      countLabel: "Disputes",
      count: exceptionCount,
      proof: "Day 4 exception regression passed",
    },
    {
      title: "Shipping handoff",
      href: "/internal/shipping",
      description:
        "Confirmed progressed subset only, no draft quote action, no overscoped shipment value.",
      countLabel: "Shipping quotes",
      count: shippingCount,
      proof: "Day 5 shipping regression passed",
    },
    {
      title: "Accounting / VAT",
      href: "/internal/accounting-vat",
      description:
        "Sage queue, released sales invoices, VAT prepayment timing, Box 1 breach and Box 6 reporting.",
      countLabel: "Sage postings",
      count: accountingCount,
      proof: "Day 6/8 accounting and VAT regression passed",
    },
    {
      title: "Escalations",
      href: "/internal/escalations",
      description:
        "Admin governance queue for policy, funding, VAT, exception, and release anomalies.",
      countLabel: "Escalation rows",
      count: escalationCount,
      proof: "Day 7/9 role boundary and hardening regression passed",
    },
  ];

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
                Thin working shell for the proven Day 2–9 backend. Use this to
                move through funding, evidence, exceptions, shipping handoff,
                accounting/VAT, and escalation queues without changing backend
                SQL.
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
              <div className="flex items-start justify-between gap-4">
                <div>
                  <h2 className="text-lg font-semibold text-slate-950">
                    {card.title}
                  </h2>
                  <p className="mt-2 text-sm leading-6 text-slate-600">
                    {card.description}
                  </p>
                </div>
                <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-600">
                  {card.count === null ? "—" : card.count}
                </span>
              </div>
              <div className="mt-5 flex flex-col gap-2 text-xs text-slate-500">
                <span>{card.countLabel}</span>
                <span className="font-medium text-slate-700">{card.proof}</span>
              </div>
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
            and idempotent. Shipper only acts on confirmed progressed shipment
            scope.
          </p>
        </section>
      </div>
    </main>
  );
}
