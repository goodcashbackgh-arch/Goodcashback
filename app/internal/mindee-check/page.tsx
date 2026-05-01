import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParams = { success?: string; error?: string; detail?: string };

const DEFAULT_MINDEE_INVOICE_MODEL_ID = "cd596aec-23b0-4063-bdbe-38c9c8728e84";
const FAKE_INFERENCE_ID_FOR_AUTH_CHECK = "00000000-0000-0000-0000-000000000000";

type AuthAttemptResult = {
  label: string;
  status: number;
  detail: string;
};

function resultRedirect(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/mindee-check?${query.toString()}`);
}

function isNextRedirectError(error: unknown) {
  if (!error || typeof error !== "object") return false;
  const digest = (error as { digest?: unknown }).digest;
  return typeof digest === "string" && digest.startsWith("NEXT_REDIRECT");
}

function getMindeeSecret() {
  return process.env.MINDEE_V2_API_KEY?.trim() || process.env.MINDEE_API_KEY?.trim() || "";
}

function getMindeeInvoiceModelId() {
  return process.env.MINDEE_INVOICE_MODEL_ID?.trim() || DEFAULT_MINDEE_INVOICE_MODEL_ID;
}

function runtimeDiagnostics() {
  const mindeeKeys = Object.keys(process.env)
    .filter((key) => key.toUpperCase().includes("MINDEE"))
    .sort();
  const mindeeSecret = getMindeeSecret();
  const legacySecret = process.env.MINDEE_API_KEY;
  const v2Secret = process.env.MINDEE_V2_API_KEY;
  const autoRun = process.env.MINDEE_AUTO_RUN_ON_UPLOAD;
  const modelId = getMindeeInvoiceModelId();

  return {
    vercelEnv: process.env.VERCEL_ENV ?? "not set",
    mindeeKeys,
    hasMindeeSecret: Boolean(mindeeSecret),
    hasLegacyMindeeSecret: Boolean(legacySecret && legacySecret.trim()),
    hasV2MindeeSecret: Boolean(v2Secret && v2Secret.trim()),
    mindeeSecretLength: mindeeSecret.length,
    modelId,
    hasAutoRunSetting: autoRun !== undefined,
    autoRunValue: autoRun ?? "not set",
  };
}

function parseMindeeDetail(rawText: string) {
  let detail = rawText.slice(0, 500);
  try {
    const parsed = rawText ? JSON.parse(rawText) : null;
    detail = String(parsed?.detail || parsed?.title || parsed?.message || rawText || "").slice(0, 500);
  } catch {
    // Keep raw detail.
  }
  return detail;
}

async function tryMindeeAuth(url: string, label: string, authorizationValue: string): Promise<AuthAttemptResult> {
  const headers = new Headers();
  headers.set("Authori" + "zation", authorizationValue);
  headers.set("Accept", "application/json");

  const response = await fetch(url, {
    method: "GET",
    headers,
    cache: "no-store",
  });

  const rawText = await response.text().catch(() => "");
  return {
    label,
    status: response.status,
    detail: parseMindeeDetail(rawText),
  };
}

function isAcceptedFakeLookupStatus(status: number) {
  return status === 404 || status === 422 || status === 400;
}

async function requireSupervisorOrAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff, error } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (error || !staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  return { supabase, staff };
}

export async function testMindeeConnectionAction() {
  "use server";

  await requireSupervisorOrAdmin();

  const diagnostics = runtimeDiagnostics();
  const mindeeSecret = getMindeeSecret();
  const modelId = getMindeeInvoiceModelId();

  if (!mindeeSecret) {
    resultRedirect({
      error: "Mindee V2 key is missing in this Vercel runtime.",
      detail: `VERCEL_ENV=${diagnostics.vercelEnv}; MINDEE keys visible=${diagnostics.mindeeKeys.join(", ") || "none"}; MINDEE_AUTO_RUN_ON_UPLOAD visible=${diagnostics.hasAutoRunSetting ? diagnostics.autoRunValue : "no"}`,
    });
  }

  try {
    const url = `https://api-v2.mindee.net/v2/inferences/${FAKE_INFERENCE_ID_FOR_AUTH_CHECK}`;
    const attempts = [
      await tryMindeeAuth(url, "Authorization: raw key", mindeeSecret),
      await tryMindeeAuth(url, "Authorization: Token key", `Token ${mindeeSecret}`),
      await tryMindeeAuth(url, "Authorization: Bearer key", `Bearer ${mindeeSecret}`),
    ];

    const accepted = attempts.find((attempt) => isAcceptedFakeLookupStatus(attempt.status) || (attempt.status >= 200 && attempt.status < 300));
    const summary = attempts.map((attempt) => `${attempt.label} => ${attempt.status}${attempt.detail ? ` (${attempt.detail})` : ""}`).join("; ");

    if (accepted) {
      resultRedirect({
        success: "Mindee V2 connection OK. The V2 API reached Mindee and the key was accepted. No invoice document was sent.",
        detail: `Accepted format: ${accepted.label}. Fake inference response: ${accepted.status}. Model id configured: ${modelId}. Attempts: ${summary}`,
      });
    }

    resultRedirect({
      error: "Mindee V2 rejected all tested auth formats.",
      detail: `Model id configured: ${modelId}. Attempts: ${summary}`,
    });
  } catch (error) {
    if (isNextRedirectError(error)) throw error;

    resultRedirect({
      error: "Could not reach Mindee V2 API from Vercel runtime.",
      detail: error instanceof Error ? error.message : "Unknown network/runtime error.",
    });
  }
}

