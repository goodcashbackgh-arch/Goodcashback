import fs from "node:fs";

const files = {
  page: fs.readFileSync("app/shipper/shipments/new/page.tsx", "utf8"),
  action: fs.readFileSync("app/shipper/shipments/new/exact-actions.ts", "utf8"),
  preview: fs.readFileSync("app/shipper/PackageContentsPreview.tsx", "utf8"),
  detail: fs.readFileSync("app/shipper/package-contents/[tracking_submission_id]/page.tsx", "utf8"),
};

const checks = [
  [files.page.includes('rpc("shipper_shipment_batch_candidates_v2")'), "new shipment page does not use candidate v2"],
  [files.page.includes("createExactShipmentBatchAction"), "new shipment page is not wired to exact action"],
  [files.action.includes('"shipper_create_shipment_batch_v2"'), "exact action does not call create v2"],
  [files.preview.includes('rpc("shipper_package_contents_preview_v2"'), "compact preview does not use exact contents v2"],
  [files.detail.includes('rpc("shipper_package_contents_preview_v2"'), "detail page does not use exact contents v2"],
  [files.page.includes("Create shipment batch"), "existing shipment page title changed"],
  [files.page.includes("Eligible received packages"), "existing candidate section label changed"],
  [files.page.includes("Shipment-eligible contents"), "existing contents label changed"],
  [files.page.includes("/shipper/shipments/new"), "existing new-shipment route missing"],
  [files.detail.includes("Original package contents"), "existing original contents section changed"],
  [files.detail.includes("Diverted from shipment"), "existing diverted section changed"],
  [files.detail.includes("freight and AP/recharge"), "existing downstream description changed"],
];

for (const [passed, message] of checks) {
  if (!passed) throw new Error(`FAIL: ${message}`);
}

console.log(JSON.stringify({
  probe: "exact_shipment_ui_wiring_source_regression_v1",
  passed: true,
  candidate_rpc: "shipper_shipment_batch_candidates_v2",
  creation_rpc: "shipper_create_shipment_batch_v2",
  contents_rpc: "shipper_package_contents_preview_v2",
  labels_navigation_downstream_preserved: true,
}, null, 2));
