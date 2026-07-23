import { NextResponse } from "next/server";

function externalRedirectTarget(parts: string[], requestUrl: string) {
  const rawPath = parts.join("/").trim();
  if (!rawPath) return null;

  const candidate = /^https?:\/\//i.test(rawPath) ? rawPath : `https://${rawPath}`;

  try {
    const target = new URL(candidate);
    if (target.protocol !== "http:" && target.protocol !== "https:") return null;
    if (!target.hostname.includes(".")) return null;

    const incoming = new URL(requestUrl);
    target.search = incoming.search;
    return target;
  } catch {
    return null;
  }
}

export async function GET(
  request: Request,
  { params }: { params: Promise<{ external: string[] }> },
) {
  const { external } = await params;
  const target = externalRedirectTarget(external, request.url);

  if (!target) {
    return NextResponse.redirect(new URL("/shipper", request.url));
  }

  return NextResponse.redirect(target);
}
