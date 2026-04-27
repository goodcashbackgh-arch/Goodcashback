"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/importer/evidence-queries?${query.toString()}`);
}

export async function answerOrderEvidenceQueryAction(formData: FormData) {
  const supabase = await createClient();
  const queryId = readString(formData, "query_id");
  const answerText = readString(formData, "answer_text");

  if (!queryId) {
    redirectWithResult({ query_error: "Missing evidence query id." });
  }

  if (!answerText) {
    redirectWithResult({ query_error: "Answer cannot be blank." });
  }

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ query_error: "Please sign in again before answering a query." });
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    redirectWithResult({ query_error: "Active operator account not found." });
  }

  const { error } = await supabase.rpc("operator_answer_order_evidence_query", {
    p_order_evidence_query_id: queryId,
    p_answer_text: answerText,
  });

  if (error) {
    redirectWithResult({ query_error: error.message });
  }

  revalidatePath("/importer/evidence-queries");

  redirectWithResult({ query_success: "Evidence query answered." });
}

export async function submitSupplierInvoiceAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = readString(formData, "order_id");
  const invoiceRef = readString(formData, "invoice_ref");
  const invoicePdfUrl = readString(formData, "invoice_pdf_url");

  if (!orderId) {
    redirectWithResult({ query_error: "Missing order id for invoice submission." });
  }

  if (!invoiceRef) {
    redirectWithResult({ query_error: "Invoice reference cannot be blank." });
  }

  if (!invoicePdfUrl) {
    redirectWithResult({ query_error: "Invoice PDF URL cannot be blank." });
  }

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult({ query_error: "Please sign in again before submitting an invoice." });
  }

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) {
    redirectWithResult({ query_error: "Active operator account not found." });
  }

  const { error } = await supabase.rpc("operator_submit_supplier_invoice", {
    p_order_id: orderId,
    p_invoice_ref: invoiceRef,
    p_invoice_pdf_url: invoicePdfUrl,
  });

  if (error) {
    redirectWithResult({ query_error: error.message });
  }

  revalidatePath("/importer/evidence-queries");

  redirectWithResult({ query_success: "Supplier invoice submitted." });
}
