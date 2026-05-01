import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParams = { success?: string; error?: string; detail?: string };

type MindeeSdkModule = {
  ClientV2?: new (options: Record<string, string>) => {
    getInference?: (inferenceId: string) => Promise<unknown>;
  };
};

const DEFAULT_MINDEE_INVOICE_MODEL_ID = "cd596aec-23b0-4063-bdbe-38c9c8728e84";
const FAKE_INFERENCE_ID_FOR_AUTH_CHECK = "00000000-0000-0000-0000-000000000000";

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

function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  try {
    return JSON.stringify(error);
  } catch {
    return "Unknown error";
  }
}

function errorStatus(error: unknown) {
  if (!error || typeof error !== "object") return null;
  const obj = error as {
    status?: unknown;
    statusCode?: unknown;
    httpStatus?: unknown;
    response?: { status?: unknown; statusCode?: unknown };
  };
  return obj.status ?? obj.statusCode ?? obj.httpStatus ?? obj.response?.status ?? obj.response?.statusCode ?? null;
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
    const mindeeModule = (await import("mindee")) as MindeeSdkModule;
    const ClientV2 = mindeeModule.ClientV2;

    if (!ClientV2) {
      resultRedirect({
        error: "Mindee SDK loaded, but ClientV2 was not found.",
        detail: "The installed mindee package does not expose ClientV2 in the expected location.",
      });
    }

    const clientOptions = { apiKey: mindeeSecret };
    const mindeeClient = new ClientV2(clientOptions);

    if (typeof mindeeClient.getInference !== "function") {
      resultRedirect({
        error: "Mindee ClientV2 loaded, but getInference was not found.",
        detail: "The SDK method name differs from the current implementation. No invoice document was sent.",
      });
    }

    await mindeeClient.getInference(FAKE_INFERENCE_ID_FOR_AUTH_CHECK);

    resultRedirect({
      success: "Mindee V2 connection OK. The SDK authenticated successfully. No invoice document was sent.",
      detail: `Model id configured: ${modelId}. Fake inference lookup unexpectedly returned successfully, but no page was consumed.`,
    });
  } catch (error) {
    if (isNextRedirectError(error)) throw error;

    const status = errorStatus(error);
    const message = errorMessage(error).slice(0, 700);
    const lower = message.toLowerCase();

    if (
      status === 401 ||
      status === 403 ||
      lower.includes("401") ||
      lower.includes("403") ||
      lower.includes("authorization") ||
      lower.includes("unauthorized") ||
      lower.includes("forbidden")
    ) {
      resultRedirect({
        error: `Mindee V2 rejected the key${status ? ` (${status})` : ""}.`,
        detail: message || "Check the key belongs to the same app.mindee.com organisation.",
      });
    }

    if (
      status === 404 ||
      lower.includes("404") ||
      lower.includes("not found") ||
      lower.includes("does not exist")
    ) {
      resultRedirect({
        success: "Mindee V2 connection OK. The SDK reached Mindee and the key was accepted. No invoice document was sent.",
        detail: `Expected fake inference lookup failure. Model id configured: ${modelId}. Detail: ${message}`,
      });
    }

    resultRedirect({
      error: "Mindee V2 SDK connection returned an unexpected result.",
      detail: `Status=${String(status ?? "unknown")}; Detail=${message}`,
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
          This checks whether Vercel can see the Mindee V2 key and whether the Mindee V2 SDK accepts it. It does not send an invoice document.
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
