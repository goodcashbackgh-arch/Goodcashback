import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

export async function GET() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return NextResponse.json({ error: "Unauthenticated" }, { status: 401 });

  const { data: operator, error: operatorError } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (operatorError) return NextResponse.json({ error: operatorError.message }, { status: 500 });
  if (!operator) return NextResponse.json({ error: "Operator account required" }, { status: 403 });

  const { data: children, error: childrenError } = await supabase
    .from("orders")
    .select("id, order_ref, parent_order_id, status, order_type, total_qty_declared, order_total_gbp_declared, created_at, retailers(name)")
    .eq("operator_id", operator.id)
    .eq("order_type", "replacement_child")
    .order("created_at", { ascending: false })
    .limit(50);

  if (childrenError) return NextResponse.json({ error: childrenError.message }, { status: 500 });

  const childRows = (children ?? []) as Row[];
  const parentIds = [...new Set(childRows.map((row) => text(row.parent_order_id)).filter(Boolean))];
  const childIds = childRows.map((row) => text(row.id)).filter(Boolean);

  const [{ data: parents }, { data: disputes }] = await Promise.all([
    parentIds.length
      ? supabase.from("orders").select("id, order_ref, status").in("id", parentIds)
      : Promise.resolve({ data: [] }),
    childIds.length
      ? supabase
          .from("disputes")
          .select("id, order_id, desired_outcome, status, replacement_child_order_id")
          .in("replacement_child_order_id", childIds)
      : Promise.resolve({ data: [] }),
  ]);

  const parentById = new Map(((parents ?? []) as Row[]).map((row) => [text(row.id), row]));
  const disputeByChildId = new Map(((disputes ?? []) as Row[]).map((row) => [text(row.replacement_child_order_id), row]));

  const rows = childRows.map((child) => {
    const id = text(child.id);
    const parent = parentById.get(text(child.parent_order_id));
    const dispute = disputeByChildId.get(id);
    const retailerValue = child.retailers as { name?: string | null } | { name?: string | null }[] | null | undefined;
    const retailer = Array.isArray(retailerValue) ? retailerValue[0] : retailerValue;

    return {
      id,
      order_ref: text(child.order_ref) || id.slice(0, 8),
      status: text(child.status),
      order_type: text(child.order_type),
      parent_order_id: text(child.parent_order_id),
      parent_order_ref: text(parent?.order_ref),
      parent_order_status: text(parent?.status),
      retailer_name: text(retailer?.name),
      total_qty_declared: child.total_qty_declared ?? null,
      order_total_gbp_declared: child.order_total_gbp_declared ?? null,
      dispute_id: text(dispute?.id),
      dispute_status: text(dispute?.status),
      desired_outcome: text(dispute?.desired_outcome),
      created_at: text(child.created_at),
    };
  });

  return NextResponse.json({ rows });
}
