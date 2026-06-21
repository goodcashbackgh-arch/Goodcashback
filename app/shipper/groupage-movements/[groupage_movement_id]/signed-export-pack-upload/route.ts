import { NextResponse } from "next/server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/utils/supabase/server";

const EVIDENCE_BUCKET = "invoice-evidence";

function safeExt(fileName: string) {
  const ext = fileName.includes(".") ? fileName.split(".").pop() : "bin";
  return (ext ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
}

function redirectTo(originUrl: URL, groupageMovementId: string, params: Record<string, string>) {
  const next = new URL(`/shipper/groupage-movements/${groupageMovementId}`, originUrl.origin);
  for (const [key, value] of Object.entries(params)) next.searchParams.set(key, value);
  return NextResponse.redirect(next, { status: 303 });
}

async function uploadGroupageSignedPackFile(params: {
  supabase: Awaited<ReturnType<typeof createClient>>;
  groupageMovementId: string;
  file: File;
}) {
  const objectPath = `shipper-groupage-movements/${params.groupageMovementId}/signed_export_pack/${Date.now()}.${safeExt(params.file.name)}`;
  const { error } = await params.supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(objectPath, params.file, { upsert: false });

  if (error) {
    throw new Error(`Groupage signed export pack upload failed. Ensure bucket '${EVIDENCE_BUCKET}' exists and is writable. ${error.message}`);
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
    const documentRefRaw = formData.get("document_ref");
    const notesRaw = formData.get("notes");
    const documentRef = typeof documentRefRaw === "string" && documentRefRaw.trim() ? documentRefRaw.trim() : null;
    const notes = typeof notesRaw === "string" && notesRaw.trim() ? notesRaw.trim() : null;
    const file = formData.get("groupage_export_pack_file");

    if (!(file instanceof File) || file.size === 0) {
      return redirectTo(url, groupageMovementId, { error: "Upload the signed Groupage Export Pack." });
    }

    const fileUrl = await uploadGroupageSignedPackFile({ supabase, groupageMovementId, file });
    const { error } = await (supabase as any).rpc("shipper_submit_groupage_signed_export_pack_v1", {
      p_groupage_movement_id: groupageMovementId,
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

    return redirectTo(url, groupageMovementId, { success: "Signed Groupage Export Pack uploaded and applied to included batches" });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Groupage signed export pack upload failed.";
    return redirectTo(url, groupageMovementId, { error: message });
  }
}
