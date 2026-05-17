import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";
import { supabaseAdmin } from "@/lib/supabase/admin";
import {
  assertSageOAuthConfigured,
  oauthCookieOptions,
  randomOAuthState,
  SAGE_AUTH_STATE_COOKIE,
  SAGE_CONNECTION_COOKIE,
  sha256Hex,
} from "@/lib/sage/oauth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

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

export async function GET(request: Request) {
  const origin = new URL(request.url).origin;
  const user = await requireAccountingUser();
  if (!user.ok) return NextResponse.redirect(new URL(`/internal/accounting-command-centre?error=${encodeURIComponent(user.error)}`, origin));

  let config: ReturnType<typeof assertSageOAuthConfigured>;
  try {
    config = assertSageOAuthConfigured(origin);
  } catch (error) {
    return NextResponse.redirect(new URL(`/internal/accounting-command-centre?error=${encodeURIComponent(error instanceof Error ? error.message : "Sage OAuth is not configured.")}`, origin));
  }

  const { data: connection, error: connectionError } = await supabaseAdmin
    .from("sage_connections")
    .insert({
      provider: "sage_cloud_accounting",
      environment: process.env.SAGE_ENVIRONMENT?.trim() || "production",
      status: "pending_oauth",
      connected_by_staff_id: user.staffId,
      metadata_json: {
        oauth_started_at: new Date().toISOString(),
        redirect_uri: config.redirectUri,
      },
    })
    .select("id")
    .single();

  if (connectionError || !connection?.id) {
    return NextResponse.redirect(new URL(`/internal/accounting-command-centre?error=${encodeURIComponent(connectionError?.message || "Could not create Sage connection record.")}`, origin));
  }

  const state = randomOAuthState();
  await supabaseAdmin.from("sage_api_request_log").insert({
    connection_id: connection.id,
    connection_event_type: "oauth_start",
    request_kind: "oauth",
    http_method: "GET",
    endpoint_path: "/oauth2/auth/central",
    request_payload_redacted: {
      response_type: "code",
      client_id_hash: sha256Hex(config.clientId).slice(0, 16),
      redirect_uri: config.redirectUri,
      scope: config.scopes,
      state_hash: sha256Hex(state).slice(0, 16),
    },
    created_by_staff_id: user.staffId,
  });

  const sageUrl = new URL(config.authorizationUrl);
  sageUrl.searchParams.set("response_type", "code");
  sageUrl.searchParams.set("client_id", config.clientId);
  sageUrl.searchParams.set("redirect_uri", config.redirectUri);
  sageUrl.searchParams.set("scope", config.scopes);
  sageUrl.searchParams.set("state", state);

  const response = NextResponse.redirect(sageUrl);
  response.cookies.set(SAGE_AUTH_STATE_COOKIE, state, oauthCookieOptions());
  response.cookies.set(SAGE_CONNECTION_COOKIE, connection.id, oauthCookieOptions());
  return response;
}
