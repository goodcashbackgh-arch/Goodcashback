import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 64) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function asObject(value: unknown): Row {
  if (value && typeof value === "object" && !Array.isArray(value)) return value as Row;
  return {};
}

function asArray(value: unknown): Row[] {
  if (!Array.isArray(value)) return [];
  return value.filter((entry) => entry && typeof entry === "object" && !Array.isArray(entry)) as Row[];
}

function firstText(...values: unknown[]) {
  for (const value of values) {
    const candidate = text(value);
    if (candidate) return candidate;
  }
  return "";
}

function jsonString(value: unknown) {
  try {
    return JSON.stringify(value ?? null, null, 2);
  } catch {
    return String(value ?? "");
  }
}

function statusTone(status: unknown): Tone {
  const raw = text(status);
  if (["ready_to_post", "ok_to_post", "posted", "sage_confirmation_recorded", "ready_for_sage_posting_preview"].includes(raw)) return "complete";
  if (["requires_revalidation", "not_revalidated", "not_posted", "frozen_pending_posting"].includes(raw)) return "action";
  if (["blocked_before_posting", "stale_reapproval_required", "blocked_source_not_ready", "posting_failed"].includes(raw)) return "blocked";
  if (["warning_only", "approved_frozen"].includes(raw)) return "review";
  return "muted";
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function accessFromPermissions(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const permissions = value as Row;
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

function mappingEntries(mappingSnapshot: unknown) {
  return Object.entries(asObject(mappingSnapshot)).map(([code, raw]) => ({ code, value: asObject(raw) }));
}

function Field({ label, value, mono = false }: { label: string; value: unknown; mono?: boolean }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3">
      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">{label}</p>
      <p className={`mt-1 break-words text-sm font-semibold text-slate-950 ${mono ? "font-mono" : ""}`}>{text(value) || "—"}</p>
    </div>
  );
}

function StatusPill({ label, value }: { label: string; value: unknown }) {
  return <span className={`inline-flex rounded-full border px-3 py-1 text-xs font-bold ${toneClass(statusTone(value))}`}>{label}: {pretty(value)}</span>;
}

function JsonBlock({ title, value }: { title: string; value: unknown }) {
  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="text-xl font-bold tracking-tight">{title}</h2>
      <pre className="mt-4 max-h-[520px] overflow-auto rounded-2xl bg-slate-950 p-4 text-xs leading-5 text-slate-50">{jsonString(value)}</pre>
    </section>
  );
}

function LineCard({ line, index }: { line: Row; index: number }) {
  const quantity = firstText(line.quantity, line.qty, line.released_qty) || "1";
  const unitPrice = firstText(line.unit_price_gbp, line.unit_price, line.price_gbp);
  const lineTotal = firstText(line.total_line_amount_gbp, line.amount_gbp, line.total_amount_gbp, line.customer_charge_amount_gbp);
  const ledger = firstText(line.sage_ledger_account_id, line.resolved_ledger_account_id, line.ledger_account_id);
  const taxRate = firstText(line.sage_tax_rate_id, line.resolved_tax_rate_id, line.tax_rate_id);

  return (
    <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Line {index + 1}</p>
          <h3 className="mt-1 text-base font-extrabold text-slate-950">{firstText(line.description, line.item_description, line.name) || "Posting line"}</h3>
        </div>
        <span className="rounded-full bg-white px-3 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">{gbp(lineTotal)}</span>
      </div>
      <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <Field label="Qty" value={quantity} />
        <Field label="Unit price" value={unitPrice ? gbp(unitPrice) : "—"} />
        <Field label="Line total" value={lineTotal ? gbp(lineTotal) : "—"} />
        <Field label="Ledger" value={ledger || "—"} mono />
        <Field label="Tax rate" value={taxRate || "—"} mono />
      </div>
    </div>
  );
}

