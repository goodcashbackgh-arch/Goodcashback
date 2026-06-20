import { NextResponse } from "next/server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

const EVIDENCE_BUCKET = "invoice-evidence";

type GroupageDetailRow = {
  shipment_batch_id: string;
  booking_ref: string | null;
  pod_status: string | null;
};

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
}

function redirectTo(originUrl: URL, groupageMovementId: string, params: Record<string, string>) {
  const next = new URL(`/shipper/groupage-movements/${groupageMovementId}`, originUrl.origin);
  for (const [key, value] of Object.entries(params)) next.searchParams.set(key, value);
  return NextResponse.redirect(next, { status: 303 });
}

function podIsClosed(value: string | null | undefined) {
  return value === "submitted_for_review" || value === "accepted_current";
}

async function uploadGroupagePodFile(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  groupageMovementId: string;
  file: File;
}) {
  const objectPath = `shipper-groupage-movements/${params.groupageMovementId}/pod_delivery_evidence/${Date.now()}.${safeExt(params.file.name)}`;
  const { error } = await params.supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(objectPath, params.file, { upsert: false });

  if (error) {
    throw new Error(`Groupage POD upload failed. Ensure bucket '${EVIDENCE_BUCKET}' exists and is writable. ${error.message}`);
  }

  const { data } = params.supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(objectPath);
  return data.publicUrl || objectPath;
}

export async function POST(request: Request, { params }: { params: Promise<{ groupage_movement_id: string }> }) {
  const { groupage_movement_id: groupageMovementId } = await params;
  const url = new URL(request.url);

  try {
    const supabase = await createClient();
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return NextResponse.redirect(new URL("/login", url.origin), { status: 303 });

    const formData = await request.formData();
    const selected = Array.from(new Set(
      formData.getAll("pod_shipment_batch_ids")
        .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
        .map((value) => value.trim())
    ));
    const documentRefRaw = formData.get("pod_document_ref");
    const notesRaw = formData.get("pod_notes");
    const documentRef = typeof documentRefRaw === "string" && documentRefRaw.trim() ? documentRefRaw.trim() : null;
    const notes = typeof notesRaw === "string" && notesRaw.trim() ? notesRaw.trim() : null;

    if (selected.length === 0) {
      return redirectTo(url, groupageMovementId, { error: "Select at least one open booking ref covered by the POD." });
    }

    const { data: detailData, error: detailError } = await (supabase as any).rpc("shipper_groupage_movement_detail_v1", {
      p_groupage_movement_id: groupageMovementId,
    });

    if (detailError) return redirectTo(url, groupageMovementId, { error: detailError.message });

    const detailRows = (detailData ?? []) as GroupageDetailRow[];
    const detailByBatch = new Map(detailRows.map((row) => [row.shipment_batch_id, row]));
    const invalidSelections = selected.filter((id) => !detailByBatch.has(id));
    if (invalidSelections.length > 0) {
      return redirectTo(url, groupageMovementId, { error: "Selected POD booking refs must belong to this active Groupage Movement." });
    }

    const openSelections = selected.filter((id) => !podIsClosed(detailByBatch.get(id)?.pod_status));
    if (openSelections.length === 0) {
      return redirectTo(url, groupageMovementId, { success: "Selected POD booking refs are already submitted or accepted." });
    }

    const file = formData.get("groupage_pod_file");
    if (!(file instanceof File) || file.size === 0) {
      return redirectTo(url, groupageMovementId, { error: "Upload the POD / delivery evidence file." });
    }

    const fileUrl = await uploadGroupagePodFile({ supabase, groupageMovementId, file });
    const { error } = await (supabase as any).rpc("shipper_submit_groupage_pod_v1", {
      p_groupage_movement_id: groupageMovementId,
      p_shipment_batch_ids: openSelections,
      p_file_url: fileUrl,
      p_document_ref: documentRef,
      p_notes: notes,
    });

    if (error) return redirectTo(url, groupageMovementId, { error: error.message });

    revalidatePath("/shipper");
    revalidatePath("/shipper/shipments");
    revalidatePath("/shipper/groupage-movements");
    revalidatePath(`/shipper/groupage-movements/${groupageMovementId}`);
    revalidatePath(`/shipper/groupage-movements/${groupageMovementId}/final-evidence`);
    revalidatePath("/internal/shipping-control");
    revalidatePath(`/internal/shipping-control/groupage-movements/${groupageMovementId}`);

    const label = openSelections.length === 1 ? "booking ref" : "booking refs";
    return redirectTo(url, groupageMovementId, { success: `POD uploaded for ${openSelections.length} ${label}.` });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Groupage POD upload failed.";
    return redirectTo(url, groupageMovementId, { error: message });
  }
}
