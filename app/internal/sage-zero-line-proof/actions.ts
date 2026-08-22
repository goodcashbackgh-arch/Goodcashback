"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { decryptSecret, sageOAuthConfig, tokenRefreshRequired } from "@/lib/sage/oauth";

const TEST_CONTACT_NAME = "Goods To Ship API Zero Test";
const TEST_CONTACT_REFERENCE = "GTSZERO";
const CONTROL_DESCRIPTION = "Goods To Ship zero-line control";
const ZERO_DESCRIPTION = "Goods To Ship zero-line runtime proof";
const CONFIRMATION = "RUN GTSZERO";

type Row = Record<string, any>;

function text(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

function sageValidationMessage(raw: unknown) {
  const parts: string[] = [];
  const keys = new Set(["$message", "message", "error", "error_description", "detail", "$dataCode", "code", "field", "property", "$source", "source"]);

  const visit = (value: unknown, depth = 0) => {
    if (depth > 4 || value === null || value === undefined) return;
    if (Array.isArray(value)) {
      for (const item of value) visit(item, depth + 1);
      return;
    }
    if (typeof value !== "object") return;

    for (const [key, child] of Object.entries(value as Row)) {
      if (keys.has(key) && (typeof child === "string" || typeof child === "number" || typeof child === "boolean")) {
        const safe = String(child).replace(/\s+/g, " ").trim();
        if (safe) parts.push(`${key}: ${safe}`);
      } else if (typeof child === "object" && child !== null) {
        visit(child, depth + 1);
      }
    }
  };

  visit(raw);
  return [...new Set(parts)].join(" | ").slice(0, 700) || "Sage returned a validation error without a displayable message.";
}

function redirectResult(values: Record<string, string | number | boolean | null | undefined>): never {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) {
    if (value === undefined || value === null) continue;
    params.set(key, String(value));
  }
  redirect(`/internal/sage-zero-line-proof?${params.toString()}`);
}

async function requireStaff() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: staff, error } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (error || !staff?.id) redirect("/auth/check");
  return { supabase };
}