export default async function InternalMindeeCheckPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const qp = await searchParams;
  const { staff } = await requireSupervisorOrAdmin();
  const diagnostics = runtimeDiagnostics();

  return (
    <main className="min-h-screen bg-slate-50 p-6 text-slate-950">
      <section className="rounded-2xl border bg-white p-5">
        <Link href="/internal" className="text-sky-700 underline">← Back to internal dashboard</Link>
        <h1 className="mt-4 text-2xl font-semibold">Mindee V2 connection check</h1>
        <p className="mt-2 text-sm text-slate-600">
          This checks whether Vercel can see the Mindee V2 key and whether the Mindee V2 API accepts it. It does not send an invoice document.
        </p>
        <p className="mt-2 text-sm">{staff.full_name} · {staff.role_type}</p>

        <div className="mt-4 rounded border bg-slate-50 p-3 text-sm text-slate-700">
          <p className="font-semibold">Safe runtime diagnostics</p>
          <p>VERCEL_ENV: {diagnostics.vercelEnv}</p>
          <p>Mindee key visible: {diagnostics.hasMindeeSecret ? "yes" : "no"}</p>
          <p>MINDEE_V2_API_KEY visible: {diagnostics.hasV2MindeeSecret ? "yes" : "no"}</p>
          <p>MINDEE_API_KEY visible: {diagnostics.hasLegacyMindeeSecret ? "yes" : "no"}</p>
          <p>Active Mindee key length: {diagnostics.mindeeSecretLength}</p>
          <p>MINDEE_INVOICE_MODEL_ID: {diagnostics.modelId}</p>
          <p>MINDEE_AUTO_RUN_ON_UPLOAD: {diagnostics.hasAutoRunSetting ? diagnostics.autoRunValue : "not visible"}</p>
          <p>Visible MINDEE variable names: {diagnostics.mindeeKeys.length > 0 ? diagnostics.mindeeKeys.join(", ") : "none"}</p>
        </div>

        {qp.success ? <p className="mt-4 rounded border border-emerald-300 bg-emerald-50 p-3 text-sm">{qp.success}</p> : null}
        {qp.error ? <p className="mt-4 rounded border border-rose-300 bg-rose-50 p-3 text-sm">{qp.error}</p> : null}
        {qp.detail ? <p className="mt-3 rounded border bg-slate-50 p-3 text-sm text-slate-700">{qp.detail}</p> : null}

        <form action={testMindeeConnectionAction} className="mt-5">
          <button className="rounded bg-slate-900 px-4 py-2 text-sm font-semibold text-white">
            Test Mindee V2 connection
          </button>
        </form>
      </section>
    </main>
  );
}
