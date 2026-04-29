import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { createOrderAction } from "./actions";
import OrderForm from "./OrderForm";

export default async function NewOrderPage() {
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

  const [{ data: retailers }, { data: hubs }, { data: shipper }] = await Promise.all([
    supabase.from("retailers").select("id, name").order("name"),
    importer?.shipper_id
      ? supabase.from("hubs").select("id, name, city").eq("shipper_id", importer.shipper_id).eq("active", true).order("name")
      : Promise.resolve({ data: [] as { id: string; name: string; city: string | null }[] }),
    importer?.shipper_id
      ? supabase.from("shippers").select("name").eq("id", importer.shipper_id).maybeSingle()
      : Promise.resolve({ data: null as { name: string } | null }),
  ]);

  const hubRows = hubs ?? [];
  const assignedHub = hubRows[0] ?? null;

  const emptyMessages = [
    (retailers ?? []).length === 0 ? "No retailers are visible for your account." : "",
    (hubRows ?? []).length === 0 ? "No destination hubs are visible for your assigned shipper." : "",
  ].filter(Boolean);

  return <main className="p-6 space-y-6">
    <Link href="/importer" className="text-sky-600">← Back</Link>
    <h1 className="text-2xl font-semibold">Create order</h1>
    <OrderForm
      retailers={retailers ?? []}
      shipperName={shipper?.name ?? "—"}
      assignedHub={assignedHub}
      emptyMessages={emptyMessages}
      action={createOrderAction}
    />
  </main>;
}
