import crypto from "node:crypto";

export const SAGE_AUTH_STATE_COOKIE = "sage_oauth_state";
export const SAGE_CONNECTION_COOKIE = "sage_connection_id";

export type SageTokenResponse = {
  access_token?: string;
  refresh_token?: string;
  token_type?: string;
  expires_in?: number;
  scope?: string;
  scopes?: string[];
  [key: string]: unknown;
};

export function sageOAuthConfig(origin?: string) {
  const clientId = process.env.SAGE_CLIENT_ID?.trim() || "";
  const clientSecret = process.env.SAGE_CLIENT_SECRET?.trim() || "";
  const authorizationUrl = process.env.SAGE_AUTHORIZATION_URL?.trim() || "https://www.sageone.com/oauth2/auth/central";
  const tokenUrl = process.env.SAGE_TOKEN_URL?.trim() || "https://oauth.accounting.sage.com/token";
  const apiBaseUrl = process.env.SAGE_API_BASE_URL?.trim() || "https://api.accounting.sage.com/v3.1";
  const redirectUri = process.env.SAGE_REDIRECT_URI?.trim() || (origin ? `${origin}/api/sage/oauth/callback` : "");
  const scopes = process.env.SAGE_SCOPES?.trim() || "full_access";

  return { clientId, clientSecret, authorizationUrl, tokenUrl, apiBaseUrl, redirectUri, scopes };
}

export function assertSageOAuthConfigured(origin?: string) {
  const config = sageOAuthConfig(origin);
  const missing = [];
  if (!config.clientId) missing.push("SAGE_CLIENT_ID");
  if (!config.clientSecret) missing.push("SAGE_CLIENT_SECRET");
  if (!config.redirectUri) missing.push("SAGE_REDIRECT_URI or request origin");
  if (!process.env.SAGE_TOKEN_ENCRYPTION_KEY?.trim()) missing.push("SAGE_TOKEN_ENCRYPTION_KEY");
  if (missing.length > 0) {
    throw new Error(`Sage OAuth is not configured. Missing: ${missing.join(", ")}.`);
  }
  return config;
}

export function randomOAuthState() {
  return crypto.randomBytes(32).toString("base64url");
}

export function sha256Hex(value: string) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function encryptionKey() {
  const raw = process.env.SAGE_TOKEN_ENCRYPTION_KEY?.trim() || "";
  if (!raw) throw new Error("SAGE_TOKEN_ENCRYPTION_KEY is not configured.");
  return crypto.createHash("sha256").update(raw).digest();
}

export function encryptSecret(plainText: string) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", encryptionKey(), iv);
  const encrypted = Buffer.concat([cipher.update(plainText, "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1:${iv.toString("base64url")}:${tag.toString("base64url")}:${encrypted.toString("base64url")}`;
}

export function decryptSecret(encryptedValue: string) {
  const [version, ivRaw, tagRaw, dataRaw] = encryptedValue.split(":");
  if (version !== "v1" || !ivRaw || !tagRaw || !dataRaw) throw new Error("Unsupported encrypted secret format.");
  const decipher = crypto.createDecipheriv("aes-256-gcm", encryptionKey(), Buffer.from(ivRaw, "base64url"));
  decipher.setAuthTag(Buffer.from(tagRaw, "base64url"));
  const plain = Buffer.concat([decipher.update(Buffer.from(dataRaw, "base64url")), decipher.final()]);
  return plain.toString("utf8");
}

export function tokenExpiresAt(expiresIn: unknown) {
  const seconds = typeof expiresIn === "number" && Number.isFinite(expiresIn) ? expiresIn : Number(expiresIn);
  const safeSeconds = Number.isFinite(seconds) && seconds > 0 ? seconds : 3600;
  return new Date(Date.now() + safeSeconds * 1000).toISOString();
}

export function scopesFromToken(token: SageTokenResponse, requestedScopes: string) {
  if (Array.isArray(token.scopes)) return token.scopes.map(String);
  if (typeof token.scope === "string" && token.scope.trim()) return token.scope.trim().split(/\s+/);
  return requestedScopes.split(/\s+/).filter(Boolean);
}

export async function exchangeSageToken(params: {
  tokenUrl: string;
  clientId: string;
  clientSecret: string;
  grantType: "authorization_code" | "refresh_token";
  code?: string;
  refreshToken?: string;
  redirectUri?: string;
}) {
  const body = new URLSearchParams();
  body.set("grant_type", params.grantType);
  body.set("client_id", params.clientId);
  body.set("client_secret", params.clientSecret);
  if (params.grantType === "authorization_code") {
    if (!params.code) throw new Error("Sage authorization code is missing.");
    if (!params.redirectUri) throw new Error("Sage redirect URI is missing.");
    body.set("code", params.code);
    body.set("redirect_uri", params.redirectUri);
  } else {
    if (!params.refreshToken) throw new Error("Sage refresh token is missing.");
    body.set("refresh_token", params.refreshToken);
  }

  const response = await fetch(params.tokenUrl, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
    cache: "no-store",
  });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  return { response, raw: raw as SageTokenResponse };
}

export async function fetchSageBusinesses(apiBaseUrl: string, accessToken: string) {
  const response = await fetch(`${apiBaseUrl.replace(/\/$/, "")}/businesses`, {
    method: "GET",
    headers: { Accept: "application/json", Authorization: `Bearer ${accessToken}` },
    cache: "no-store",
  });
  const raw = await response.json().catch(async () => ({ non_json_body: await response.text().catch(() => null) }));
  return { response, raw };
}

export function normalizeSageBusinesses(raw: unknown) {
  const root = raw && typeof raw === "object" ? raw as Record<string, unknown> : {};
  const candidates = [root.$items, root.items, root.businesses, root.data, raw];
  const array = candidates.find(Array.isArray) as unknown[] | undefined;
  return (array ?? []).map((item) => {
    const row = item && typeof item === "object" ? item as Record<string, unknown> : {};
    const id = String(row.id ?? row.business_id ?? row.sage_business_id ?? "").trim();
    const name = String(row.name ?? row.displayed_as ?? row.business_name ?? id).trim();
    return {
      sage_business_id: id,
      sage_business_name: name || id,
      business_country_code: row.country_id ? String(row.country_id) : null,
      business_currency_code: row.base_currency ? String(row.base_currency) : row.currency ? String(row.currency) : null,
      raw_business_json: row,
    };
  }).filter((row) => row.sage_business_id && row.sage_business_name);
}

export function oauthCookieOptions(maxAgeSeconds = 600) {
  return {
    httpOnly: true,
    secure: true,
    sameSite: "lax" as const,
    path: "/",
    maxAge: maxAgeSeconds,
  };
}

export function clearOauthCookieOptions() {
  return {
    httpOnly: true,
    secure: true,
    sameSite: "lax" as const,
    path: "/",
    maxAge: 0,
  };
}

export function redactedTokenPayload(token: SageTokenResponse) {
  return {
    token_type: token.token_type ?? null,
    expires_in: token.expires_in ?? null,
    scope: token.scope ?? null,
    scopes: token.scopes ?? null,
    has_access_token: Boolean(token.access_token),
    has_refresh_token: Boolean(token.refresh_token),
  };
}
