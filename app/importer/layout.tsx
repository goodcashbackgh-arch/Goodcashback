import Link from "next/link";
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
  const [{ data }, { data: physicalData }] = user
    ? await Promise.all([
        supabase.rpc("order_settlement_audience_v1", { p_order_id: null }),
        (supabase as any).rpc("importer_physical_receipt_reviews_v1", { p_review_id: null }),
      ])
    : [{ data: [] }, { data: null }];
  const rows = (data ?? []) as SettlementRow[];
  const physicalCount = Number((physicalData as any)?.action_count ?? 0);

  return (
    <>
      <SettlementImporterSummary rows={rows} />
      <div className="px-4 pt-4 md:px-6">
        <div className="mx-auto flex max-w-7xl justify-end">
          <Link href="/importer/physical-receipts" className="inline-flex items-center gap-2 rounded-full border border-amber-200 bg-amber-50 px-4 py-2 text-sm font-semibold text-amber-900 shadow-sm">
            Physical Receipt Exceptions
            <span className="rounded-full bg-amber-900 px-2 py-0.5 text-xs text-white">{physicalCount}</span>
          </Link>
        </div>
      </div>
      {children}
      <div className="px-6 pb-8">
        <div className="mx-auto max-w-7xl">
          <ReplacementOrdersPanel />
        </div>
      </div>
    </>
  );
}
