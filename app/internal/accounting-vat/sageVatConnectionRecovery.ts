"use server";

import { supabaseAdmin } from "@/lib/supabase/admin";

type Row = Record<string, unknown>;

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

export async function recoverSageConnectionStatusForVatRead() {
  const { data: tokens, error: tokenError } = await supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, expires_at")
    .eq("status", "active")
    .order("expires_at", { ascending: false })
    .limit(1);

  if (tokenError) throw new Error(`Sage token lookup failed: ${tokenError.message}`);

  const token = (tokens?.[0] ?? null) as Row | null;
  const connectionId = text(token?.connection_id);
  if (!connectionId) throw new Error("No active Sage OAuth token found.");

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, status")
    .eq("id", connectionId)
    .maybeSingle();

  if (connectionError) throw new Error(connectionError.message);

  const status = text((connection as Row | null)?.status);
  if (!connection || ["disabled", "revoked"].includes(status)) {
    throw new Error("Sage connection is disabled, revoked, or missing.");
  }

  if (status === "connected") return { connectionId, recovered: false };

  if (["refresh_failed", "error"].includes(status)) {
    await supabaseAdmin
      .from("sage_connections")
      .update({
        status: "connected",
        last_error_code: null,
        last_error_message: null,
        updated_at: new Date().toISOString(),
      })
      .eq("id", connectionId);

    return { connectionId, recovered: true };
  }

  throw new Error(`Sage connection status ${status || "unknown"} is not recoverable for VAT reconstruction.`);
}
