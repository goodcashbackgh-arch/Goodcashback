import { createClient } from "@/utils/supabase/server";
import SettlementCustomerPatch from "./SettlementCustomerPatch";

type SettlementRow = {
  credit_added_to_account_gbp: number | string | null;
  potential_additional_credit_gbp: number | string | null;
};

type FundingRow = {
  confirmed_dva_funding_gbp: number | string | null;
};

type AudienceStatusRow = {
  customer_sales_state: string | null;
};

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

export default async function CustomerOrderOperationsLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ order_id: string }>;
}) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();
  const [{ data: settlementData }, { data: fundingData }, { data: audienceStatusData }] = await Promise.all([
    supabase.rpc("order_settlement_audience_v1", { p_order_id: orderId }).maybeSingle(),
    supabase.from("order_funding_position_vw").select("confirmed_dva_funding_gbp").eq("order_id", orderId).maybeSingle(),
    (supabase as any).rpc("order_audience_status_v1", { p_order_id: orderId }).maybeSingle(),
  ]);

  const settlement = settlementData as SettlementRow | null;
  const funding = fundingData as FundingRow | null;
  const audienceStatus = audienceStatusData as AudienceStatusRow | null;
  const creditAdded = Math.max(Number(settlement?.credit_added_to_account_gbp ?? 0), 0);
  const pendingCredit = Math.max(Number(settlement?.potential_additional_credit_gbp ?? 0), 0);
  const showCreditUpdate = creditAdded > 0.01 || pendingCredit > 0.01;
  const finalSaleValueConfirmed = audienceStatus?.customer_sales_state === "posted";
  const confirmedPaymentGbp = Math.max(Number(funding?.confirmed_dva_funding_gbp ?? 0), 0);

  return (
    <>
      <SettlementCustomerPatch
        finalSaleValueConfirmed={finalSaleValueConfirmed}
        confirmedPaymentGbp={confirmedPaymentGbp}
      />
      {showCreditUpdate ? (
        <div className="bg-slate-50 px-4 pt-4 xl:px-6">
          <section className="mx-auto rounded-3xl border border-cyan-100 bg-cyan-50/70 p-4 text-sm text-cyan-950 shadow-sm">
            <p className="font-black">Credit update for this order</p>
            <div className="mt-2 flex flex-wrap gap-x-6 gap-y-1 font-semibold">
              {creditAdded > 0.01 ? <span>Added to account: {money(creditAdded)}</span> : null}
              {pendingCredit > 0.01 ? <span>Pending final review: {money(pendingCredit)}</span> : null}
            </div>
            {pendingCredit > 0.01 ? <p className="mt-1 text-xs font-semibold text-cyan-800">Pending credit is not available until supervisor approval.</p> : null}
          </section>
        </div>
      ) : null}
      {children}
    </>
  );
}
