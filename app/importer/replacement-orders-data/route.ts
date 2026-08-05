import { NextResponse } from "next/server";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

async function requireOperator() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) return { supabase, response: NextResponse.json({ error: "Unauthenticated" }, { status: 401 }) };

  const { data: operator, error: operatorError } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (operatorError) return { supabase, response: NextResponse.json({ error: operatorError.message }, { status: 500 }) };
  if (!operator) return { supabase, response: NextResponse.json({ error: "Operator account required" }, { status: 403 }) };

  return { supabase, operator, response: null };
}

export async function GET() {
  const auth = await requireOperator();
  if (auth.response) return auth.response;

  const { supabase, operator } = auth;

  const { data: orders, error: ordersError } = await supabase
    .from("orders")
    .select("id, order_ref, parent_order_id, status, order_type, total_qty_declared, order_total_gbp_declared, created_at, retailers(name)")
    .eq("operator_id", operator.id)
    .order("created_at", { ascending: false })
    .limit(200);

  if (ordersError) return NextResponse.json({ error: ordersError.message }, { status: 500 });

  const orderRows = (orders ?? []) as Row[];
  const orderIds = orderRows.map((row) => text(row.id)).filter(Boolean);
  const childRows = orderRows.filter((row) => text(row.order_type) === "replacement_child");
  const parentIds = [...new Set(childRows.map((row) => text(row.parent_order_id)).filter(Boolean))];
  const childIds = childRows.map((row) => text(row.id)).filter(Boolean);

  const [{ data: parents }, { data: childDisputes }, { data: routes, error: routesError }, { data: tracking, error: trackingError }] = await Promise.all([
    parentIds.length
      ? supabase.from("orders").select("id, order_ref, status").in("id", parentIds)
      : Promise.resolve({ data: [] }),
    childIds.length
      ? supabase
          .from("disputes")
          .select("id, order_id, desired_outcome, status, replacement_child_order_id")
          .in("replacement_child_order_id", childIds)
      : Promise.resolve({ data: [] }),
    orderIds.length
      ? supabase
          .from("physical_replacement_same_order_routes")
          .select("id, order_id, dispute_id, route_status, replacement_qty, transferred_adjusted_net_value_gbp, successor_tracking_submission_id, successor_tracking_line_allocation_id, tracking_allocated_at, created_at")
          .in("order_id", orderIds)
          .order("created_at", { ascending: false })
      : Promise.resolve({ data: [], error: null }),
    orderIds.length
      ? supabase
          .from("order_tracking_submissions")
          .select("id, order_id, tracking_ref, tracking_date, submitted_at, superseded_at")
          .in("order_id", orderIds)
          .is("superseded_at", null)
          .order("submitted_at", { ascending: false })
      : Promise.resolve({ data: [], error: null }),
  ]);

  if (routesError) return NextResponse.json({ error: routesError.message }, { status: 500 });
  if (trackingError) return NextResponse.json({ error: trackingError.message }, { status: 500 });

  const routeRows = (routes ?? []) as Row[];
  const routeDisputeIds = [...new Set(routeRows.map((row) => text(row.dispute_id)).filter(Boolean))];
  const { data: routeDisputes, error: routeDisputesError } = routeDisputeIds.length
    ? await supabase.from("disputes").select("id, status, desired_outcome").in("id", routeDisputeIds)
    : { data: [], error: null };

  if (routeDisputesError) return NextResponse.json({ error: routeDisputesError.message }, { status: 500 });

  const orderById = new Map(orderRows.map((row) => [text(row.id), row]));
  const parentById = new Map(((parents ?? []) as Row[]).map((row) => [text(row.id), row]));
  const disputeByChildId = new Map(((childDisputes ?? []) as Row[]).map((row) => [text(row.replacement_child_order_id), row]));
  const routeDisputeById = new Map(((routeDisputes ?? []) as Row[]).map((row) => [text(row.id), row]));
  const trackingByOrder = new Map<string, Row[]>();

  for (const submission of (tracking ?? []) as Row[]) {
    const orderId = text(submission.order_id);
    const current = trackingByOrder.get(orderId) ?? [];
    current.push(submission);
    trackingByOrder.set(orderId, current);
  }

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

  const sameOrderRoutes = routeRows.map((route) => {
    const orderId = text(route.order_id);
    const order = orderById.get(orderId);
    const dispute = routeDisputeById.get(text(route.dispute_id));
    const retailerValue = order?.retailers as { name?: string | null } | { name?: string | null }[] | null | undefined;
    const retailer = Array.isArray(retailerValue) ? retailerValue[0] : retailerValue;

    return {
      id: text(route.id),
      order_id: orderId,
      order_ref: text(order?.order_ref) || orderId.slice(0, 8),
      order_status: text(order?.status),
      retailer_name: text(retailer?.name),
      dispute_id: text(route.dispute_id),
      dispute_status: text(dispute?.status),
      desired_outcome: text(dispute?.desired_outcome),
      route_status: text(route.route_status),
      replacement_qty: route.replacement_qty ?? null,
      transferred_adjusted_net_value_gbp: route.transferred_adjusted_net_value_gbp ?? null,
      successor_tracking_submission_id: text(route.successor_tracking_submission_id),
      successor_tracking_line_allocation_id: text(route.successor_tracking_line_allocation_id),
      tracking_allocated_at: text(route.tracking_allocated_at),
      created_at: text(route.created_at),
      tracking_submissions: (trackingByOrder.get(orderId) ?? []).map((submission) => ({
        id: text(submission.id),
        tracking_ref: text(submission.tracking_ref),
        tracking_date: text(submission.tracking_date),
        submitted_at: text(submission.submitted_at),
      })),
    };
  });

  return NextResponse.json({ rows, same_order_routes: sameOrderRoutes });
}

export async function POST(request: Request) {
  const auth = await requireOperator();
  if (auth.response) return auth.response;

  const { supabase } = auth;
  const body = (await request.json().catch(() => null)) as
    | { order_id?: unknown; tracking_submission_id?: unknown; route_ids?: unknown; note?: unknown }
    | null;

  const orderId = text(body?.order_id);
  const trackingSubmissionId = text(body?.tracking_submission_id);
  const routeIds = Array.isArray(body?.route_ids) ? body?.route_ids.map(text).filter(Boolean) : [];
  const note = text(body?.note) || null;

  if (!orderId || !trackingSubmissionId || routeIds.length === 0) {
    return NextResponse.json({ error: "Order, tracking submission and at least one replacement route are required." }, { status: 400 });
  }

  const { data, error } = await supabase.rpc("operator_allocate_same_order_replacement_tracking_v1", {
    p_order_id: orderId,
    p_tracking_submission_id: trackingSubmissionId,
    p_route_ids: routeIds,
    p_note: note,
  });

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json({ result: data });
}
