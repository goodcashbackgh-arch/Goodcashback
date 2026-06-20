import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

export const dynamic = "force-dynamic";

export async function GET(_request: Request, { params }: { params: Promise<{ groupage_movement_id: string }> }) {
  const { groupage_movement_id: groupageMovementId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Unauthenticated", { status: 401 });

  const { data, error } = await (supabase as any).rpc("shipper_groupage_export_pack_preview_v1", {
    p_groupage_movement_id: groupageMovementId,
  });

  if (error) return new NextResponse(`Unable to generate Groupage supporting document list: ${error.message}`, { status: 400 });

  const rows = data ?? [];
  const body = [
    "Groupage supporting shipment documents",
    `Groupage movement id: ${groupageMovementId}`,
    "",
    ...rows.map((row: any) => `${row.booking_ref ?? "booking"}: ${row.sales_invoice_ref ?? "no sales invoice ref"}`),
  ].join("\n");

  return new NextResponse(body, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}
