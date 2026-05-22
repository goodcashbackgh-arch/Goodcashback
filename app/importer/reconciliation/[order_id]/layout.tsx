import CompactInvoiceLinesPatch from "./CompactInvoiceLinesPatch";
import { createClient } from "@/utils/supabase/server";

type SurplusEvidenceRow = {
  credit_created_gbp: number | string | null;
  evidence_surplus_gbp: number | string | null;
  evidence_status: string | null;
  evidence_basis: string | null;
  funding_total_gbp: number | string | null;
  evidence_value_gbp: number | string | null;
};

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function pretty(value: string | null | undefined) {
  return value ? value.replaceAll("_", " ") : "—";
}

export default async function ImporterReconciliationLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ order_id: string }>;
}) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();
  const { data } = await supabase
    .from("order_surplus_evidence_position_v2")
    .select("credit_created_gbp, evidence_surplus_gbp, evidence_status, evidence_basis, funding_total_gbp, evidence_value_gbp")
    .eq("order_id", orderId)
    .maybeSingle();

  const evidence = data as SurplusEvidenceRow | null;
  const creditCreated = Number(evidence?.credit_created_gbp ?? 0);
  const surplus = Number(evidence?.evidence_surplus_gbp ?? 0);
  const showConfirmedCredit = evidence?.evidence_status === "credit_created" && creditCreated > 0;

  return (
    <>
      <CompactInvoiceLinesPatch />
      {showConfirmedCredit ? (
        <div className="mx-auto max-w-7xl px-4 pt-4 sm:px-6 sm:pt-6">
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-950 shadow-sm">
            <p className="font-black">Variance explained by confirmed customer credit</p>
            <p className="mt-1 leading-6">
              This order has {money(creditCreated)} confirmed as customer credit from surplus evidence. Funding total {money(evidence?.funding_total_gbp)} less evidence value {money(evidence?.evidence_value_gbp)} created a surplus of {money(surplus)}. Evidence basis: {pretty(evidence?.evidence_basis)}.
            </p>
            <p className="mt-1 text-xs font-semibold text-emerald-800">
              Keep the invoice-line variance visible for audit, but treat it as accounted for when it matches this confirmed credit.
            </p>
          </section>
        </div>
      ) : null}
      {children}
    </>
  );
}