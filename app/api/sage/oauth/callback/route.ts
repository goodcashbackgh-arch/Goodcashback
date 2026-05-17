import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import {
  assertSageOAuthConfigured,
  clearOauthCookieOptions,
  encryptSecret,
  exchangeSageToken,
  fetchSageBusinesses,
  normalizeSageBusinesses,
  oauthCookieOptions,
  redactedTokenPayload,
  SAGE_AUTH_STATE_COOKIE,
  SAGE_CONNECTION_COOKIE,
  scopesFromToken,
  sha256Hex,
  tokenExpiresAt,
} from "@/lib/sage/oauth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function finishRedirect(origin: string, params: Record<string, string>) {
  const url = new URL("/internal/accounting-command-centre", origin);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
  const response = NextResponse.redirect(url);
  response.cookies.set(SAGE_AUTH_STATE_COOKIE, "", clearOauthCookieOptions());
  response.cookies.set(SAGE_CONNECTION_COOKIE, "", clearOauthCookieOptions());
  return response;
}

export async function GET(request: Request) {
  const url = new URL(request.url);
  const origin = url.origin;
  const code = url.searchParams.get("code") || "";
  const state = url.searchParams.get("state") || "";
  const errorParam = url.searchParams.get("error") || "";
  const errorDescription = url.searchParams.get("error_description") || "";
  const cookieStore = await cookies();
  const expectedState = cookieStore.get(SAGE_AUTH_STATE_COOKIE)?.value || "";
  const connectionId = cookieStore.get(SAGE_CONNECTION_COOKIE)?.value || "";

  if (!connectionId) return finishRedirect(origin, { error: "Missing Sage connection cookie. Start OAuth again." });
  if (errorParam) {
    await supabaseAdmin.from("sage_connections").update({
      status: "error",
      last_error_code: errorParam,
      last_error_message: errorDescription || "Sage OAuth returned an error.",
      updated_at: new Date().toISOString(),
    }).eq("id", connectionId);
    return finishRedirect(origin, { error: `Sage OAuth failed: ${errorDescription || errorParam}` });
  }
  if (!code) return finishRedirect(origin, { error: "Sage OAuth callback did not include an authorization code." });
  if (!state || !expectedState || state !== expectedState) return finishRedirect(origin, { error: "Sage OAuth state check failed. Start OAuth again." });

  let config: ReturnType<typeof assertSageOAuthConfigured>;
  try {
    config = assertSageOAuthConfigured(origin);
  } catch (error) {
    return finishRedirect(origin, { error: error instanceof Error ? error.message : "Sage OAuth is not configured." });
  }

  const { data: requestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: connectionId,
    connection_event_type: "oauth_callback",
    request_kind: "oauth",
    http_method: "POST",
    endpoint_path: "/token",
    request_payload_redacted: {
      grant_type: "authorization_code",
      redirect_uri: config.redirectUri,
      code_hash: sha256Hex(code).slice(0, 16),
      state_hash: sha256Hex(state).slice(0, 16),
    },
  }).select("id").single();

  const tokenResult = await exchangeSageToken({
    tokenUrl: config.tokenUrl,
    clientId: config.clientId,
    clientSecret: config.clientSecret,
    grantType: "authorization_code",
    code,
    redirectUri: config.redirectUri,
  });

  await supabaseAdmin.from("sage_api_response_log").insert({
    request_log_id: requestLog?.id,
    connection_id: connectionId,
    http_status: tokenResult.response.status,
    success_yn: tokenResult.response.ok,
    response_payload_redacted: redactedTokenPayload(tokenResult.raw),
    error_code: tokenResult.response.ok ? null : String((tokenResult.raw as Record<string, unknown>).error ?? "token_exchange_failed"),
    error_message: tokenResult.response.ok ? null : String((tokenResult.raw as Record<string, unknown>).error_description ?? (tokenResult.raw as Record<string, unknown>).message ?? "Sage token exchange failed."),
  });

  if (!tokenResult.response.ok || !tokenResult.raw.access_token || !tokenResult.raw.refresh_token) {
    await supabaseAdmin.from("sage_connections").update({
      status: "error",
      last_error_code: "token_exchange_failed",
      last_error_message: JSON.stringify(redactedTokenPayload(tokenResult.raw)),
      updated_at: new Date().toISOString(),
    }).eq("id", connectionId);
    return finishRedirect(origin, { error: `Sage token exchange failed (${tokenResult.response.status}).` });
  }

  await supabaseAdmin.from("sage_oauth_tokens").update({
    status: "superseded",
    superseded_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }).eq("connection_id", connectionId).eq("status", "active");

  const expiresAt = tokenExpiresAt(tokenResult.raw.expires_in);
  const scopes = scopesFromToken(tokenResult.raw, config.scopes);
  const { error: tokenInsertError } = await supabaseAdmin.from("sage_oauth_tokens").insert({
    connection_id: connectionId,
    access_token_encrypted: encryptSecret(tokenResult.raw.access_token),
    refresh_token_encrypted: encryptSecret(tokenResult.raw.refresh_token),
    token_type: tokenResult.raw.token_type || "Bearer",
    expires_at: expiresAt,
    scopes,
    status: "active",
    encryption_key_ref: "SAGE_TOKEN_ENCRYPTION_KEY:v1",
    issued_at: new Date().toISOString(),
    last_refresh_at: new Date().toISOString(),
  });

  if (tokenInsertError) {
    await supabaseAdmin.from("sage_connections").update({
      status: "error",
      last_error_code: "token_store_failed",
      last_error_message: tokenInsertError.message,
      updated_at: new Date().toISOString(),
    }).eq("id", connectionId);
    return finishRedirect(origin, { error: `Sage token storage failed: ${tokenInsertError.message}` });
  }

  await supabaseAdmin.from("sage_connections").update({
    status: "connected",
    connected_at: new Date().toISOString(),
    last_refresh_at: new Date().toISOString(),
    last_error_code: null,
    last_error_message: null,
    updated_at: new Date().toISOString(),
  }).eq("id", connectionId);

  const { data: businessRequestLog } = await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: connectionId,
    connection_event_type: "business_discovery",
    request_kind: "business_discovery",
    http_method: "GET",
    endpoint_path: "/businesses",
    request_payload_redacted: {},
  }).select("id").single();

  const businessResult = await fetchSageBusinesses(config.apiBaseUrl, tokenResult.raw.access_token);
  const businesses = businessResult.response.ok ? normalizeSageBusinesses(businessResult.raw) : [];

  await supabaseAdmin.from("sage_api_response_log").insert({
    request_log_id: businessRequestLog?.id,
    connection_id: connectionId,
    http_status: businessResult.response.status,
    success_yn: businessResult.response.ok,
    response_payload_redacted: { business_count: businesses.length },
    error_code: businessResult.response.ok ? null : "business_discovery_failed",
    error_message: businessResult.response.ok ? null : JSON.stringify(businessResult.raw).slice(0, 700),
  });

  if (businesses.length > 0) {
    for (let i = 0; i < businesses.length; i += 1) {
      await supabaseAdmin.from("sage_businesses").upsert({
        connection_id: connectionId,
        sage_business_id: businesses[i].sage_business_id,
        sage_business_name: businesses[i].sage_business_name,
        business_country_code: businesses[i].business_country_code,
        business_currency_code: businesses[i].business_currency_code,
        is_primary: i === 0,
        status: "active",
        selected_at: i === 0 ? new Date().toISOString() : null,
        raw_business_json: businesses[i].raw_business_json,
        updated_at: new Date().toISOString(),
      }, { onConflict: "connection_id,sage_business_id" });
    }
  }

  const response = finishRedirect(origin, {
    success: businesses.length > 0 ? `Sage connected. ${businesses.length} business record(s) discovered.` : "Sage connected. No businesses were discovered yet.",
  });
  response.cookies.set(SAGE_AUTH_STATE_COOKIE, "", { ...oauthCookieOptions(0), maxAge: 0 });
  response.cookies.set(SAGE_CONNECTION_COOKIE, "", { ...oauthCookieOptions(0), maxAge: 0 });
  return response;
}
