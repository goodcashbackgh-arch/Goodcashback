import { POST as runProbe } from "../sage-zero-line/route";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const confirm = url.searchParams.get("confirm") || "";
  const forwarded = new Request(request.url, {
    method: "POST",
    headers: request.headers,
    body: JSON.stringify({ confirm }),
  });
  return runProbe(forwarded);
}
