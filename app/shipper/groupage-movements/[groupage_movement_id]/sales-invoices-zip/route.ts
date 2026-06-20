import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { sageApiFetch } from "@/lib/sage/server-token";
import { createClient } from "@/utils/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type PackRow = {
  groupage_movement_ref: string | null;
  booking_ref: string | null;
  order_id: string | null;
  order_ref: string | null;
  sales_invoice_ref: string | null;
};

type InvoiceRow = {
  id: string;
  order_id: string | null;
  sage_invoice_id: string | null;
  sage_reference: string | null;
  sage_status: string | null;
  invoice_type: string | null;
  sage_posted_at: string | null;
  created_at: string | null;
};

function safeName(value: string | null | undefined) {
  return (value || "document").replace(/[^a-z0-9._-]+/gi, "-").replace(/-+/g, "-").replace(/^-|-$/g, "") || "document";
}

function unique(values: Array<string | null | undefined>) {
  return Array.from(new Set(values.map((value) => String(value ?? "").trim()).filter(Boolean)));
}

function normal(value: string | null | undefined) {
  return String(value ?? "").trim().toLowerCase();
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

function zip(files: { name: string; content: Buffer | string }[]) {
  const localParts: Buffer[] = [];
  const centralParts: Buffer[] = [];
  let offset = 0;

  for (const file of files) {
    const name = Buffer.from(file.name, "utf8");
    const content = Buffer.isBuffer(file.content) ? file.content : Buffer.from(file.content, "utf8");
    const crc = crc32(content);
    const local = Buffer.concat([u32(0x04034b50), u16(20), u16(0), u16(0), u16(0), u16(0), u32(crc), u32(content.length), u32(content.length), u16(name.length), u16(0), name]);
    const central = Buffer.concat([u32(0x02014b50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0), u32(crc), u32(content.length), u32(content.length), u16(name.length), u16(0), u16(0), u16(0), u16(0), u32(0), u32(offset), name]);
    localParts.push(local, content);
    centralParts.push(central);
    offset += local.length + content.length;
  }

  const centralDirectory = Buffer.concat(centralParts);
  const end = Buffer.concat([u32(0x06054b50), u16(0), u16(0), u16(files.length), u16(files.length), u32(centralDirectory.length), u32(offset), u16(0)]);
  return Buffer.concat([...localParts, centralDirectory, end]);
}

function pickInvoiceForRef(ref: string, groupRows: PackRow[], invoices: InvoiceRow[]) {
  const groupOrderIds = new Set(unique(groupRows.map((row) => row.order_id)));
  const candidates = invoices.filter((invoice) => invoice.order_id && groupOrderIds.has(invoice.order_id));
  const wantedRef = normal(ref);

  return candidates.find((invoice) => normal(invoice.sage_reference) === wantedRef)
    ?? candidates.find((invoice) => normal(invoice.sage_invoice_id) === wantedRef)
    ?? (candidates.length === 1 ? candidates[0] : null)
    ?? candidates.sort((a, b) => String(b.sage_posted_at ?? b.created_at ?? "").localeCompare(String(a.sage_posted_at ?? a.created_at ?? "")))[0]
    ?? null;
}

async function fetchInvoicePdf(invoiceId: string, origin: string) {
  const response = await sageApiFetch(`/sales_invoices/${encodeURIComponent(invoiceId)}`, {
    method: "GET",
    headers: { Accept: "application/pdf" },
  }, { origin });

  if (!response.ok) throw new Error(`PDF fetch failed: ${response.status} ${response.statusText}`);
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().includes("application/pdf")) throw new Error(`Expected PDF, received ${contentType || "unknown content type"}`);
  return Buffer.from(await response.arrayBuffer());
}

export async function GET(request: Request, { params }: { params: Promise<{ groupage_movement_id: string }> }) {
  const { groupage_movement_id: groupageMovementId } = await params;
  const origin = new URL(request.url).origin;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Unauthenticated", { status: 401 });

  const { data, error } = await (supabase as any).rpc("shipper_groupage_export_pack_preview_v1", {
    p_groupage_movement_id: groupageMovementId,
  });
  if (error) return new NextResponse(`Unable to generate supporting ZIP: ${error.message}`, { status: 400 });

  const rows = (data ?? []) as PackRow[];
  const invoiceRows = rows.filter((row) => String(row.sales_invoice_ref ?? "").trim());
  if (invoiceRows.length === 0) return new NextResponse("No posted customer sales invoice references found for this Groupage Movement.", { status: 404 });

  const orderIds = unique(invoiceRows.map((row) => row.order_id));
  if (orderIds.length === 0) return new NextResponse("No order ids were returned for the Groupage supporting document rows.", { status: 404 });

  const { data: invoiceData, error: invoiceError } = await supabaseAdmin
    .from("sales_invoices")
    .select("id, order_id, sage_invoice_id, sage_reference, sage_status, invoice_type, sage_posted_at, created_at")
    .in("order_id", orderIds)
    .eq("invoice_type", "main")
    .eq("sage_status", "posted");
  if (invoiceError) return new NextResponse(`Unable to resolve supporting invoice documents: ${invoiceError.message}`, { status: 400 });

  const invoices = (invoiceData ?? []) as InvoiceRow[];
  const grouped = new Map<string, PackRow[]>();
  for (const row of invoiceRows) {
    const ref = String(row.sales_invoice_ref).trim();
    grouped.set(ref, [...(grouped.get(ref) ?? []), row]);
  }

  const files: { name: string; content: Buffer | string }[] = [];
  const warnings: string[] = [];

  for (const [ref, groupRows] of grouped.entries()) {
    const invoice = pickInvoiceForRef(ref, groupRows, invoices);
    const invoiceId = String(invoice?.sage_invoice_id ?? "").trim();
    const bookingRefs = unique(groupRows.map((row) => row.booking_ref));
    const orderRefs = unique(groupRows.map((row) => row.order_ref));
    if (!invoiceId) {
      warnings.push(`${ref}: posted document id not found for booking(s) ${bookingRefs.join(", ") || "unknown"} / order(s) ${orderRefs.join(", ") || "unknown"}.`);
      continue;
    }
    try {
      files.push({
        name: `shipment-documents/${safeName(bookingRefs.join("-") || "booking")}-${safeName(ref)}.pdf`,
        content: await fetchInvoicePdf(invoiceId, origin),
      });
    } catch (err) {
      warnings.push(`${ref}: ${err instanceof Error ? err.message : "PDF fetch failed."}`);
    }
  }

  if (files.length === 0) return new NextResponse(["No customer sales invoice PDFs could be added to the ZIP.", "", ...warnings].join("\n"), { status: 502 });

  const movementRef = rows[0]?.groupage_movement_ref || groupageMovementId;
  files.unshift({
    name: "manifest.txt",
    content: [
      "Groupage supporting shipment documents ZIP",
      `Groupage movement: ${movementRef}`,
      `Groupage movement id: ${groupageMovementId}`,
      `PDF files: ${files.length}`,
      "",
      "This ZIP contains the posted customer sales invoice PDFs referenced by the Groupage Export Pack annex.",
      "It supports the export pack. It does not replace signed export evidence upload or batch-level evidence records.",
      ...(warnings.length ? ["", "Warnings:", ...warnings] : []),
    ].join("\n"),
  });

  return new NextResponse(zip(files), {
    headers: {
      "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename="${safeName(movementRef)}-supporting-shipment-documents.zip"`,
      "Cache-Control": "no-store",
    },
  });
}
