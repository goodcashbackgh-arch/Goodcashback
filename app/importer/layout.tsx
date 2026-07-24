import { createClient } from "@/utils/supabase/server";
import ReplacementOrdersPanel from "./ReplacementOrdersPanel";
import SettlementImporterSummary from "./SettlementImporterSummary";

type SettlementRow = {
  order_id: string;
  order_ref: string | null;
  credit_added_to_account_gbp: number | string | null;
  other_settlement_adjustment_gbp: number | string | null;
  potential_additional_credit_gbp: number | string | null;
  resolution_status: string | null;
};

export default async function ImporterLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data } = user
    ? await supabase.rpc("order_settlement_audience_v1", { p_order_id: null })
    : { data: [] };
  const rows = (data ?? []) as SettlementRow[];

  return (
    <>
      <SettlementImporterSummary rows={rows} />
      {children}
      <div className="px-6 pb-8">
        <div className="mx-auto max-w-7xl">
          <ReplacementOrdersPanel />
        </div>
      </div>
    </>
  );
}
