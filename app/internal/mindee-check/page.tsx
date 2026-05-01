import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParams = { success?: string; error?: string; detail?: string };

function resultRedirect(params: Record<string, string>): never {
  const query = new URLSearchParams(params);
  redirect(`/internal/mindee-check?${query.toString()}`);
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

  const apiKey = process.env.MINDEE_API_KEY;
  if (!apiKey) {
    resultRedirect({ error: "MINDEE_API_KEY is missing in this Vercel runtime." });
  }

  const endpoint = process.env.MINDEE_INVOICE_API_URL || "https://api.mindee.net/v1/products/mindee/invoices/v4/predict";

  try {
    const emptyForm = new FormData();
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Token ${apiKey}`,
      },
      body: emptyForm,
    });

    const rawText = await response.text().catch(() => "");
    let detail = rawText.slice(0, 500);
    try {
      const parsed = rawText ? JSON.parse(rawText) : null;
      const apiError = parsed?.api_request?.error;
      const message = apiError?.message || apiError?.details || parsed?.message || parsed?.detail;
      if (message) detail = String(message).slice(0, 500);
    } catch {
      // Keep raw detail.
    }

    if (response.status === 401 || response.status === 403) {
      resultRedirect({
        error: `Mindee rejected the API key (${response.status}).`,
        detail: detail || "Check the key was copied correctly and saved in Vercel Production environment variables.",
      });
    }

    if (response.status === 404) {
      resultRedirect({
        error: "Mindee endpoint was not found.",
        detail: endpoint,
      });
    }

    if (response.status === 400 || response.status === 422) {
      resultRedirect({
        success: "Mindee connection OK. The app reached Mindee and the key was accepted. No invoice document was sent.",
        detail: detail || `Mindee returned expected no-document validation (${response.status}).`,
      });
    }

    if (response.ok) {
      resultRedirect({
        success: "Mindee connection OK. The app reached Mindee and the key was accepted.",
        detail: `Unexpected success status ${response.status}. No invoice document was sent.`,
      });
    }

    resultRedirect({
      error: `Mindee connection returned unexpected status ${response.status}.`,
      detail: detail || endpoint,
    });
  } catch (error) {
    resultRedirect({
      error: "Could not reach Mindee from Vercel runtime.",
      detail: error instanceof Error ? error.message : "Unknown network/runtime error.",
    });
  }
}

export default async function InternalMindeeCheckPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const qp = await searchParams;
  const { staff } = await requireSupervisorOrAdmin();

  return (
    <main className="min-h-screen bg-slate-50 p-6 text-slate-950">
      <section className="rounded-2xl border bg-white p-5">
        <Link href="/internal" className="text-sky-700 underline">← Back to internal dashboard</Link>
        <h1 className="mt-4 text-2xl font-semibold">Mindee connection check</h1>
        <p className="mt-2 text-sm text-slate-600">
          This checks whether Vercel can see MINDEE_API_KEY and whether Mindee accepts the key. It does not send an invoice document.
        </p>
        <p className="mt-2 text-sm">{staff.full_name} · {staff.role_type}</p>

        {qp.success ? <p className="mt-4 rounded border border-emerald-300 bg-emerald-50 p-3 text-sm">{qp.success}</p> : null}
        {qp.error ? <p className="mt-4 rounded border border-rose-300 bg-rose-50 p-3 text-sm">{qp.error}</p> : null}
        {qp.detail ? <p className="mt-3 rounded border bg-slate-50 p-3 text-sm text-slate-700">{qp.detail}</p> : null}

        <form action={testMindeeConnectionAction} className="mt-5">
          <button className="rounded bg-slate-900 px-4 py-2 text-sm font-semibold text-white">
            Test Mindee connection
          </button>
        </form>
      </section>
    </main>
  );
}
