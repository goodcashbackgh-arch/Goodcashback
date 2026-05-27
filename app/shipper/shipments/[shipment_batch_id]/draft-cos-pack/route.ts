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

function safeFile(value: string | null | undefined) {
  return (value || "draft-cos-eep-pack").replace(/[^a-z0-9-]+/gi, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "draft-cos-eep-pack";
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

function qty(value: number | string | null | undefined) {
  const parsed = n(value);
  return parsed % 1 === 0 ? String(Math.trunc(parsed)) : parsed.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
}

function headerCell(label: string, value: unknown, options?: { multiline?: boolean }) {
  return `
    <div class="field">
      <div class="field-label">${esc(label)}</div>
      <div class="field-value${options?.multiline ? " multiline" : ""}">${esc(display(value))}</div>
    </div>`;
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
  const issuedDate = new Date().toISOString().slice(0, 10);
  const boxes = display(first.final_package_confirmation || first.total_boxes);
  const completionStatus = first.completion_status || "completion_fields_draft";

  const itemRows = rows.map((row) => `
    <tr>
      <td>${esc(display(row.sales_invoice_ref, "Pending sales invoice ref"))}</td>
      <td class="mono">${esc(traceSku(row))}</td>
      <td>${esc(display(row.item_description, "Assorted retail goods"))}</td>
      <td class="center">GBP</td>
      <td class="num">${esc(qty(row.qty_allocated))}</td>
      <td class="num">${esc(money(row.unit_export_value_gbp))}</td>
      <td class="num">${esc(money(row.total_export_value_gbp))}</td>
      <td>${esc(display(row.package_box_ref, eepRef))}</td>
      <td>${esc(display(row.destination, "Ghana"))}</td>
    </tr>`).join("");

  const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${esc(eepRef)} Draft COS + EEP</title>
  <style>
    @page { size: A4 portrait; margin: 14mm; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #f3f4f6; color: #111827; font-family: "Times New Roman", Times, serif; }
    .toolbar { position: sticky; top: 0; z-index: 10; display: flex; gap: 10px; align-items: center; justify-content: center; padding: 10px; background: #111827; color: white; font-family: Arial, Helvetica, sans-serif; }
    .toolbar button { border: 0; border-radius: 10px; padding: 9px 14px; font-weight: 700; cursor: pointer; }
    .sheet { width: 210mm; min-height: 297mm; margin: 18px auto; padding: 11mm 13mm; background: white; box-shadow: 0 12px 40px rgba(15, 23, 42, 0.18); page-break-after: always; }
    .sheet:last-child { page-break-after: auto; }
    .draft-banner { border: 1px solid #111827; padding: 6px; margin-bottom: 10px; text-align: center; font-family: Arial, Helvetica, sans-serif; font-size: 11px; font-weight: 800; letter-spacing: 0.12em; text-transform: uppercase; }
    h1 { margin: 0 0 10px; text-align: center; font-size: 24px; text-decoration: underline; }
    h2 { margin: 12px 0 8px; font-size: 15px; font-family: Arial, Helvetica, sans-serif; }
    .certificate-grid { display: grid; grid-template-columns: 1.15fr 1fr; border: 1px solid #6b7280; }
    .left-panel, .right-panel { min-height: 90mm; }
    .right-panel { border-left: 1px solid #6b7280; }
    .field { border-bottom: 1px solid #9ca3af; min-height: 20mm; padding: 6px 8px; }
    .right-panel .field { min-height: 16mm; }
    .field.small { min-height: 13mm; }
    .field-label { font-size: 10px; font-weight: 700; text-transform: uppercase; color: #374151; letter-spacing: 0.05em; }
    .field-value { margin-top: 4px; font-size: 13px; font-weight: 700; line-height: 1.25; white-space: pre-wrap; }
    .field-value.multiline { min-height: 38px; }
    .logo-box { min-height: 38mm; display: flex; align-items: center; justify-content: center; border-bottom: 1px solid #9ca3af; font-size: 32px; font-weight: 700; color: #374151; letter-spacing: 0.05em; }
    .mini-grid { display: grid; grid-template-columns: 1fr 1fr; }
    .mini-grid .field:nth-child(odd) { border-right: 1px solid #9ca3af; }
    .goods-note { margin-top: 12px; border: 1px solid #6b7280; padding: 9px; font-size: 13px; font-weight: 700; line-height: 1.35; }
    .signature-area { margin-top: 22px; display: grid; grid-template-columns: 1fr 1fr; gap: 22px; align-items: end; }
    .sig-line { border-top: 1px solid #111827; padding-top: 6px; min-height: 26px; font-size: 12px; }
    .company-stamp { margin-top: 14px; text-align: center; font-size: 22px; font-weight: 700; letter-spacing: 0.08em; color: #374151; }
    .small-text { font-size: 11px; color: #374151; line-height: 1.35; }
    .summary-row { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-bottom: 10px; font-family: Arial, Helvetica, sans-serif; }
    .summary-card { border: 1px solid #d1d5db; padding: 8px; border-radius: 8px; }
    .summary-card span { display: block; font-size: 9px; text-transform: uppercase; color: #6b7280; letter-spacing: .06em; }
    .summary-card strong { display: block; margin-top: 4px; font-size: 13px; }
    table { width: 100%; border-collapse: collapse; font-family: Arial, Helvetica, sans-serif; font-size: 10px; }
    th, td { border: 1px solid #9ca3af; padding: 5px 6px; vertical-align: top; }
    th { background: #f3f4f6; font-size: 9px; text-transform: uppercase; letter-spacing: 0.04em; }
    .num { text-align: right; white-space: nowrap; }
    .center { text-align: center; }
    .mono { font-family: "Courier New", Courier, monospace; font-weight: 700; }
    .totals { display: flex; justify-content: flex-end; gap: 18px; margin-top: 10px; font-family: Arial, Helvetica, sans-serif; font-size: 12px; font-weight: 800; }
    .footer-note { margin-top: 16px; font-size: 11px; line-height: 1.35; color: #374151; }
    @media print {
      body { background: white; }
      .toolbar { display: none; }
      .sheet { margin: 0; box-shadow: none; width: auto; min-height: auto; }
    }
  </style>
</head>
<body>
  <div class="toolbar">
    <button onclick="window.print()">Print / Save as PDF</button>
    <span>Draft COS + EEP Pack · ${esc(eepRef)}</span>
  </div>

  <section class="sheet">
    <div class="draft-banner">Draft only — shipper to place on letterhead/template, sign/stamp, and upload final evidence</div>
    <h1>Certificate Of Shipment</h1>
    <div class="certificate-grid">
      <div class="left-panel">
        ${headerCell("Supplier / Exporter", "GOODCASHBACK / TENANT EXPORTER\nDummy UK address\nUNITED KINGDOM\nVAT REGISTRATION No.: Dummy VAT number", { multiline: true })}
        ${headerCell("Freight Forwarder", display(first.shipper_name, "Shipper to complete"), { multiline: true })}
        ${headerCell("Consignee", "GHANA JURISDICTION HUB / TENANT DESTINATION HUB\nDummy Ghana address", { multiline: true })}
        <div class="mini-grid">
          ${headerCell("Container / seal no", `${display(first.container_number)} / ${display(first.seal_number)}`)}
          ${headerCell("Place of Receipt", display(first.place_of_delivery, "Ghana / destination hub"))}
          ${headerCell("Vessel", display(first.vessel_voyage))}
          ${headerCell("Port of Loading", display(first.port_of_loading))}
          ${headerCell("Port of Discharge", display(first.port_of_discharge))}
          ${headerCell("Place of Delivery", display(first.place_of_delivery))}
          ${headerCell("Date of Shipment", display(first.export_shipment_date))}
          ${headerCell("Shipment Terms", "Consolidated shipment")}
        </div>
      </div>
      <div class="right-panel">
        <div class="mini-grid">
          ${headerCell("Date Issued", issuedDate)}
          ${headerCell("Customer Reference", display(first.booking_ref, shipmentBatchId))}
        </div>
        ${headerCell("Bill of lading", display(first.mbl_bol_sea_waybill_ref))}
        <div class="logo-box">${esc(display(first.shipper_name, "SHIPPER"))}</div>
        ${headerCell("Internal document / EEP ref", eepRef)}
        ${headerCell("Boxes / Packages", boxes)}
        ${headerCell("Completion status", completionStatus)}
      </div>
    </div>

    <div class="goods-note">
      GOODS SHIPPED AS PER OUR INTERNAL DOCUMENT NO.: ${esc(eepRef)}<br />
      DATE: ${esc(display(first.export_shipment_date, issuedDate))}<br />
      BOXES: ${esc(boxes)}<br /><br />
      Description of goods: Assorted retail consumer goods as per attached EEP / packing list ${esc(eepRef)}.
    </div>

    <p class="small-text">
      We hereby certify that the above-mentioned goods covered by the invoice/reference number(s) and detailed in the attached EEP / packing list were shipped as part of a consolidated shipment.
    </p>

    <div class="signature-area">
      <div class="sig-line">Authorised name: ${esc(display(first.authorised_name))}</div>
      <div class="sig-line">Signature / stamp / date</div>
    </div>
    <div class="company-stamp">${esc(display(first.shipper_name, "SHIPPER"))}</div>
  </section>

  <section class="sheet">
    <h1>Export Evidence Pack / Packing List</h1>
    <div class="summary-row">
      <div class="summary-card"><span>EEP ref</span><strong>${esc(eepRef)}</strong></div>
      <div class="summary-card"><span>Shipment / booking ref</span><strong>${esc(display(first.booking_ref, shipmentBatchId))}</strong></div>
      <div class="summary-card"><span>Package / box</span><strong>${esc(display(first.package_box_ref, eepRef))}</strong></div>
      <div class="summary-card"><span>Destination</span><strong>${esc(display(first.destination, "Ghana"))}</strong></div>
    </div>
    <table>
      <thead>
        <tr>
          <th>Sales invoice ref</th>
          <th>Trace SKU</th>
          <th>Description</th>
          <th>Currency</th>
          <th class="num">Qty</th>
          <th class="num">Unit export value</th>
          <th class="num">Total export value</th>
          <th>Package / box</th>
          <th>Destination</th>
        </tr>
      </thead>
      <tbody>${itemRows}</tbody>
    </table>
    <div class="totals">
      <span>Total Qty: ${esc(qty(totalQty))}</span>
      <span>Total Value: GBP ${esc(money(totalValue))}</span>
    </div>
    <div class="footer-note">
      This EEP / packing list is the detailed goods schedule referenced by the Certificate of Shipment. It is intended to support the shipment/export evidence pack and avoid placing every detailed line directly on the short certificate page.
    </div>
  </section>
</body>
</html>`;

  return new NextResponse(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Disposition": `inline; filename="${safeFile(eepRef)}-draft-cos-eep-pack.html"`,
      "Cache-Control": "no-store",
    },
  });
}