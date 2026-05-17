import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function healthTone(status: unknown, health: unknown): Tone {
  const rawStatus = text(status);
  const rawHealth = text(health);
  if (rawStatus === "connected" && rawHealth === "healthy") return "complete";
  if (["pending_oauth", "token_expired"].includes(rawStatus) || ["expires_soon", "no_active_token"].includes(rawHealth)) return "action";
  if (["refresh_failed", "revoked", "disabled", "error"].includes(rawStatus) || rawHealth === "expired") return "blocked";
  return "review";
}

function envStatus() {
  return {
    clientId: Boolean(process.env.SAGE_CLIENT_ID?.trim()),
    clientSecret: Boolean(process.env.SAGE_CLIENT_SECRET?.trim()),
    tokenKey: Boolean(process.env.SAGE_TOKEN_ENCRYPTION_KEY?.trim()),
    redirectUri: Boolean(process.env.SAGE_REDIRECT_URI?.trim()),
  };
}

function EnvChip({ label, ok }: { label: string; ok: boolean }) {
  return <span className={`rounded-full border px-2 py-1 text-[10px] font-bold ${ok ? "border-emerald-200 bg-emerald-50 text-emerald-800" : "border-amber-200 bg-amber-50 text-amber-800"}`}>{label}: {ok ? "set" : "missing"}</span>;
}

function ConnectionCard({ row }: { row: Row }) {
  const tone = healthTone(row.connection_status, row.token_health);
  const connectionId = text(row.connection_id);
  return (
    <div className={`rounded-2xl border p-3 ${toneClass(tone)}`}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{pretty(row.connection_ref)}</p>
          <p className="mt-1 text-sm font-extrabold">{pretty(row.connection_status)} · {pretty(row.token_health)}</p>
        </div>
        <span className="rounded-full border bg-white/70 px-2 py-1 text-[10px] font-bold">{pretty(row.environment)}</span>
      </div>
      <div className="mt-2 grid gap-1 text-xs leading-5 opacity-90 sm:grid-cols-2 lg:grid-cols-4">
        <p><span className="font-bold">Business:</span> {text(row.primary_sage_business_name) || "—"}</p>
        <p><span className="font-bold">Businesses:</span> {text(row.sage_business_count) || "0"}</p>
        <p><span className="font-bold">Expires:</span> {text(row.token_expires_at) || "—"}</p>
        <p><span className="font-bold">Last refresh:</span> {text(row.last_refresh_at) || "—"}</p>
      </div>
      {text(row.last_error_message) ? <p className="mt-2 rounded-xl border border-rose-200 bg-white/70 px-3 py-2 text-xs font-semibold text-rose-800">{text(row.last_error_code)}: {text(row.last_error_message)}</p> : null}
      <div className="mt-3 flex flex-wrap gap-2">
        <Link href="/api/sage/oauth/start" className="rounded-lg bg-violet-700 px-3 py-1.5 text-xs font-bold text-white hover:bg-violet-800">Reconnect / replace</Link>
        {connectionId ? <Link href={`/api/sage/oauth/refresh?connection_id=${connectionId}`} className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-xs font-bold text-slate-800 hover:bg-slate-50">Refresh token diagnostic</Link> : null}
      </div>
    </div>
  );
}

export default async function SageConnectionPanel() {
  const supabase = await createClient();
  const { data, error } = await (supabase as any).rpc("internal_sage_connection_status_v1");
  const rows = ((data ?? []) as Row[]);
  const env = envStatus();
  const envReady = env.clientId && env.clientSecret && env.tokenKey;

  return (
    <section className="rounded-3xl border border-violet-200 bg-white p-4 shadow-sm">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.22em] text-violet-600">Sage connection/settings</p>
          <h2 className="mt-1 text-xl font-semibold">OAuth connection foundation</h2>
          <p className="mt-1 max-w-4xl text-sm leading-6 text-slate-600">Phase 6 connection control only. Tokens are stored encrypted server-side. No browser-to-Sage calls and no live Sage posting exists here.</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <EnvChip label="Client ID" ok={env.clientId} />
          <EnvChip label="Client secret" ok={env.clientSecret} />
          <EnvChip label="Token key" ok={env.tokenKey} />
          <EnvChip label="Redirect URI" ok={env.redirectUri} />
        </div>
      </div>

      {error ? <p className="mt-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Sage status RPC unavailable: {error.message}. Confirm the Phase 5 migration was run.</p> : null}

      <div className="mt-4 grid gap-3">
        {rows.length > 0 ? rows.map((row) => <ConnectionCard key={text(row.connection_id)} row={row} />) : (
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
            <p className="font-bold text-slate-950">No Sage connection recorded yet.</p>
            <p className="mt-1 leading-6">Start OAuth only after the Sage app redirect URI and Vercel environment variables are configured.</p>
          </div>
        )}
      </div>

      <div className="mt-4 flex flex-wrap items-center gap-2">
        <Link href="/api/sage/oauth/start" className={`rounded-xl px-4 py-2 text-sm font-bold text-white ${envReady ? "bg-violet-700 hover:bg-violet-800" : "bg-slate-400"}`}>{rows.length > 0 ? "Start replacement OAuth" : "Start Sage OAuth"}</Link>
        {!envReady ? <p className="text-xs font-semibold text-amber-700">OAuth will fail until Client ID, Client secret and token encryption key are set in Vercel.</p> : null}
      </div>
    </section>
  );
}