async function sageCall(args: {
  apiBaseUrl: string;
  accessToken: string;
  sageBusinessId: string;
  method: "GET" | "POST" | "DELETE";
  path: string;
  body?: unknown;
}) {
  const response = await fetch(`${args.apiBaseUrl.replace(/\/$/, "")}${args.path}`, {
    method: args.method,
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${args.accessToken}`,
      "X-Business": args.sageBusinessId,
      ...(args.body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    body: args.body === undefined ? undefined : JSON.stringify(args.body),
    cache: "no-store",
  });
  const raw = response.status === 204
    ? null
    : await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  return { response, raw, requestId: response.headers.get("x-request-id") || response.headers.get("x_request_id") };
}

function objectId(raw: unknown, location: string | null) {
  const row = raw && typeof raw === "object" && !Array.isArray(raw) ? raw as Row : {};
  const fromBody = text(row.id) || text(row.purchase_invoice?.id) || text(row.data?.id) || text(row.$items?.[0]?.id);
  if (fromBody) return fromBody;
  if (!location) return "";
  const clean = location.split("?")[0].replace(/\/$/, "");
  return decodeURIComponent(clean.slice(clean.lastIndexOf("/") + 1));
}

function findDescription(value: unknown, description: string): Row | null {
  if (Array.isArray(value)) {
    for (const child of value) {
      const found = findDescription(child, description);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== "object") return null;
  const row = value as Row;
  if (text(row.description) === description) return row;
  for (const child of Object.values(row)) {
    const found = findDescription(child, description);
    if (found) return found;
  }
  return null;
}

function contactIsVendor(row: Row) {
  const types = Array.isArray(row.contact_types) ? row.contact_types : [];
  return types.some((item: unknown) => {
    if (typeof item === "string") return item === "VENDOR";
    const candidate = item && typeof item === "object" ? item as Row : {};
    return text(candidate.id) === "VENDOR" || text(candidate.type_id) === "VENDOR";
  });
}

async function resolveCreatedInvoiceIdByReference(args: {
  common: { apiBaseUrl: string; accessToken: string; sageBusinessId: string };
  reference: string;
}) {
  const search = await sageCall({
    ...args.common,
    method: "GET",
    path: `/purchase_invoices?search=${encodeURIComponent(args.reference)}&items_per_page=20&attributes=all`,
  });
  if (!search.response.ok) return "";
  const items = Array.isArray((search.raw as Row)?.$items) ? (search.raw as Row).$items as Row[] : [];
  const exact = items.filter((row) => text(row.reference) === args.reference);
  return exact.length === 1 ? text(exact[0].id) : "";
}

export async function runSageZeroLineProofAction(formData: FormData) {
  const { supabase } = await requireStaff();

  if (process.env.VERCEL_ENV !== "production" || process.env.VERCEL_GIT_COMMIT_REF !== "main") {
    redirectResult({ code: "production_main_only", sage_write_made: false });
  }
  if (text(formData.get("confirmation")) !== CONFIRMATION) {
    redirectResult({ code: "confirmation_failed", sage_write_made: false });
  }

  const { data: tokenRows, error: tokenError } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, access_token_encrypted, expires_at, sage_business_row_id")
    .eq("status", "active")
    .order("expires_at", { ascending: false })
    .limit(1);
  if (tokenError) redirectResult({ code: "token_read_failed", sage_write_made: false });
  const token = (tokenRows?.[0] ?? null) as Row | null;
  if (!token) redirectResult({ code: "active_token_missing", sage_write_made: false });
  if (tokenRefreshRequired(token.expires_at, 90)) {
    redirectResult({ code: "active_token_not_safe_for_probe", sage_write_made: false });
  }

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, status")
    .eq("id", token.connection_id)
    .maybeSingle();
  if (connectionError || !connection || connection.status !== "connected") {
    redirectResult({ code: "sage_connection_not_connected", sage_write_made: false });
  }

  let businessQuery = supabaseAdmin
    .from("sage_businesses")
    .select("id, sage_business_id, sage_business_name")
    .eq("connection_id", token.connection_id)
    .eq("status", "active")
    .order("is_primary", { ascending: false })
    .limit(1);
  const selectedBusinessRowId = text(token.sage_business_row_id);
  if (selectedBusinessRowId) businessQuery = businessQuery.eq("id", selectedBusinessRowId);
  const { data: businesses, error: businessError } = await businessQuery;
  if (businessError) redirectResult({ code: "business_read_failed", sage_write_made: false });
  const business = (businesses?.[0] ?? null) as Row | null;
  const sageBusinessId = text(business?.sage_business_id);
  if (!sageBusinessId) redirectResult({ code: "active_sage_business_missing", sage_write_made: false });

  const { data: mappingData, error: mappingError } = await (supabase as any).rpc("internal_sage_mapping_control_v1");
  if (mappingError) redirectResult({ code: "mapping_read_failed", sage_write_made: false });
  const mappings = (mappingData ?? []) as Row[];
  const ledger = mappings.find((row) => row.mapping_code === "SUPPLIER_GOODS_AP_LEDGER" && row.mapping_status === "configured");
  const taxRate = mappings.find((row) => row.mapping_code === "SUPPLIER_GOODS_AP_TAX_RATE" && row.mapping_status === "configured");
  const ledgerId = text(ledger?.sage_external_id);
  const taxRateId = text(taxRate?.sage_external_id);
  if (!ledgerId || !taxRateId) redirectResult({ code: "supplier_goods_ap_mapping_missing", sage_write_made: false });

  const accessToken = decryptSecret(text(token.access_token_encrypted));
  const config = sageOAuthConfig();
  const common = { apiBaseUrl: config.apiBaseUrl, accessToken, sageBusinessId };

  const contacts = await sageCall({
    ...common,
    method: "GET",
    path: `/contacts?search=${encodeURIComponent(TEST_CONTACT_REFERENCE)}&items_per_page=100&attributes=all`,
  });
  if (!contacts.response.ok) {
    redirectResult({ code: "test_contact_search_failed", http_status: contacts.response.status, sage_write_made: false });
  }
  const items = Array.isArray((contacts.raw as Row)?.$items) ? (contacts.raw as Row).$items as Row[] : [];
  const exact = items.filter((row) => text(row.name) === TEST_CONTACT_NAME && text(row.reference) === TEST_CONTACT_REFERENCE);
  if (exact.length !== 1) {
    redirectResult({ code: exact.length === 0 ? "dedicated_test_contact_missing" : "dedicated_test_contact_not_unique", sage_write_made: false, match_count: exact.length });
  }
  const contact = exact[0];
  if (!contactIsVendor(contact)) redirectResult({ code: "dedicated_test_contact_is_not_vendor", sage_write_made: false });

  const reference = `GTS-ZERO-${Date.now()}`;
  const date = new Date().toISOString().slice(0, 10);
  const body = {
    purchase_invoice: {
      contact_id: text(contact.id),
      date,
      due_date: date,
      reference,
      notes: "Disposable Goods To Ship Sage zero-line runtime proof; delete immediately after verification.",
      currency_code: "GBP",
      invoice_lines: [
        {
          description: CONTROL_DESCRIPTION,
          ledger_account_id: ledgerId,
          tax_rate_id: taxRateId,
          eu_goods_services_type_id: "GOODS",
          quantity: 1,
          unit_price: 1,
          tax_amount: 0.2,
          currency_tax_amount: 0,
        },
        {
          description: ZERO_DESCRIPTION,
          ledger_account_id: ledgerId,
          tax_rate_id: taxRateId,
          eu_goods_services_type_id: "GOODS",
          quantity: 1,
          unit_price: 0,
          tax_amount: 0,
          currency_tax_amount: 0,
        },
      ],
    },
  };

  let invoiceId = "";
  let createStatus: number | null = null;
  let getStatus: number | null = null;
  let deleteStatus: number | null = null;
  let zeroLine: Row | null = null;
  let controlLine: Row | null = null;
  let createRequestId: string | null = null;
  let getRequestId: string | null = null;
  let deleteRequestId: string | null = null;
  let createValidationError = "";

  try {
    const created = await sageCall({ ...common, method: "POST", path: "/purchase_invoices", body });
    createStatus = created.response.status;
    createRequestId = created.requestId;
    if (!created.response.ok) createValidationError = sageValidationMessage(created.raw);
    invoiceId = objectId(created.raw, created.response.headers.get("location"));

    if (createStatus === 201 && !invoiceId) {
      invoiceId = await resolveCreatedInvoiceIdByReference({ common, reference });
    }

    if (createStatus === 201 && invoiceId) {
      const fetched = await sageCall({ ...common, method: "GET", path: `/purchase_invoices/${encodeURIComponent(invoiceId)}?attributes=all` });
      getStatus = fetched.response.status;
      getRequestId = fetched.requestId;
      if (fetched.response.ok) {
        zeroLine = findDescription(fetched.raw, ZERO_DESCRIPTION);
        controlLine = findDescription(fetched.raw, CONTROL_DESCRIPTION);
      }
    }
  } finally {
    if (!invoiceId && createStatus === 201) {
      invoiceId = await resolveCreatedInvoiceIdByReference({ common, reference });
    }
    if (invoiceId) {
      let deleted = await sageCall({ ...common, method: "DELETE", path: `/purchase_invoices/${encodeURIComponent(invoiceId)}` });
      if ([408, 429].includes(deleted.response.status) || deleted.response.status >= 500) {
        await new Promise((resolve) => setTimeout(resolve, 500));
        deleted = await sageCall({ ...common, method: "DELETE", path: `/purchase_invoices/${encodeURIComponent(invoiceId)}` });
      }
      deleteStatus = deleted.response.status;
      deleteRequestId = deleted.requestId;
    }
  }

  const zeroUnitPrice = Number(zeroLine?.unit_price);
  const zeroTaxAmount = Number(zeroLine?.tax_amount ?? zeroLine?.currency_tax_amount ?? 0);
  const proven = createStatus === 201
    && getStatus === 200
    && Boolean(controlLine)
    && Boolean(zeroLine)
    && Number.isFinite(zeroUnitPrice)
    && zeroUnitPrice === 0
    && Number.isFinite(zeroTaxAmount)
    && zeroTaxAmount === 0
    && deleteStatus === 204;

  redirectResult({
    code: proven ? "sage_zero_line_runtime_proven" : "sage_zero_line_runtime_not_proven",
    reference,
    create_status: createStatus,
    sage_validation_error: createValidationError || null,
    get_status: getStatus,
    delete_status: deleteStatus,
    zero_line_retained: Boolean(zeroLine),
    zero_line_unit_price: Number.isFinite(zeroUnitPrice) ? zeroUnitPrice : null,
    zero_line_tax_amount: Number.isFinite(zeroTaxAmount) ? zeroTaxAmount : null,
    control_line_retained: Boolean(controlLine),
    cleanup_complete: deleteStatus === 204,
    sage_write_made: createStatus === 201,
    create_request_id: createRequestId,
    get_request_id: getRequestId,
    delete_request_id: deleteRequestId,
  });
}
