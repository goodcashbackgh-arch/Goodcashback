import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type PackRow = {
  booking_ref: string | null;
  eep_ref: string | null;
  customer_name: string | null;
  package_box_ref: string | null;
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

function safeName(value: string | null | undefined) {
  return (value || "sales-invoice")
    .replace(/[^a-z0-9._-]+/gi, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "sales-invoice";
}

function cleanDescription(value: string | null | undefined) {
  return display(value, "Assorted retail goods")
    .replace(/^export\s+sale\s*-\s*/i, "")
    .replace(/^export\s+sale\s+goods\s+charge\s*-\s*/i, "")
    .replace(/^supplementary\s+export\s+sale\s+shipping\s+charge\s*-\s*/i, "")
    .replace(/\s*-\s*ord[-\s_]*[a-z0-9-]+\s*$/i, "")
    .replace(/\s*-\s*ord[-\s_]*[a-z0-9-]+\s*-\s*booking\s+[a-z0-9-]+\s*$/i, "")
    .replace(/\s*-\s*booking\s+[a-z0-9-]+\s*$/i, "")
    .replace(/\s+/g, " ")
    .trim() || "Assorted retail goods";
}

const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i += 1) {
    let c = i;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[i] = c >>> 0;
  }
  return table;
})();

function crc32(buffer: Buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function u16(value: number) {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value & 0xffff, 0);
  return buffer;
}

function u32(value: number) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value >>> 0, 0);
  return buffer;
}

function zip(files: { name: string; content: string | Buffer }[]) {
  const localParts: Buffer[] = [];
  const centralParts: Buffer[] = [];
  let offset = 0;

  for (const file of files) {
    const name = Buffer.from(file.name, "utf8");
    const content = Buffer.isBuffer(file.content) ? file.content : Buffer.from(file.content, "utf8");
    const crc = crc32(content);

    const localHeader = Buffer.concat([
      u32(0x04034b50), u16(20), u16(0), u16(0), u16(0), u16(0),
      u32(crc), u32(content.length), u32(content.length), u16(name.length), u16(0), name,
    ]);
    localParts.push(localHeader, content);

    const centralHeader = Buffer.concat([
      u32(0x02014b50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0),
      u32(crc), u32(content.length), u32(content.length), u16(name.length), u16(0), u16(0),
      u16(0), u16(0), u32(0), u32(offset), name,
    ]);
    centralParts.push(centralHeader);
    offset += localHeader.length + content.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  const end = Buffer.concat([
    u32(0x06054b50), u16(0), u16(0), u16(files.length), u16(files.length),
    u32(centralDirectory.length), u32(offset), u16(0),
  ]);

  return Buffer.concat([...localParts, centralDirectory, end]);
}

function invoiceHtml(invoiceRef: string, rows: PackRow[]) {
  const first = rows[0];
  const totalQty = rows.reduce((sum, row) => sum + n(row.qty_allocated), 0);
  const totalValue = rows.reduce((sum, row) => sum + n(row.total_export_value_gbp), 0);
  const lineRows = rows.map((row) => `
    <tr>
      <td>${esc(cleanDescription(row.item_description))}</td>
      <td>${esc(display(row.order_ref))}</td>
      <td class="num">${esc(qty(row.qty_allocated))}</td>
      <td class="num">${esc(money(row.unit_export_value_gbp))}</td>
      <td class="num">${esc(money(row.total_export_value_gbp))}</td>
    </tr>`).join("");

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>${esc(invoiceRef)} sales invoice evidence</title>
  <style>
    body { font-family: Arial, Helvetica, sans-serif; color: #111827; margin: 28px; }
    h1 { margin: 0 0 8px; font-size: 22px; }
    .meta { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin: 16px 0; }
    .box { border: 1px solid #d1d5db; border-radius: 8px; padding: 10px; }
    .label { color: #6b7280; font-size: 11px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; }
    .value { margin-top: 4px; font-weight: 700; }
    table { width: 100%; border-collapse: collapse; margin-top: 18px; font-size: 12px; }
    th, td { border: 1px solid #9ca3af; padding: 8px; vertical-align: top; }
    th { background: #f3f4f6; text-align: left; text-transform: uppercase; font-size: 10px; letter-spacing: .05em; }
    .num { text-align: right; white-space: nowrap; }
    .totals { margin-top: 12px; display: flex; justify-content: flex-end; gap: 20px; font-weight: 800; }
    .note { margin-top: 16px; color: #4b5563; font-size: 12px; line-height: 1.5; }
  </style>
</head>
<body>
  <h1>Sales invoice evidence</h1>
  <div class="meta">
    <div class="box"><div class="label">Sales invoice ref</div><div class="value">${esc(invoiceRef)}</div></div>
    <div class="box"><div class="label">Shipment / booking ref</div><div class="value">${esc(display(first.booking_ref))}</div></div>
    <div class="box"><div class="label">Customer</div><div class="value">${esc(display(first.customer_name))}</div></div>
    <div class="box"><div class="label">Destination</div><div class="value">${esc(display(first.destination, "Ghana"))}</div></div>
  </div>
  <table><thead><tr><th>Description</th><th>Order ref</th><th class="num">Qty</th><th class="num">Unit value GBP</th><th class="num">Total value GBP</th></tr></thead><tbody>${lineRows}</tbody></table>
  <div class="totals"><span>Total Qty: ${esc(qty(totalQty))}</span><span>Total Value: GBP ${esc(money(totalValue))}</span></div>
  <p class="note">Generated from the same posted customer sales invoice values used by the COS / EEP pack. Supplementary shipping-only invoices are excluded from this goods schedule.</p>
</body>
</html>`;
}

export async function GET(_request: Request, { params }: { params: Promise<{ shipment_batch_id: string }> }) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Unauthenticated", { status: 401 });

  const { data, error } = await (supabase as any).rpc("shipper_export_evidence_pack_preview_v1", {
    p_shipment_batch_id: shipmentBatchId,
  });

  if (error) return new NextResponse(`Unable to generate sales invoice ZIP: ${error.message}`, { status: 400 });

  const rows = (data ?? []) as PackRow[];
  const invoiceRows = rows.filter((row) => String(row.sales_invoice_ref ?? "").trim());
  if (invoiceRows.length === 0) {
    return new NextResponse("No posted customer sales invoice references found for this shipment batch.", { status: 404 });
  }

  const grouped = new Map<string, PackRow[]>();
  for (const row of invoiceRows) {
    const ref = String(row.sales_invoice_ref).trim();
    grouped.set(ref, [...(grouped.get(ref) ?? []), row]);
  }

  const files = Array.from(grouped.entries()).map(([ref, groupRows]) => ({
    name: `sales-invoices/${safeName(ref)}.html`,
    content: invoiceHtml(ref, groupRows),
  }));

  files.unshift({
    name: "README.txt",
    content: [
      "Sales invoice evidence ZIP",
      `Shipment batch: ${shipmentBatchId}`,
      `Invoice files: ${files.length}`,
      "",
      "Each HTML file contains the posted customer sales invoice line values used by the COS / EEP pack.",
      "Supplementary shipping-only invoices are intentionally excluded.",
    ].join("\n"),
  });

  const archive = zip(files);
  const first = rows[0];
  const filename = `${safeName(first?.eep_ref || first?.booking_ref || shipmentBatchId)}-sales-invoices.zip`;

  return new NextResponse(archive, {
    headers: {
      "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename="${filename}"`,
      "Cache-Control": "no-store",
    },
  });
}
