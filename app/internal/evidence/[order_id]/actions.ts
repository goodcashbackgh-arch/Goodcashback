"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

function readString(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}

function redirectWithResult(orderId: string, params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/evidence/${orderId}?${query.toString()}`);
}

export async function createOrderEvidenceQueryAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = readString(formData, "order_id");

  if (!orderId) {
    redirect("/internal/evidence?query_error=Missing+order+reference.");
  }

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirectWithResult(orderId, {
      query_error: "Please sign in again before creating an evidence query.",
    });
  }

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) {
    redirectWithResult(orderId, {
      query_error: "Active staff user not found.",
    });
  }

  if (!["admin", "supervisor"].includes(String(staff.role_type))) {
    redirectWithResult(orderId, {
      query_error: "Only admin or supervisor staff can create evidence queries.",
    });
  }

  const queryType = readString(formData, "query_type");
  const message = readString(formData, "message");
  const supplierInvoiceId = readString(formData, "supplier_invoice_id") || null;
  const supplierInvoiceLineId = readString(formData, "supplier_invoice_line_id") || null;
  const orderTrackingSubmissionId = readString(formData, "order_tracking_submission_id") || null;

  const { data, error } = await supabase.rpc("staff_create_order_evidence_query", {
    p_order_id: orderId,
    p_query_type: queryType,
    p_message: message,
    p_supplier_invoice_id: supplierInvoiceId,
    p_supplier_invoice_line_id: supplierInvoiceLineId,
    p_order_tracking_submission_id: orderTrackingSubmissionId,
  });

  if (error) {
    redirectWithResult(orderId, {
      query_error: error.message,
    });
  }

  revalidatePath(`/internal/evidence/${orderId}`);

  const createdQueryType =
    typeof data === "object" && data !== null && "query_type" in data
      ? String((data as { query_type?: unknown }).query_type)
      : queryType;

  redirectWithResult(orderId, {
    query_success: `Created ${createdQueryType} evidence query.`,
  });
}

async function getActiveStaff(supabase: Awaited<ReturnType<typeof createClient>>) {
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { staff: null, error: "Please sign in again." };

  const { data: staff, error: staffError } = await supabase
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (staffError || !staff) return { staff: null, error: "Active staff user not found." };

  return { staff, error: null };
}

export async function closeOrderEvidenceQueryAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = readString(formData, "order_id");
  const queryId = readString(formData, "query_id");
  const notes = readString(formData, "notes");

  if (!orderId || !queryId) {
    redirect(`/internal/evidence?query_error=Missing+order+or+query+reference.`);
  }

  const { error: staffError } = await getActiveStaff(supabase);
  if (staffError) {
    redirectWithResult(orderId, {
      query_error: staffError,
    });
  }

  const { error } = await supabase.rpc("staff_close_order_evidence_query", {
    p_order_evidence_query_id: queryId,
    p_resolution_notes: notes,
  });

  if (error) {
    redirectWithResult(orderId, {
      query_error: error.message,
    });
  }

  revalidatePath(`/internal/evidence/${orderId}`);
  redirectWithResult(orderId, {
    query_success: "Evidence query closed.",
  });
}

export async function cancelOrderEvidenceQueryAction(formData: FormData) {
  const supabase = await createClient();
  const orderId = readString(formData, "order_id");
  const queryId = readString(formData, "query_id");
  const notes = readString(formData, "notes");

  if (!orderId || !queryId) {
    redirect(`/internal/evidence?query_error=Missing+order+or+query+reference.`);
  }

  const { error: staffError } = await getActiveStaff(supabase);
  if (staffError) {
    redirectWithResult(orderId, {
      query_error: staffError,
    });
  }

  const { error } = await supabase.rpc("staff_cancel_order_evidence_query", {
    p_order_evidence_query_id: queryId,
    p_resolution_notes: notes,
  });

  if (error) {
    redirectWithResult(orderId, {
      query_error: error.message,
    });
  }

  revalidatePath(`/internal/evidence/${orderId}`);
  redirectWithResult(orderId, {
    query_success: "Evidence query cancelled.",
  });
}
