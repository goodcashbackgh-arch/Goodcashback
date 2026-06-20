import Link from "next/link";
import { redirect } from "next/navigation";
import { FloatingActionBar } from "@/app/_components/FloatingActionBar";
import { createClient } from "@/utils/supabase/server";

export default async function ShipperGroupageMovementLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ groupage_movement_id: string }>;
}) {
  const { groupage_movement_id: groupageMovementId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (user) {
    const { data: shipperUser } = await supabase
      .from("shipper_users")
      .select("id")
      .eq("auth_user_id", user.id)
      .eq("active", true)
      .maybeSingle();

    if (!shipperUser) {
      const { data: staff } = await supabase
        .from("staff")
        .select("id")
        .eq("auth_user_id", user.id)
        .eq("active", true)
        .maybeSingle();

      if (staff) redirect(`/internal/shipping-control/groupage-movements/${groupageMovementId}`);
    }
  }

  return (
    <>
      {children}
      <div className="h-32 print:hidden" aria-hidden="true" />
      <FloatingActionBar innerClassName="flex max-w-4xl flex-wrap items-center justify-center gap-3 rounded-2xl border border-indigo-200 bg-white/95 p-3 shadow-lg backdrop-blur">
        <Link
          href={`/shipper/groupage-movements/${groupageMovementId}/export-pack`}
          target="_blank"
          className="rounded-xl border border-indigo-300 bg-indigo-50 px-4 py-2 text-sm font-semibold text-indigo-900 hover:bg-indigo-100"
        >
          Download combined export pack
        </Link>
        <Link
          href={`/shipper/groupage-movements/${groupageMovementId}/sales-invoices-zip`}
          className="rounded-xl border border-sky-300 bg-sky-50 px-4 py-2 text-sm font-semibold text-sky-900 hover:bg-sky-100"
        >
          Download supporting shipment documents ZIP
        </Link>
        <span className="text-xs font-medium text-slate-600">
          Download the groupage pack, collect supporting shipment documents, then upload the signed export pack below.
        </span>
      </FloatingActionBar>
    </>
  );
}
