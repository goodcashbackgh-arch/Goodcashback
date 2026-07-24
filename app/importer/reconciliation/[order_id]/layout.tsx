import CompactInvoiceLinesPatch from "./CompactInvoiceLinesPatch";
import ConfirmedSurplusCreditPatch from "./ConfirmedSurplusCreditPatch";
import ExistingExceptionCases from "./ExistingExceptionCases";
import { createClient } from "@/utils/supabase/server";

type SettlementRow = {
  credit_added_to_account_gbp: number | string | null;
  other_settlement_adjustment_gbp: number | string | null;
  potential_additional_credit_gbp: number | string | null;
  resolution_status: string | null;
};

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
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
    .rpc("order_settlement_audience_v1", { p_order_id: orderId })
    .maybeSingle();

  const settlement = data as SettlementRow | null;
  const credit = Math.max(Number(settlement?.credit_added_to_account_gbp ?? 0), 0);
  const otherAdjustment = Math.max(Number(settlement?.other_settlement_adjustment_gbp ?? 0), 0);
  const pending = Math.max(Number(settlement?.potential_additional_credit_gbp ?? 0), 0);
  const totalDifference = credit + otherAdjustment + pending;
  const fullyResolved = settlement?.resolution_status === "fully_resolved" && pending <= 0.01;
  const overResolved = settlement?.resolution_status === "over_resolved_review";
  const showSettlement = totalDifference > 0.01;

  return (
    <>
      <CompactInvoiceLinesPatch />
      {fullyResolved ? <ConfirmedSurplusCreditPatch /> : null}
      {showSettlement ? (
        <div className="mx-auto max-w-7xl px-4 pt-4 sm:px-6 sm:pt-6">
          <section className={`rounded-3xl border p-4 text-sm shadow-sm ${overResolved ? "border-rose-200 bg-rose-50 text-rose-950" : fullyResolved ? "border-emerald-200 bg-emerald-50 text-emerald-950" : "border-amber-200 bg-amber-50 text-amber-950"}`}>
            <p className="font-black">
              {overResolved ? "Settlement classification needs review" : fullyResolved ? "Settlement difference fully accounted for" : "Settlement difference partially accounted for"}
            </p>
            <p className="mt-1 leading-6">
              Total difference {money(totalDifference)}. Credit added {money(credit)}. Other settlement adjustment {money(otherAdjustment)}. Pending supervisor review {money(pending)}.
            </p>
            <p className="mt-1 text-xs font-semibold opacity-80">
              No importer action is required. Invoice-line variance remains visible for audit.
            </p>
          </section>
        </div>
      ) : null}
      {children}
      <ExistingExceptionCases orderId={orderId} />
    </>
  );
}
