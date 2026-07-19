import Link from "next/link";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import BulkLineSelectionControls from "./BulkLineSelectionControls";
import SelectedInvoiceCookie from "./SelectedInvoiceCookie";
import {
  addManualSupplierInvoiceLineAction,
  bulkMarkSupplierInvoiceLinesProgressedAction,
  createExceptionCaseAction,
  deleteManualSupplierInvoiceLineAction,
  markSupplierInvoiceLineProgressedAction,
  updateSupplierInvoiceLineAction,
} from "./actions";
import { resolveSupplierInvoiceLineNonPhysicalAction } from "./nonPhysicalActions";

type Invoice = { id:string; invoice_ref:string; invoice_pdf_url:string; uploaded_at:string|null; ocr_extracted_at:string|null; review_status:string|null };
type Line = { id:string; supplier_invoice_id:string; line_order:number; line_source:string; retailer_sku:string|null; description:string; qty:number; size:string|null; amount_inc_vat_gbp:number; qty_confirmed:number|null; amount_confirmed:number|null; eligible_for_invoice_yn:string };
type Resolution = { supplier_invoice_line_id:string; financial_type:string; notes:string|null };
type Search = { success?:string; error?:string; supplier_invoice_id?:string };
const retired = new Set(["rejected_resubmit_required","duplicate_blocked","superseded"]);
const progressed = (line: Pick<Line,"eligible_for_invoice_yn">) => ["y","yes","true","1"].includes((line.eligible_for_invoice_yn||"").trim().toLowerCase());
const gbp = (v:unknown) => new Intl.NumberFormat("en-GB",{style:"currency",currency:"GBP"}).format(Number(v??0));
const signed = (v:number) => Math.abs(v)<0.005?gbp(0):`${v>0?"+":""}${gbp(v)}`;
const input = "w-full rounded-xl border border-slate-300 px-3 py-2 text-sm";

