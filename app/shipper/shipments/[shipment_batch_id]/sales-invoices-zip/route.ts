import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { sageApiFetch } from "@/lib/sage/server-token";
import { createClient } from "@/utils/supabase/server";

type PackRow = {
  shipment_batch_id: string | null;
  booking_ref: string | null;
  eep_ref: string | null;
  order_id: string | null;
  order_ref: string | null;
  sales_invoice_ref: string | null;
  item_description: string | null;
  qty_allocated: number | string | null;
  unit_export_value_gbp: number | string | null;
  total_export_value_gbp: number | string | null;
  destination: string | null;
};

type SalesInvoiceRow = {
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
  return (value || "shipment-document")
    .replace(/[^a-z0-9._-]+/gi, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "shipment-document";
}

function normalize(value: string | null | undefined) {
  return String(value ?? "").trim().toLowerCase();
}

function unique(values: Array<string | null | undefined>) {
  return Array.from(new Set(values.map((value) => String(value ?? "").trim()).filter(Boolean)));
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

function pickInvoiceForGroup(ref: string, rows: PackRow[], invoices: SalesInvoiceRow[]) {
  const orderIds = new Set(unique(rows.map((row) => row.order_id)));
  const candidates = invoices.filter((invoice) => invoice.order_id && orderIds.has(invoice.order_id));
  const wantedRef = normalize(ref);

  const matchingRef = candidates.find((invoice) => normalize(invoice.sage_reference) === wantedRef);
  if (matchingRef) return matchingRef;

  const matchingSageId = candidates.find((invoice) => normalize(invoice.sage_invoice_id) === wantedRef);
  if (matchingSageId) return matchingSageId;

  if (candidates.length === 1) return candidates[0];

  return candidates
    .slice()
    .sort((a, b) => String(b.sage_posted_at ?? b.created_at ?? "").localeCompare(String(a.sage_posted_at ?? a.created_at ?? "")))[0] ?? null;
}

async function fetchSageInvoicePdf(sageInvoiceId: string, origin: string) {
  const response = await sageApiFetch(`/sales_invoices/${encodeURIComponent(sageInvoiceId)}`, {
    method: "GET",
    headers: { Accept: "application/pdf" },
  }, { origin });

  const contentType = response.headers.get("content-type") ?? "";

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`Document PDF fetch failed (${response.status} ${response.statusText}): ${body.slice(0, 300)}`);
  }

  if (!contentType.toLowerCase().includes("application/pdf")) {
    const body = await response.text().catch(() => "");
    throw new Error(`Document service returned ${contentType || "unknown content-type"}, not application/pdf. Document may not be ready. Body: ${body.slice(0, 300)}`);
  }

  return Buffer.from(await response.arrayBuffer());
}

export async function GET(request: Request, { params }: { params: Promise<{ shipment_batch_id: string }> }) {
  const { shipment_batch_id: shipmentBatchId } = await params;
  const origin = new URL(request.url).origin;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return new NextResponse("Unauthenticated", { status: 401 });

  const { data, error } = await (supabase as any).rpc("shipper_export_evidence_pack_preview_v1", {
    p_shipment_batch_id: shipmentBatchId,
  });

  if (error) return new NextResponse(`Unable to generate shipment document ZIP: ${error.message}`, { status: 400 });

  const rows = (data ?? []) as PackRow[];
  const invoiceRows = rows.filter((row) => String(row.sales_invoice_ref ?? "").trim());
  if (invoiceRows.length === 0) {
    return new NextResponse("No posted shipment document references found for this shipment batch.", { status: 404 });
  }

  const orderIds = unique(invoiceRows.map((row) => row.order_id));
  if (orderIds.length === 0) {
    return new NextResponse("No order ids were returned for the posted document evidence rows.", { status: 404 });
  }

  const { data: invoiceData, error: invoiceError } = await supabaseAdmin
    .from("sales_invoices")
    .select("id, order_id, sage_invoice_id, sage_reference, sage_status, invoice_type, sage_posted_at, created_at")
    .in("order_id", orderIds)
    .eq("invoice_type", "main")
    .eq("sage_status", "posted");

  if (invoiceError) {
    return new NextResponse(`Unable to resolve document ids for shipment document ZIP: ${invoiceError.message}`, { status: 400 });
  }

  const invoices = (invoiceData ?? []) as SalesInvoiceRow[];
  const grouped = new Map<string, PackRow[]>();
  for (const row of invoiceRows) {
    const ref = String(row.sales_invoice_ref).trim();
    grouped.set(ref, [...(grouped.get(ref) ?? []), row]);
  }

  const files: { name: string; content: string | Buffer }[] = [];
  const failures: string[] = [];

  for (const [ref, groupRows] of grouped.entries()) {
    const invoice = pickInvoiceForGroup(ref, groupRows, invoices);
    const sageInvoiceId = String(invoice?.sage_invoice_id ?? "").trim();

    if (!invoice || !sageInvoiceId) {
      failures.push(`${ref}: no posted document id found for order(s) ${unique(groupRows.map((row) => row.order_ref)).join(", ") || "unknown"}.`);
      continue;
    }

    try {
      const pdf = await fetchSageInvoicePdf(sageInvoiceId, origin);
      files.push({
        name: `shipment-documents/${safeName(ref)}.pdf`,
        content: pdf,
      });
    } catch (error) {
      failures.push(`${ref}: ${error instanceof Error ? error.message : "Document PDF fetch failed."}`);
    }
  }

  if (files.length === 0) {
    return new NextResponse([
      "No shipment document PDFs could be added to the ZIP.",
      "",
      ...failures,
    ].join("\n"), { status: 502 });
  }

  files.unshift({
    name: "README.txt",
    content: [
      "Shipment document ZIP",
      `Shipment batch: ${shipmentBatchId}`,
      `PDF files: ${files.length}`,
      "",
      "PDF files are fetched from approved platform document records for shipment evidence support.",
      "Supplementary shipping-only charge documents are intentionally excluded from this COS / EEP support pack.",
      ...(failures.length > 0 ? ["", "Fetch warnings:", ...failures] : []),
    ].join("\n"),
  });

  const archive = zip(files);
  const first = rows[0];
  const filename = `${safeName(first?.eep_ref || first?.booking_ref || shipmentBatchId)}-shipment-documents.zip`;

  return new NextResponse(archive, {
    headers: {
      "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename="${filename}"`,
      "Cache-Control": "no-store",
    },
  });
}
