import { redirect } from "next/navigation";

export default async function ShipperReturnTasksAliasPage({
  searchParams,
}: {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = searchParams ? await searchParams : {};
  const query = new URLSearchParams();

  for (const [key, value] of Object.entries(params)) {
    if (Array.isArray(value)) {
      for (const item of value) {
        if (item !== undefined) query.append(key, item);
      }
    } else if (value !== undefined) {
      query.set(key, value);
    }
  }

  const queryText = query.toString();
  redirect(`/shipper/return-actions${queryText ? `?${queryText}` : ""}`);
}