export default async function Page({params,searchParams}:{params:Promise<{order_id:string}>;searchParams?:Promise<Search>}) {
  const {order_id:orderId}=await params;
  const qp=searchParams?await searchParams:{};
  const supabase=await createClient();
  const {data:{user}}=await supabase.auth.getUser();
  if(!user) redirect("/login");
  const {data:operator}=await supabase.from("operators").select("id, full_name").eq("auth_user_id",user.id).eq("active",true).maybeSingle();
  if(!operator) redirect("/auth/check");
  const {data:order}=await supabase.from("orders").select("id, importer_id, order_ref, total_qty_declared, order_total_gbp_declared, screenshot_url").eq("id",orderId).maybeSingle();
  if(!order) redirect("/importer");
  const {data:access}=await supabase.from("operator_importers").select("id").eq("operator_id",operator.id).eq("importer_id",order.importer_id).is("revoked_at",null).limit(1).maybeSingle();
  if(!access) redirect("/importer");

  const [{data:invoiceRows,error:invoiceError},{data:screenshots}] = await Promise.all([
    supabase.from("supplier_invoices").select("id, invoice_ref, invoice_pdf_url, uploaded_at, ocr_extracted_at, review_status").eq("order_id",orderId).order("uploaded_at",{ascending:false}),
    supabase.from("order_screenshots").select("id, screenshot_url, display_order, note").eq("order_id",orderId).order("display_order"),
  ]);
  const invoices=((invoiceRows??[]) as Invoice[]).filter(i=>!retired.has(i.review_status??""));
  const cookieStore=await cookies();
  const requested=qp.supplier_invoice_id?.trim()||cookieStore.get(`recon_invoice_${orderId}`)?.value||"";
  const invoice=invoices.find(i=>i.id===requested)??invoices[0]??null;
  const invoiceIds=invoices.map(i=>i.id);
  const {data:allLineRows,error:linesError}=invoiceIds.length?await supabase.from("supplier_invoice_lines").select("id, supplier_invoice_id, line_order, line_source, retailer_sku, description, qty, size, amount_inc_vat_gbp, qty_confirmed, amount_confirmed, eligible_for_invoice_yn").in("supplier_invoice_id",invoiceIds).order("line_order"):{data:[] as Line[],error:null};
  const allLines=(allLineRows??[]) as Line[];
  const lines=invoice?allLines.filter(l=>l.supplier_invoice_id===invoice.id):[];
  const lineIds=allLines.map(l=>l.id);
  const [{data:resolutionRows},{data:disputeRows}] = await Promise.all([
    lineIds.length?supabase.from("supplier_invoice_line_resolutions").select("supplier_invoice_line_id, financial_type, notes").in("supplier_invoice_line_id",lineIds).eq("active",true):Promise.resolve({data:[] as Resolution[]}),
    lineIds.length?supabase.from("dispute_lines").select("supplier_invoice_line_id, disputes!inner(id, desired_outcome, resolved_at)").in("supplier_invoice_line_id",lineIds).is("resolved_at",null):Promise.resolve({data:[] as any[]}),
  ]);
  const resolutions=new Map(((resolutionRows??[]) as Resolution[]).map(r=>[r.supplier_invoice_line_id,r]));
  const disputes=new Map<string,string>();
  for(const row of disputeRows??[]){const d=Array.isArray(row.disputes)?row.disputes[0]:row.disputes;if(d&&!d.resolved_at)disputes.set(row.supplier_invoice_line_id,d.desired_outcome);}

  const declaredQty=Number(order.total_qty_declared??0), declaredValue=Number(order.order_total_gbp_declared??0);
  const accountedQty=allLines.filter(l=>progressed(l)||disputes.has(l.id)).reduce((s,l)=>s+Number(l.qty??0),0);
  const accountedValue=allLines.filter(l=>progressed(l)||disputes.has(l.id)||resolutions.has(l.id)).reduce((s,l)=>s+Number(l.amount_inc_vat_gbp??0),0);
  const remainingQty=Math.max(0,declaredQty-accountedQty), remainingValue=Math.max(0,declaredValue-accountedValue);
  const selectable=lines.filter(l=>!progressed(l)&&!disputes.has(l.id)&&!resolutions.has(l.id)&&Number(l.qty)<=remainingQty&&Number(l.amount_inc_vat_gbp)<=remainingValue+0.01);
  const unresolved=lines.filter(l=>!progressed(l)&&!disputes.has(l.id)&&!resolutions.has(l.id));
  const qVar=accountedQty-declaredQty, vVar=accountedValue-declaredValue;

  return <main className="min-h-screen bg-slate-50 p-4 text-slate-950 sm:p-6"><div className="mx-auto max-w-7xl space-y-6">
    <FlashQueryParamCleaner/><SelectedInvoiceCookie orderId={orderId} supplierInvoiceId={invoice?.id??null}/>
    <section className="rounded-3xl border bg-white p-5 shadow-sm">
      <Link href={`/importer/orders/${orderId}/operations#invoice`} className="text-sm font-semibold text-sky-700">← Back to order evidence</Link>
      <p className="mt-5 text-xs font-bold uppercase tracking-[.18em] text-sky-600">Invoice reconciliation</p>
      <h1 className="mt-1 text-2xl font-semibold">Order {order.order_ref??orderId}</h1>
      <p className="mt-2 text-sm text-slate-600">The selected invoice stays separate; the baseline is counted once across all active invoices.</p>
      <div className="mt-4 flex flex-wrap gap-2">{invoices.map(i=><Link key={i.id} href={`/importer/reconciliation/${orderId}?supplier_invoice_id=${i.id}`} className={`rounded-full px-3 py-1.5 text-xs font-semibold ${invoice?.id===i.id?"bg-sky-700 text-white":"border border-sky-200 bg-sky-50 text-sky-800"}`}>{i.invoice_ref}</Link>)}</div>
      {qp.success?<p className="mt-4 rounded-xl bg-emerald-50 p-3 text-sm text-emerald-900">{qp.success}</p>:null}{qp.error?<p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm text-rose-900">{qp.error}</p>:null}
    </section>

    <section className="rounded-3xl border bg-white p-5 shadow-sm"><div className="flex flex-wrap justify-between gap-3"><div><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Order-wide bundle check</p><h2 className="text-xl font-semibold">All active invoice lines</h2></div><span className={`rounded-full px-3 py-1 text-xs font-semibold ${Math.abs(qVar)<.01&&Math.abs(vVar)<.01?"bg-emerald-100 text-emerald-800":"bg-amber-100 text-amber-800"}`}>{Math.abs(qVar)<.01&&Math.abs(vVar)<.01?"Accounted for":"Variance open"}</span></div>
      <div className="mt-4 grid gap-3 md:grid-cols-6">{[["Declared qty",declaredQty],["Accounted qty",accountedQty],["Qty variance",qVar],["Declared value",gbp(declaredValue)],["Accounted value",gbp(accountedValue)],["Value variance",signed(vVar)]].map(([a,b])=><div key={String(a)} className="rounded-2xl bg-slate-50 p-3"><p className="text-xs text-slate-500">{a}</p><p className="font-semibold">{b}</p></div>)}</div>
    </section>

    <section className="grid gap-6 lg:grid-cols-2"><article className="rounded-3xl border bg-white p-5 shadow-sm"><h2 className="text-xl font-semibold">Selected supplier invoice</h2>{invoiceError?<p className="mt-3 text-rose-700">{invoiceError.message}</p>:invoice?<><dl className="mt-4 grid gap-3 sm:grid-cols-2"><div><dt className="text-xs text-slate-500">Reference</dt><dd className="font-semibold">{invoice.invoice_ref}</dd></div><div><dt className="text-xs text-slate-500">Line count</dt><dd>{lines.length}</dd></div><div><dt className="text-xs text-slate-500">Uploaded</dt><dd>{invoice.uploaded_at??"—"}</dd></div><div><dt className="text-xs text-slate-500">OCR extracted</dt><dd>{invoice.ocr_extracted_at??"—"}</dd></div></dl><a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="mt-4 inline-block rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Open this invoice</a></>:<p className="mt-3 text-slate-600">No active invoice.</p>}</article>
      <article className="rounded-3xl border bg-white p-5 shadow-sm"><h2 className="text-xl font-semibold">Original order screenshots</h2><div className="mt-4 space-y-3">{(screenshots??[]).map((s:any)=><details key={s.id} className="rounded-xl border p-3"><summary className="cursor-pointer font-semibold">Screenshot {s.display_order??""}</summary>{s.note?<p className="mt-2 text-sm">{s.note}</p>:null}<img src={s.screenshot_url} alt="Order screenshot" className="mt-3 max-h-[60vh] w-full object-contain"/></details>)}</div></article>
    </section>

    {invoice?<><section className="rounded-3xl border bg-white p-5 shadow-sm"><h2 className="text-xl font-semibold">Add manual line to {invoice.invoice_ref}</h2><form action={addManualSupplierInvoiceLineAction} className="mt-4 grid gap-3 md:grid-cols-5"><input type="hidden" name="order_id" value={orderId}/><input type="hidden" name="supplier_invoice_id" value={invoice.id}/><input name="description" required placeholder="Description" className={`${input} md:col-span-2`}/><input name="qty" required type="number" min="0" step="1" placeholder="Qty" className={input}/><input name="amount_inc_vat_gbp" required type="number" min="0" step=".01" placeholder="Amount" className={input}/><button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Add line</button></form></section>

    <section className="rounded-3xl border bg-white p-5 shadow-sm"><h2 className="text-xl font-semibold">Supplier invoice lines — {invoice.invoice_ref}</h2>{selectable.length?<div className="mt-4 rounded-2xl bg-emerald-50 p-4"><BulkLineSelectionControls selectableCount={selectable.length}/><form id="bulk-progress-form" action={bulkMarkSupplierInvoiceLinesProgressedAction} className="mt-3"><input type="hidden" name="order_id" value={orderId}/><input type="hidden" name="supplier_invoice_id" value={invoice.id}/><button className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white">Mark selected as progressed</button></form></div>:null}
      {linesError?<p className="mt-4 text-rose-700">{linesError.message}</p>:<div className="mt-4 space-y-4">{lines.map(line=>{const done=progressed(line), dispute=disputes.get(line.id), resolution=resolutions.get(line.id), locked=Boolean(dispute||resolution), canProgress=selectable.some(x=>x.id===line.id);return <article key={line.id} className={`rounded-2xl border p-4 ${done?"border-emerald-200 bg-emerald-50":locked?"border-amber-200 bg-amber-50":"bg-white"}`}><div className="flex flex-wrap justify-between gap-2"><label className="font-semibold"><input type="checkbox" name="line_ids" value={line.id} form="bulk-progress-form" disabled={!canProgress} className="mr-2"/>Line {line.line_order}</label><span className="text-xs font-semibold">{done?"Progressed":resolution?`Parked: ${resolution.financial_type}`:dispute?`Exception: ${dispute}`:"Unresolved"}</span></div><div className="mt-3 grid gap-3 md:grid-cols-6"><input form={`edit-${line.id}`} name="description" defaultValue={line.description} readOnly={line.line_source==="ocr_extracted"||locked} className={`${input} md:col-span-3`}/><input form={`edit-${line.id}`} name="qty" type="number" min="0" step="1" defaultValue={line.qty} readOnly={locked} className={input}/><input form={`edit-${line.id}`} name="amount_inc_vat_gbp" type="number" min="0" step=".01" defaultValue={line.amount_inc_vat_gbp} readOnly={locked} className={input}/><input form={`edit-${line.id}`} name="size" defaultValue={line.size??""} readOnly={locked} placeholder="Size" className={input}/></div><div className="mt-3 flex flex-wrap gap-2">{!locked?<button form={`edit-${line.id}`} className="rounded-xl bg-sky-700 px-3 py-2 text-sm font-semibold text-white">Save</button>:null}{canProgress?<form action={markSupplierInvoiceLineProgressedAction}><input type="hidden" name="order_id" value={orderId}/><input type="hidden" name="supplier_invoice_id" value={invoice.id}/><input type="hidden" name="line_id" value={line.id}/><button className="rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-800">Mark progressed</button></form>:null}{!done&&!locked?<form action={resolveSupplierInvoiceLineNonPhysicalAction} className="flex gap-2"><input type="hidden" name="order_id" value={orderId}/><input type="hidden" name="supplier_invoice_id" value={invoice.id}/><input type="hidden" name="line_id" value={line.id}/><select name="financial_type" className="rounded-xl border px-2 text-sm"><option value="delivery">delivery</option><option value="discount">discount</option><option value="fee">fee</option><option value="other_non_physical">other non-physical</option></select><button className="rounded-xl bg-sky-100 px-3 py-2 text-sm font-semibold text-sky-900">Park</button></form>:null}{line.line_source==="manually_added"&&!locked?<form action={deleteManualSupplierInvoiceLineAction}><input type="hidden" name="order_id" value={orderId}/><input type="hidden" name="supplier_invoice_id" value={invoice.id}/><input type="hidden" name="line_id" value={line.id}/><button className="rounded-xl bg-rose-50 px-3 py-2 text-sm font-semibold text-rose-800">Delete</button></form>:null}</div><form id={`edit-${line.id}`} action={updateSupplierInvoiceLineAction}><input type="hidden" name="order_id" value={orderId}/><input type="hidden" name="supplier_invoice_id" value={invoice.id}/><input type="hidden" name="line_id" value={line.id}/></form></article>})}</div>}
    </section>

    {unresolved.length?<section className="rounded-3xl border bg-white p-5 shadow-sm"><h2 className="text-xl font-semibold">Create exception from this invoice</h2><form action={createExceptionCaseAction} className="mt-4 space-y-3"><input type="hidden" name="order_id" value={orderId}/><input type="hidden" name="supplier_invoice_id" value={invoice.id}/>{unresolved.map(l=><label key={l.id} className="block rounded-xl bg-slate-50 p-3"><input type="checkbox" name="exception_line_ids" value={l.id} className="mr-2"/>Line {l.line_order} · {l.description} · {gbp(l.amount_inc_vat_gbp)}</label>)}<label className="mr-4"><input type="radio" name="remedy" value="refund" className="mr-2"/>Refund</label><label><input type="radio" name="remedy" value="replacement" className="mr-2"/>Replacement</label><button className="ml-4 rounded-xl bg-amber-700 px-4 py-2 text-sm font-semibold text-white">Create exception</button></form></section>:null}</>:null}
  </div></main>;
}