export default async function FrozenSnapshotPreviewPage({
  params,
}: {
  params: Promise<{ snapshot_id: string }>;
}) {
  const { snapshot_id: snapshotId } = await params;

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);
  if (!canAccess) redirect("/internal/accounting-command-centre");

  const [queueResult, detailResult] = await Promise.all([
    (supabase as any).rpc("internal_sage_posting_snapshot_queue_v1"),
    supabase
      .from("sage_posting_snapshots")
      .select("id, commercial_payload, mapping_semantic_fingerprint, payload_semantic_fingerprint, sage_status_at_freeze, created_at, created_by_staff_id, created_by_auth_user_id, last_posting_error, posting_attempt_count")
      .eq("id", snapshotId)
      .maybeSingle(),
  ]);

  if (queueResult.error) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-4xl rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-900">
          Snapshot queue unavailable: {queueResult.error.message}
        </div>
      </main>
    );
  }

  const snapshot = ((queueResult.data ?? []) as Row[]).find((row) => text(row.snapshot_id) === snapshotId);
  if (!snapshot) notFound();

  const detail = (detailResult.data ?? {}) as Row;
  const resolvedPayload = asObject(snapshot.resolved_payload);
  const commercialPayload = detail.commercial_payload ?? resolvedPayload.commercial_payload ?? {};
  const mappingSnapshot = snapshot.mapping_snapshot ?? resolvedPayload.mapping_snapshot ?? resolvedPayload.resolved_mappings ?? {};
  const header = asObject(resolvedPayload.sage_header);
  const customerTarget = asObject(resolvedPayload.customer_target);
  const lines = asArray(resolvedPayload.resolved_lines);
  const taxResolution = asObject(resolvedPayload.tax_resolution);
  const ledgerResolution = asObject(resolvedPayload.ledger_resolution);
  const freezeControl = asObject(resolvedPayload.freeze_control);
  const resolverControl = asObject(resolvedPayload.resolver_control);
  const isReadyToPost = text(snapshot.posting_gate_status) === "ready_to_post";

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/accounting-command-centre">← Accounting command centre</Link>
            <Link href="/internal/sage-ready">Live Sage queue</Link>
            <Link href="/internal/sage-mapping">Mappings</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Frozen Sage posting preview</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">{text(snapshot.order_ref) || text(snapshot.reference_text) || short(snapshot.snapshot_id)}</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
                Final accounting preview of the approved frozen snapshot. This page reads the frozen payload and mapping snapshot that would feed the later Sage adapter. It does not post to Sage.
              </p>
            </div>
            <div className={`rounded-2xl border p-4 ${toneClass(statusTone(snapshot.posting_gate_status))}`}>
              <p className="text-xs font-bold uppercase tracking-wide opacity-70">Posting gate</p>
              <p className="mt-1 text-2xl font-extrabold">{pretty(snapshot.posting_gate_status)}</p>
              <p className="mt-1 text-xs leading-5 opacity-90">{text(snapshot.posting_gate_blocker) || "No blocker"}</p>
            </div>
          </div>
          <div className="mt-4 flex flex-wrap gap-2">
            <StatusPill label="Approval" value={snapshot.approval_status} />
            <StatusPill label="Revalidation" value={snapshot.revalidation_status} />
            <StatusPill label="Posting" value={snapshot.sage_posting_status} />
            <StatusPill label="Lane" value={snapshot.document_lane} />
            <StatusPill label="Document" value={snapshot.document_type} />
          </div>
          {detailResult.error ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Snapshot table detail unavailable: {detailResult.error.message}. Showing queue snapshot only.</p>
          ) : null}
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <Field label="Counterparty/contact target" value={firstText(customerTarget.display_name, snapshot.counterparty_name)} />
          <Field label="Amount" value={`${gbp(snapshot.amount_gbp)} ${text(snapshot.currency_code) || "GBP"}`} />
          <Field label="Reference" value={firstText(header.reference, snapshot.reference_text)} mono />
          <Field label="Idempotency key" value={snapshot.idempotency_key} mono />
          <Field label="Batch" value={snapshot.batch_ref} mono />
          <Field label="Source" value={`${text(snapshot.source_table)} / ${text(snapshot.source_id)}`} mono />
          <Field label="Approved at" value={text(snapshot.approved_at).slice(0, 19).replace("T", " ")} />
          <Field label="Revalidated at" value={text(snapshot.revalidated_at) ? text(snapshot.revalidated_at).slice(0, 19).replace("T", " ") : "Not revalidated"} />
        </section>

        <section className={`rounded-3xl border p-5 shadow-sm ${isReadyToPost ? "border-emerald-200 bg-emerald-50 text-emerald-950" : "border-amber-200 bg-amber-50 text-amber-950"}`}>
          <h2 className="text-xl font-bold tracking-tight">Posting decision</h2>
          <p className="mt-2 text-sm leading-6">
            {isReadyToPost
              ? "This frozen snapshot is currently ready for the future Sage posting action. Posting remains disabled until the idempotent Sage adapter is built."
              : "This frozen snapshot is not posting-safe. Resolve the blocker or re-approve a refreshed snapshot before any future Sage post is allowed."}
          </p>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-bold tracking-tight">Sage header preview</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            <Field label="Sage document type" value={firstText(resolvedPayload.sage_document_type, snapshot.document_type)} />
            <Field label="Reference" value={firstText(header.reference, snapshot.reference_text)} mono />
            <Field label="Notes" value={firstText(header.notes, snapshot.notes_text)} />
            <Field label="Currency" value={firstText(header.currency_code, snapshot.currency_code, "GBP")} />
            <Field label="Order ref" value={firstText(resolvedPayload.source_order_ref, header.order_ref, snapshot.order_ref)} mono />
            <Field label="Booking ref" value={firstText(header.booking_ref, snapshot.booking_ref)} mono />
            <Field label="Tax rate" value={firstText(taxResolution.sage_tax_rate_id, mappingSnapshot && asObject(mappingSnapshot).ZERO_RATED_EXPORT_TAX_RATE && asObject(asObject(mappingSnapshot).ZERO_RATED_EXPORT_TAX_RATE).sage_external_id)} mono />
            <Field label="Ledger account" value={firstText(ledgerResolution.sage_ledger_account_id)} mono />
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-bold tracking-tight">Resolved posting lines</h2>
          {lines.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">No resolved lines found in the frozen payload. Do not post until the resolver emits line-level payloads.</p>
          ) : (
            <div className="mt-4 space-y-3">{lines.map((line, index) => <LineCard key={`${index}-${text(line.description)}`} line={line} index={index} />)}</div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-bold tracking-tight">Frozen Sage mappings</h2>
          <p className="mt-2 text-sm leading-6 text-slate-600">These are the mapping values captured at freeze approval. Later mapping changes must create drift/reapproval rather than silently changing this posting snapshot.</p>
          <div className="mt-4 grid gap-3 lg:grid-cols-2">
            {mappingEntries(mappingSnapshot).length === 0 ? (
              <p className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">No mapping snapshot found.</p>
            ) : mappingEntries(mappingSnapshot).map((entry) => (
              <div key={entry.code} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="text-xs font-bold uppercase tracking-wide text-slate-500">{entry.code}</p>
                <p className="mt-1 text-lg font-extrabold text-slate-950">{firstText(entry.value.sage_display_name, entry.value.display_name, "Unnamed mapping")}</p>
                <div className="mt-3 grid gap-3 sm:grid-cols-2">
                  <Field label="Sage ID" value={entry.value.sage_external_id} mono />
                  <Field label="Configured at" value={entry.value.configured_at ? text(entry.value.configured_at).slice(0, 19).replace("T", " ") : "—"} />
                </div>
              </div>
            ))}
          </div>
        </section>

        <section className="grid gap-4 lg:grid-cols-2">
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 className="text-xl font-bold tracking-tight">Snapshot audit</h2>
            <div className="mt-4 grid gap-3">
              <Field label="Mapping fingerprint" value={detail.mapping_semantic_fingerprint ?? "—"} mono />
              <Field label="Payload fingerprint" value={detail.payload_semantic_fingerprint ?? "—"} mono />
              <Field label="Posting attempts" value={detail.posting_attempt_count ?? "0"} />
              <Field label="Last posting error" value={detail.last_posting_error ?? "—"} />
              <Field label="Snapshot created" value={text(detail.created_at) ? text(detail.created_at).slice(0, 19).replace("T", " ") : "—"} />
            </div>
          </section>

          <section className="rounded-3xl border border-violet-200 bg-violet-50 p-5 text-sm leading-6 text-violet-900 shadow-sm">
            <h2 className="text-xl font-bold tracking-tight">Control rule</h2>
            <p className="mt-2">This page is a posting preview, not a posting action. A future Sage adapter must use this snapshot id and idempotency key, then record the Sage document id only after Sage confirms creation.</p>
            <p className="mt-3 font-semibold">No edits are made here. Corrections after posting must use a correction route, not silent mutation.</p>
          </section>
        </section>

        <JsonBlock title="Resolved payload JSON" value={resolvedPayload} />
        <JsonBlock title="Commercial payload JSON" value={commercialPayload} />
        <JsonBlock title="Mapping snapshot JSON" value={mappingSnapshot} />
      </div>
    </main>
  );
}
