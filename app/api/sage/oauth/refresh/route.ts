import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import {
  assertSageOAuthConfigured,
  decryptSecret,
  encryptSecret,
  exchangeSageToken,
  redactedTokenPayload,
  scopesFromToken,
  tokenExpiresAt,
} from "@/lib/sage/oauth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type TokenRow = {
  id: string;
  connection_id: string;
  refresh_token_encrypted: string;
};

async function requireAccountingUser() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false as const, status: 401, error: "Login required." };

  const { data: allowed, error: accessError } = await supabase.rpc("internal_has_accounting_admin_access_v1");
  if (accessError) return { ok: false as const, status: 500, error: accessError.message };
  if (!allowed) return { ok: false as const, status: 403, error: "Accounting admin access required." };

  const { data: staff, error: staffError } = await supabaseAdmin
    .from("staff")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (staffError) return { ok: false as const, status: 500, error: staffError.message };
  if (!staff?.id) return { ok: false as const, status: 403, error: "Active staff record required." };

  return { ok: true as const, staffId: staff.id as string };
}

async function refreshConnection(request: Request) {
  const origin = new URL(request.url).origin;
  const user = await requireAccountingUser();
  if (!user.ok) return NextResponse.json({ ok: false, error: user.error }, { status: user.status });

  let bodyConnectionId = "";
  if (request.method === "POST") {
    const body = await request.json().catch(() => ({}));
    bodyConnectionId = typeof body.connection_id === "string" ? body.connection_id : "";
  }
  const urlConnectionId = new URL(request.url).searchParams.get("connection_id") || "";
  const connectionId = bodyConnectionId || urlConnectionId;

  let config: ReturnType<typeof assertSageOAuthConfigured>;
  try {
    config = assertSageOAuthConfigured(origin);
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : "Sage OAuth is not configured." }, { status: 500 });
  }

  let tokenQuery = supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, refresh_token_encrypted")
    .eq("status", "active")
    .order("expires_at", { ascending: true })
    .limit(1);

  if (connectionId) tokenQuery = tokenQuery.eq("connection_id", connectionId);
  const { data: tokens, error: tokenError } = await tokenQuery;
  if (tokenError) return NextResponse.json({ ok: false, error: tokenError.message }, { status: 500 });
  const token = (tokens?.[0] ?? null) as TokenRow | null;
  if (!token) return NextResponse.json({ ok: false, error: "No active Sage token found to refresh." }, { status: 404 });

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .select("id, status")
    .eq("id", token.connection_id)
    .maybeSingle();
  if (connectionError) return NextResponse.json({ ok: false, error: connectionError.message }, { status: 500 });
  if (!connection || connection.status === "disabled") return NextResponse.json({ ok: false, error: "Sage connection is disabled or missing." }, { status: 409 });

  const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: token.connection_id,
    connection_event_type: "token_refresh",
    request_kind: "token_refresh",
    http_method: "POST",
    endpoint_path: "/token",
    request_payload_redacted: { grant_type: "refresh_token" },
    created_by_staff_id: user.staffId,
  }).select("id").single();

  let refreshToken = "";
  try {
    refreshToken = decryptSecret(token.refresh_token_encrypted);
  } catch (error) {
    await supabaseAdmin.from("sage_connections").update({
      status: "refresh_failed",
      last_error_code: "decrypt_failed",
      last_error_message: error instanceof Error ? error.message : "Could not decrypt Sage refresh token.",
      updated_at: new Date().toISOString(),
    }).eq("id", token.connection_id);
    return NextResponse.json({ ok: false, error: "Could not decrypt Sage refresh token." }, { status: 500 });
  }

  const tokenResult = await exchangeSageToken({
    tokenUrl: config.tokenUrl,
    clientId: config.clientId,
    clientSecret: config.clientSecret,
    grantType: "refresh_token",
    refreshToken,
  });

  if (requestLog?.id) {
    await supabaseAdmin.from("sage_api_response_log").insert({
      request_log_id: requestLog.id,
      connection_id: token.connection_id,
      http_status: tokenResult.response.status,
      success_yn: tokenResult.response.ok,
      response_payload_redacted: redactedTokenPayload(tokenResult.raw),
      error_code: tokenResult.response.ok ? null : String((tokenResult.raw as Record<string, unknown>).error ?? "token_refresh_failed"),
      error_message: tokenResult.response.ok ? null : String((tokenResult.raw as Record<string, unknown>).error_description ?? (tokenResult.raw as Record<string, unknown>).message ?? "Sage token refresh failed."),
    });
  }

  if (!tokenResult.response.ok || !tokenResult.raw.access_token || !tokenResult.raw.refresh_token) {
    await supabaseAdmin.from("sage_oauth_tokens").update({
      status: "refresh_failed",
      updated_at: new Date().toISOString(),
    }).eq("id", token.id);
    await supabaseAdmin.from("sage_connections").update({
      status: "refresh_failed",
      last_error_code: "token_refresh_failed",
      last_error_message: JSON.stringify(redactedTokenPayload(tokenResult.raw)),
      updated_at: new Date().toISOString(),
    }).eq("id", token.connection_id);
    return NextResponse.json({ ok: false, error: `Sage token refresh failed (${tokenResult.response.status}).` }, { status: 502 });
  }

  await supabaseAdmin.from("sage_oauth_tokens").update({
    status: "superseded",
    superseded_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("id", token.id);

  const expiresAt = tokenExpiresAt(tokenResult.raw.expires_in);
  await supabaseAdmin.from("sage_oauth_tokens").insert({
    connection_id: token.connection_id,
    access_token_encrypted: encryptSecret(tokenResult.raw.access_token),
    refresh_token_encrypted: encryptSecret(tokenResult.raw.refresh_token),
    token_type: tokenResult.raw.token_type || "Bearer",
    expires_at: expiresAt,
    scopes: scopesFromToken(tokenResult.raw, config.scopes),
    status: "active",
    encryption_key_ref: "SAGE_TOKEN_ENCRYPTION_KEY:v1",
    issued_at: new Date().toISOString(),
    last_refresh_at: new Date().toISOString(),
  });

  await supabaseAdmin.from("sage_connections").update({
    status: "connected",
    last_refresh_at: new Date().toISOString(),
    last_error_code: null,
    last_error_message: null,
    updated_at: new Date().toISOString(),
  }).eq("id", token.connection_id);

  return NextResponse.json({ ok: true, connection_id: token.connection_id, token_expires_at: expiresAt });
}

export async function POST(request: Request) {
  return refreshConnection(request);
}

export async function GET(request: Request) {
  return refreshConnection(request);
}
