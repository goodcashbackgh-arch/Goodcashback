import Link from "next/link";

export const dynamic = "force-dynamic";
export const revalidate = 0;

function text(value: unknown): string {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

export default async function VatReturnRunLayout({ children, params }: any) {
  const routeParams = params ? await params : {};
  const runId = text(routeParams?.return_run_id);

  if (!runId) return children;

  const links = [
    { href: `/internal/accounting-vat/returns/${runId}`, label: "Draft return", hint: "Main tabs" },
    { href: `/internal/accounting-vat/returns/${runId}?tab=journals`, label: "Sage adjustment journals", hint: "Approve / post" },
    { href: `/internal/accounting-vat/returns/${runId}/sage-evidence`, label: "Evidence pack", hint: "Posting proof" },
    { href: `/internal/accounting-vat/returns/${runId}?tab=submission`, label: "Submission evidence", hint: "Sage/MTD lock" },
  ];

  return (
    <>
      <div className="bg-slate-50 px-6 pt-6 text-slate-950">
        <nav className="mx-auto flex max-w-7xl gap-2 overflow-x-auto rounded-3xl border border-slate-200 bg-white p-3 shadow-sm" aria-label="VAT return navigation">
          {links.map((link) => (
            <Link key={link.href} href={link.href} className="min-w-fit rounded-2xl border border-slate-200 bg-white px-4 py-3 text-sm text-slate-700 hover:border-sky-200 hover:bg-sky-50 hover:text-sky-900">
              <span className="block font-bold">{link.label}</span>
              <span className="mt-1 block text-xs opacity-75">{link.hint}</span>
            </Link>
          ))}
        </nav>
      </div>
      {children}
    </>
  );
}
