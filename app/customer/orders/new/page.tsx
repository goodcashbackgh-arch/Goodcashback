import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import OrderForm from "@/app/importer/orders/new/OrderForm";
import { createCustomerOrderAction } from "./actions";

type RetailerOption = { id: string; name: string };
type HubOption = { id: string; name: string; full_address?: string | null };
type ShipperRetailerRow = { retailer_id: string };

function shortId(id: string) {
  return id.slice(0, 8);
}

export default async function NewCustomerOrderPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return <main className="p-6">Please sign in.</main>;

  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  const { data: operatorImporter } = operator
    ? await supabase.from("operator_importers").select("importer_id").eq("operator_id", operator.id).is("revoked_at", null).limit(1).maybeSingle()
    : { data: null };
  const { data: importer } = operatorImporter?.importer_id
    ? await supabase.from("importers").select("shipper_id").eq("id", operatorImporter.importer_id).maybeSingle()
    : { data: null };

  const [{ data: shipperRetailerRows }, { data: hubs }, { data: shipper }] = await Promise.all([
    importer?.shipper_id
      ? supabase.from("shipper_retailers").select("retailer_id").eq("shipper_id", importer.shipper_id).eq("enabled", true).order("created_at")
      : Promise.resolve({ data: [] as ShipperRetailerRow[] }),
    importer?.shipper_id
      ? supabase.from("hubs").select("id, name, full_address").eq("shipper_id", importer.shipper_id).eq("active", true).order("created_at")
      : Promise.resolve({ data: [] as HubOption[] }),
    importer?.shipper_id
      ? supabase.from("shippers").select("name").eq("id", importer.shipper_id).maybeSingle()
      : Promise.resolve({ data: null as { name: string } | null }),
  ]);

  const retailerIds = ((shipperRetailerRows ?? []) as ShipperRetailerRow[]).map((row) => row.retailer_id).filter(Boolean);
  const { data: retailerNameRows } = retailerIds.length > 0
    ? await supabase.from("retailers").select("id, name").in("id", retailerIds)
    : { data: [] as RetailerOption[] };
  const retailerNameById = new Map((retailerNameRows ?? []).map((retailer) => [retailer.id, retailer.name]));
  const retailers = retailerIds.map((id) => ({ id, name: retailerNameById.get(id) ?? `Retailer ${shortId(id)}` }));
  const hubRows = (hubs ?? []) as HubOption[];
  const emptyMessages = [
    retailers.length === 0 ? "No retailers are visible for your account." : "",
    hubRows.length === 0 ? "No destination hubs are visible for your assigned shipper." : "",
  ].filter(Boolean);

  return (
    <main className="p-6 space-y-6">
      <Link href="/customer" className="text-sky-600">← Back</Link>
      <h1 className="text-2xl font-semibold">Create order</h1>
      <OrderForm retailers={retailers} shipperName={shipper?.name ?? "—"} assignedHub={hubRows[0] ?? null} emptyMessages={emptyMessages} action={createCustomerOrderAction} />
    </main>
  );
}
