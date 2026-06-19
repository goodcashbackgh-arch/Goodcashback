import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type PackRow = {
  groupage_movement_id: string;
  groupage_movement_ref: string | null;
  groupage_status: string | null;
  exporter_name: string | null;
  exporter_address: string | null;
  exporter_vat_number: string | null;
  shipper_name: string | null;
  movement_consignee_name: string | null;
  movement_consignee_address: string | null;
  notify_party_name: string | null;
  notify_party_address: string | null;
  weight_text: string | null;
  shipment_batch_id: string;
  booking_ref: string | null;
  importer_name: string | null;
  final_recipient_name: string | null;
  final_recipient_address: string | null;
  eep_ref: string | null;
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

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function safeFile(value: string | null | undefined) {
  return (value || "groupage-export-pack").replace(/[^a-z0-9-]+/gi, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "groupage-export-pack";
}

function esc(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function display(value: unknown, fallback = "—") {
  const raw = String(value ?? "").trim();
  return raw.length > 0 ? raw : fallback;
}

function last3(value: string | null | undefined) {
  const compact = (value ?? "").replace(/[^a-z0-9]/gi, "");
  if (!compact) return "REF";
  return compact.length <= 3 ? compact : compact.slice(-3);
}

function traceSku(row: PackRow) {
  return `${last3(row.order_ref)}/${last3(row.supplier_invoice_ref)}`;
}

function headerCell(label: string, value: unknown, options?: { multiline?: boolean }) {
  return `<div class="field"><div class="field-label">${esc(label)}</div><div class="field-value${options?.multiline ? " multiline" : ""}">${esc(display(value))}</div></div>`;
}

function uniqueRows(rows: PackRow[], key: keyof PackRow) {
  return Array.from(new Set(rows.map((row) => String(row[key] ?? "").trim()).filter(Boolean)));
}

export async function GET(_request: Request, { params }: { params: Promise<{ groupage_movement_id: string }> }) {
  const { groupage_movement_id: groupageMovementId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Unauthenticated", { status: 401 });

  const { data, error } = await (supabase as any).rpc("shipper_groupage_export_pack_preview_v1", {
    p_groupage_movement_id: groupageMovementId,
  });

  if (error) return new NextResponse(`Unable to generate Groupage Export Pack: ${error.message}`, { status: 400 });

  const rows = (data ?? []) as PackRow[];
  if (rows.length === 0) return new NextResponse("No EEP lines found for this Groupage Movement.", { status: 404 });

  const first = rows[0];
  const blockers = [
    !String(first.exporter_name ?? "").trim() ? "Exporter profile is missing." : null,
    !String(first.movement_consignee_name ?? "").trim() ? "Movement consignee is missing." : null,
    !String(first.mbl_bol_sea_waybill_ref ?? "").trim() ? "MBOL / BOL / sea waybill is missing." : null,
    !String(first.container_number ?? "").trim() ? "Container number is missing." : null,
    !String(first.seal_number ?? "").trim() ? "Seal number is missing." : null,
    !String(first.vessel_voyage ?? "").trim() ? "Vessel / voyage is missing." : null,
    !String(first.port_of_loading ?? "").trim() ? "Port of loading is missing." : null,
    !String(first.port_of_discharge ?? "").trim() ? "Port of discharge is missing." : null,
    !String(first.place_of_delivery ?? "").trim() ? "Place of delivery is missing." : null,
    !String(first.export_shipment_date ?? "").trim() ? "Export shipment date is missing." : null,
    rows.some((row) => !String(row.sales_invoice_ref ?? "").trim()) ? "One or more rows are missing a customer sales invoice reference." : null,
    rows.some((row) => !String(row.final_recipient_name ?? "").trim()) ? "One or more rows are missing a final recipient." : null,
  ].filter(Boolean) as string[];

  if (blockers.length > 0) {
    return new NextResponse(`Groupage Export Pack blocked:\n- ${blockers.join("\n- ")}`, { status: 409 });
  }

  const movementRef = first.groupage_movement_ref || `GM-${safeFile(groupageMovementId)}`;
  const issuedDate = new Date().toISOString().slice(0, 10);
  const totalQty = rows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const totalValue = rows.reduce((sum, row) => sum + n(row.total_export_value_gbp), 0);
  const totalBoxes = new Set(rows.map((row) => row.package_box_ref || row.booking_ref || row.eep_ref).filter(Boolean)).size;
  const bookingRefs = uniqueRows(rows, "booking_ref");

  const sectionRows = bookingRefs.map((bookingRef) => {
    const batchRows = rows.filter((row) => String(row.booking_ref ?? "") === bookingRef);
    const sample = batchRows[0];
    return `<tr><td>${esc(display(sample.booking_ref))}</td><td>${esc(display(sample.importer_name))}</td><td>${esc(display(sample.final_recipient_name))}</td><td>${esc(display(sample.final_recipient_address))}</td><td class="num">${esc(qty(batchRows.reduce((sum, row) => sum + n(row.qty_allocated), 0)))}</td><td class="num">${esc(money(batchRows.reduce((sum, row) => sum + n(row.total_export_value_gbp), 0)))}</td></tr>`;
  }).join("");

  const itemRows = rows.map((row) => `<tr><td>${esc(display(row.booking_ref))}</td><td>${esc(display(row.importer_name))}</td><td>${esc(display(row.sales_invoice_ref))}</td><td class="mono">${esc(traceSku(row))}</td><td>${esc(display(row.item_description, "Retail goods as invoiced"))}</td><td class="num">${esc(qty(row.qty_allocated))}</td><td class="num">${esc(money(row.unit_export_value_gbp))}</td><td class="num">${esc(money(row.total_export_value_gbp))}</td><td>${esc(display(row.package_box_ref, row.eep_ref ?? row.booking_ref ?? movementRef))}</td><td>${esc(display(row.destination, "Destination per recipient schedule"))}</td></tr>`).join("");

  const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${esc(movementRef)} Groupage Export Pack</title>
  <style>
    @page { size: A4 portrait; margin: 14mm; }
    @page eep { size: A4 landscape; margin: 12mm; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #f3f4f6; color: #111827; font-family: "Times New Roman", Times, serif; }
    .toolbar { position: sticky; top: 0; z-index: 10; display: flex; gap: 10px; align-items: center; justify-content: center; padding: 10px; background: #111827; color: white; font-family: Arial, Helvetica, sans-serif; }
    .toolbar button { border: 0; border-radius: 10px; padding: 9px 14px; font-weight: 700; cursor: pointer; }
    .sheet { width: 210mm; min-height: 297mm; margin: 18px auto; padding: 11mm 13mm; background: white; box-shadow: 0 12px 40px rgba(15, 23, 42, 0.18); page-break-after: always; }
    .sheet:last-child { page-break-after: auto; }
    .eep-sheet { page: eep; width: 297mm; min-height: 210mm; }
    .draft-banner { border: 1px solid #111827; padding: 6px; margin-bottom: 10px; text-align: center; font-family: Arial, Helvetica, sans-serif; font-size: 11px; font-weight: 800; letter-spacing: 0.12em; text-transform: uppercase; }
    h1 { margin: 0 0 10px; text-align: center; font-size: 24px; text-decoration: underline; }
    h2 { margin: 0 0 8px; font-size: 17px; }
    .certificate-grid { display: grid; grid-template-columns: 1.15fr 1fr; border: 1px solid #6b7280; }
    .right-panel { border-left: 1px solid #6b7280; }
    .field { border-bottom: 1px solid #9ca3af; min-height: 18mm; padding: 6px 8px; }
    .field-label { font-size: 10px; font-weight: 700; text-transform: uppercase; color: #374151; letter-spacing: 0.05em; }
    .field-value { margin-top: 4px; font-size: 13px; font-weight: 700; line-height: 1.25; white-space: pre-wrap; }
    .field-value.multiline { min-height: 38px; }
    .logo-box { min-height: 32mm; display: flex; align-items: center; justify-content: center; border-bottom: 1px solid #9ca3af; font-size: 24px; font-weight: 700; color: #374151; text-align: center; }
    .mini-grid { display: grid; grid-template-columns: 1fr 1fr; }
    .mini-grid .field:nth-child(odd) { border-right: 1px solid #9ca3af; }
    .goods-note { margin-top: 12px; border: 1px solid #6b7280; padding: 9px; font-size: 13px; font-weight: 700; line-height: 1.35; }
    .signature-area { margin-top: 22px; display: grid; grid-template-columns: 1fr 1fr; gap: 22px; align-items: end; }
    .sig-line { border-top: 1px solid #111827; padding-top: 6px; min-height: 26px; font-size: 12px; }
    table { width: 100%; border-collapse: collapse; font-family: Arial, Helvetica, sans-serif; font-size: 9px; table-layout: fixed; }
    th, td { border: 1px solid #9ca3af; padding: 5px 5px; vertical-align: top; overflow-wrap: anywhere; }
    th { background: #f3f4f6; font-size: 8px; text-transform: uppercase; letter-spacing: 0.04em; }
    .num { text-align: right; white-space: nowrap; }
    .mono { font-family: "Courier New", Courier, monospace; font-weight: 700; }
    .totals { display: flex; justify-content: flex-end; gap: 18px; margin-top: 10px; font-family: Arial, Helvetica, sans-serif; font-size: 12px; font-weight: 800; }
    .footer-note { margin-top: 16px; font-size: 11px; line-height: 1.35; color: #374151; }
    @media print { body { background: white; } .toolbar { display: none; } .sheet { margin: 0; box-shadow: none; } .sheet:not(.eep-sheet), .eep-sheet { width: auto; min-height: auto; } }
  </style>
</head>
<body>
  <div class="toolbar"><button onclick="window.print()">Print / Save as PDF</button><span>Groupage Export Pack · ${esc(movementRef)}</span></div>
  <section class="sheet">
    <div class="draft-banner">Draft only — shipper to sign/stamp/authenticate and upload final evidence</div>
    <h1>Groupage Certificate Of Shipment</h1>
    <div class="certificate-grid">
      <div class="left-panel">
        ${headerCell("Supplier / Exporter", `${display(first.exporter_name)}\n${display(first.exporter_address)}\nVAT REGISTRATION No.: ${display(first.exporter_vat_number)}`, { multiline: true })}
        ${headerCell("Freight forwarder / packer", display(first.shipper_name), { multiline: true })}
        ${headerCell("Movement consignee / receiving party", `${display(first.movement_consignee_name)}\n${display(first.movement_consignee_address)}`, { multiline: true })}
        ${headerCell("Notify party", `${display(first.notify_party_name)}\n${display(first.notify_party_address)}`, { multiline: true })}
        <div class="mini-grid">${headerCell("Container / seal no", `${display(first.container_number)} / ${display(first.seal_number)}`)}${headerCell("Weight", display(first.weight_text, "Not separately recorded by issuing consolidator"))}${headerCell("Vessel", display(first.vessel_voyage))}${headerCell("Port of Loading", display(first.port_of_loading))}${headerCell("Port of Discharge", display(first.port_of_discharge))}${headerCell("Place of Delivery", display(first.place_of_delivery))}${headerCell("Date of Shipment", display(first.export_shipment_date))}${headerCell("Shipment Terms", "Consolidated/groupage shipment")}</div>
      </div>
      <div class="right-panel">
        <div class="mini-grid">${headerCell("Date Issued", issuedDate)}${headerCell("Groupage Ref", movementRef)}</div>
        ${headerCell("Bill of lading / sea waybill", display(first.mbl_bol_sea_waybill_ref))}
        <div class="logo-box">${esc(display(first.shipper_name, "SHIPPER"))}</div>
        ${headerCell("Included booking refs", bookingRefs.join(", "), { multiline: true })}${headerCell("Packages / sections", `${bookingRefs.length} booking refs / ${totalBoxes} package refs`)}${headerCell("Completion status", display(first.groupage_status))}
      </div>
    </div>
    <div class="goods-note">Goods shipped under this movement are the goods detailed in the attached booking/invoice schedule and EEP line annex. Each booking section preserves the original shipper booking reference and final recipient/importer details.</div>
    <div class="signature-area"><div class="sig-line">Authorised name: ${esc(display(first.authorised_name))}</div><div class="sig-line">Signature / stamp / date</div></div>
  </section>
  <section class="sheet eep-sheet">
    <h1>Groupage Booking / Recipient Schedule</h1>
    <table><thead><tr><th>Booking ref</th><th>Importer</th><th>Final recipient</th><th>Final recipient address</th><th class="num">Qty</th><th class="num">Value GBP</th></tr></thead><tbody>${sectionRows}</tbody></table>
    <div class="totals"><span>Total Qty: ${esc(qty(totalQty))}</span><span>Total Value: GBP ${esc(money(totalValue))}</span></div>
    <div class="footer-note">This schedule links the groupage movement to each original shipment batch booking reference. It does not replace the batch booking reference.</div>
  </section>
  <section class="sheet eep-sheet">
    <h1>Export Evidence Pack / Invoice Line Annex</h1>
    <table><thead><tr><th>Booking ref</th><th>Importer</th><th>Sales invoice ref</th><th>Trace SKU</th><th>Description</th><th class="num">Qty</th><th class="num">Unit value</th><th class="num">Total value</th><th>Package / box</th><th>Destination</th></tr></thead><tbody>${itemRows}</tbody></table>
    <div class="totals"><span>Total Qty: ${esc(qty(totalQty))}</span><span>Total Value: GBP ${esc(money(totalValue))}</span></div>
    <div class="footer-note">This line annex is generated from the existing batch export evidence pack preview logic and is the detailed goods schedule referenced by the groupage certificate.</div>
  </section>
</body>
</html>`;

  return new NextResponse(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Disposition": `inline; filename="${safeFile(movementRef)}-groupage-export-pack.html"`,
      "Cache-Control": "no-store",
    },
  });
}
