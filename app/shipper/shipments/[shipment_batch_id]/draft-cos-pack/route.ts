import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type PackRow = {
  booking_ref: string | null;
  eep_ref: string | null;
  shipper_name: string | null;
  customer_name: string | null;
  package_box_ref: string | null;
  total_boxes: number | string | null;
  mbl_bol_sea_waybill_ref: string | null;
  container_number: string | null;
  seal_number: string | null;
  vessel_voyage: string | null;
  port_of_loading: string | null;
  port_of_discharge: string | null;
  place_of_delivery: string | null;
  export_shipment_date: string | null;
  final_package_confirmation: string | null;
  authorised_name: string | null;
  completion_status: string | null;
  order_ref: string | null;
  sales_invoice_ref: string | null;
  sage_account_ref: string | null;
  supplier_invoice_ref: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  unit_export_value_gbp: number | string | null;
  total_export_value_gbp: number | string | null;
  destination: string | null;
};

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined) {
  return n(value).toFixed(2);
}

function q(value: unknown) {
  const text = String(value ?? "").replaceAll('"', '""');
  return `"${text}"`;
}

function safeFile(value: string | null | undefined) {
  return (value || "draft-cos-eep-pack").replace(/[^a-z0-9-]+/gi, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "draft-cos-eep-pack";
}

function last3(value: string | null | undefined) {
  const compact = (value ?? "").replace(/[^a-z0-9]/gi, "");
  if (!compact) return "REF";
  return compact.length <= 3 ? compact : compact.slice(-3);
}

function traceSku(row: PackRow) {
  return `${last3(row.order_ref)}/${last3(row.supplier_invoice_ref)}`;
}

export async function GET(_request: Request, { params }: { params: Promise<{ shipment_batch_id: string }> }) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Unauthenticated", { status: 401 });

  const { data, error } = await (supabase as any).rpc("shipper_export_evidence_pack_preview_v1", {
    p_shipment_batch_id: shipmentBatchId,
  });

  if (error) {
    return new NextResponse(`Unable to generate draft COS / EEP pack: ${error.message}`, { status: 400 });
  }

  const rows = (data ?? []) as PackRow[];
  if (rows.length === 0) return new NextResponse("No EEP lines found for this shipment batch.", { status: 404 });

  const first = rows[0];
  const eepRef = first.eep_ref || `EEP-${safeFile(first.booking_ref || shipmentBatchId)}`;
  const totalQty = rows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const totalValue = rows.reduce((sum, row) => sum + n(row.total_export_value_gbp), 0);

  const lines: string[] = [];
  lines.push("DRAFT CERTIFICATE OF SHIPMENT / EXPORT EVIDENCE PACK");
  lines.push(`Status,${q(first.completion_status || "completion_fields_draft")}`);
  lines.push(`EEP Ref,${q(eepRef)}`);
  lines.push(`Shipment / Booking Ref,${q(first.booking_ref || shipmentBatchId)}`);
  lines.push(`Freight Forwarder / Packer,${q(first.shipper_name || "")}`);
  lines.push(`Consignee,${q("Ghana jurisdiction hub / tenant destination hub")}`);
  lines.push(`Goods Description,${q(`Assorted retail consumer goods as per attached Export Evidence Pack / Packing List Ref: ${eepRef}`)}`);
  lines.push(`MBL / BOL / Sea Waybill,${q(first.mbl_bol_sea_waybill_ref)}`);
  lines.push(`Container Number,${q(first.container_number)}`);
  lines.push(`Seal Number,${q(first.seal_number)}`);
  lines.push(`Vessel / Voyage,${q(first.vessel_voyage)}`);
  lines.push(`Port of Loading,${q(first.port_of_loading)}`);
  lines.push(`Port of Discharge,${q(first.port_of_discharge)}`);
  lines.push(`Place of Delivery,${q(first.place_of_delivery)}`);
  lines.push(`Export / Shipment Date,${q(first.export_shipment_date)}`);
  lines.push(`Final Package Confirmation,${q(first.final_package_confirmation || first.total_boxes)}`);
  lines.push(`Authorised Name,${q(first.authorised_name)}`);
  lines.push("");
  lines.push("EEP / PACKING LIST");
  lines.push([
    "Customer",
    "Sage A/C Ref",
    "Sales Invoice Ref",
    "Trace SKU",
    "Description",
    "Qty",
    "Unit Export Value GBP",
    "Total Export Value GBP",
    "Package / Box",
    "Destination",
  ].map(q).join(","));

  for (const row of rows) {
    lines.push([
      row.customer_name,
      row.sage_account_ref || "Pending Sage A/C ref",
      row.sales_invoice_ref || "Pending sales invoice ref",
      traceSku(row),
      row.item_description,
      n(row.qty_allocated).toString(),
      money(row.unit_export_value_gbp),
      money(row.total_export_value_gbp),
      row.package_box_ref,
      row.destination || "Ghana",
    ].map(q).join(","));
  }

  lines.push("");
  lines.push(`Total Qty,${q(totalQty)}`);
  lines.push(`Total Value GBP,${q(money(totalValue))}`);
  lines.push("");
  lines.push(q(`We certify that the goods listed in Export Evidence Pack / Packing List Ref: ${eepRef} were packed and shipped as part of this consolidated shipment.`));

  return new NextResponse(lines.join("\n"), {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${safeFile(eepRef)}-draft-cos-eep-pack.csv"`,
      "Cache-Control": "no-store",
    },
  });
}
