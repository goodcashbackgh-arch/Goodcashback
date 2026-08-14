import { createClient } from "@/utils/supabase/client";

export async function uploadCorrectionScreenshots({
  orderId,
  importerId,
  files,
}: {
  orderId: string;
  importerId: string;
  files: File[];
}) {
  const supabase = createClient();
  const urls: string[] = [];
  const stamp = Date.now();

  for (let index = 0; index < files.length; index += 1) {
    const file = files[index];
    const ext = (file.name.split(".").pop() ?? "bin").toLowerCase().replace(/[^a-z0-9]/g, "") || "bin";
    const objectPath = `${importerId}/${orderId}/correction-${stamp}-${index + 1}.${ext}`;
    const { error } = await supabase.storage.from("order-screenshots").upload(objectPath, file, { upsert: false });
    if (error) throw new Error(`Replacement attachment upload failed. ${error.message}`);
    const { data } = supabase.storage.from("order-screenshots").getPublicUrl(objectPath);
    urls.push(data.publicUrl || objectPath);
  }

  return urls;
}
