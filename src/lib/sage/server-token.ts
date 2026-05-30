import { supabaseAdmin } from "@/lib/supabase/admin";
import {
  assertSageOAuthConfigured,
  decryptSecret,
  encryptSecret,
  exchangeSageToken,
  redactedTokenPayload,
  scopesFromToken,
  tokenExpiresAt,
  tokenRefreshRequired,
} from "@/lib/sage/oauth";

type ActiveTokenRow = {
  id: string;
  connection_id: string;
  access_token_encrypted: string;
  refresh_token_encrypted: string;
  expires_at: string;
};

type SageAccessTokenResult = {
  connectionId: string;
  accessToken: string;
  expiresAt: string;
  refreshed: boolean;
};

async function loadActiveToken(connectionId?: string): Promise<ActiveTokenRow | null> {
  let query = supabaseAdmin
    .from("sage_oauth_tokens")
    .select("id, connection_id, access_token_encrypted, refresh_token_encrypted, expires_at")
    .eq("status", "active")
    .order("expires_at", { ascending: false })
    .limit(1);

  if (connectionId) query = query.eq("connection_id", connectionId);

  const { data, error } = await query;
  if (error) throw new Error(`Sage token lookup failed: ${error.message}`);
  return (data?.[0] ?? null) as ActiveTokenRow | null;
}

async function markRefreshFailed(connectionId: string, tokenId: string, code: string, message: string) {
  await supabaseAdmin
    .from("sage_oauth_tokens")
    .update({ status: "refresh_failed", updated_at: new Date().toISOString() })
    .eq("id", tokenId);

  await supabaseAdmin
    .from("sage_connections")
    .update({
      status: "refresh_failed",
      last_error_code: code,
      last_error_message: message,
      updated_at: new Date().toISOString(),
    })
    .eq("id", connectionId);
}

export async function getValidSageAccessToken(options: { connectionId?: string; origin?: string; forceRefresh?: boolean } = {}): Promise<SageAccessTokenResult> {
  const config = assertSageOAuthConfigured(options.origin);
  const token = await loadActiveToken(options.connectionId);
  if (!token) throw new Error("No active Sage OAuth token found.");

  const shouldRefresh = options.forceRefresh || tokenRefreshRequired(token.expires_at);
  if (!shouldRefresh) {
    return {
      connectionId: token.connection_id,
      accessToken: decryptSecret(token.access_token_encrypted),
      expiresAt: token.expires_at,
      refreshed: false,
    };
  }

  const { data: requestLog } = await supabaseAdmin
    .from("sage_api_request_log")
    .insert({
      connection_id: token.connection_id,
      connection_event_type: "token_refresh",
      request_kind: "token_refresh",
      http_method: "POST",
      endpoint_path: "/token",
      request_payload_redacted: { grant_type: "refresh_token", refresh_strategy: "server_side_auto" },
    })
    .select("id")
    .single();

  let refreshToken = "";
  try {
    refreshToken = decryptSecret(token.refresh_token_encrypted);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not decrypt Sage refresh token.";
    await markRefreshFailed(token.connection_id, token.id, "decrypt_failed", message);
    throw new Error("Could not decrypt Sage refresh token.");
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
    await markRefreshFailed(token.connection_id, token.id, "token_refresh_failed", JSON.stringify(redactedTokenPayload(tokenResult.raw)));
    throw new Error(`Sage token refresh failed (${tokenResult.response.status}).`);
  }

  await supabaseAdmin
    .from("sage_oauth_tokens")
    .update({
      status: "superseded",
      superseded_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", token.id);

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

  await supabaseAdmin
    .from("sage_connections")
    .update({
      status: "connected",
      last_refresh_at: new Date().toISOString(),
      last_error_code: null,
      last_error_message: null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", token.connection_id);

  return {
    connectionId: token.connection_id,
    accessToken: tokenResult.raw.access_token,
    expiresAt,
    refreshed: true,
  };
}

export async function sageApiFetch(path: string, init: RequestInit = {}, options: { connectionId?: string; origin?: string } = {}) {
  if (/^https?:\/\//i.test(path)) throw new Error("sageApiFetch expects a Sage API path, not a full URL.");

  const config = assertSageOAuthConfigured(options.origin);
  const token = await getValidSageAccessToken({ connectionId: options.connectionId, origin: options.origin });
  const url = `${config.apiBaseUrl.replace(/\/$/, "")}${path.startsWith("/") ? path : `/${path}`}`;

  return fetch(url, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init.headers ?? {}),
      Authorization: `Bearer ${token.accessToken}`,
    },
    cache: "no-store",
  });
}
