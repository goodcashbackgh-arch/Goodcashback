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
