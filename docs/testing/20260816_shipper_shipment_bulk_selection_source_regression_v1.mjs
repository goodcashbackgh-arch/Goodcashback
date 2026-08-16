import fs from "node:fs";

const files = {
  page: fs.readFileSync("app/shipper/shipments/new/page.tsx", "utf8"),
  controls: fs.readFileSync("app/shipper/shipments/new/ShipmentSelectionControls.tsx", "utf8"),
  action: fs.readFileSync("app/shipper/shipments/new/exact-actions.ts", "utf8"),
  addendum: fs.readFileSync("docs/governing-pack/ui/SHIPPER_SHIPMENT_BATCH_BULK_SELECTION_UI_ADDENDUM_v1.md", "utf8"),
};

const checks = [
  [files.page.includes('rpc("shipper_shipment_batch_candidates_v2")'), "shipment page no longer uses candidate v2"],
  [files.page.includes("createExactShipmentBatchAction"), "shipment page no longer uses the exact server action"],
  [files.action.includes('"shipper_create_shipment_batch_v2"'), "exact action no longer calls create v2"],
  [files.page.includes('id="shipper-shipment-batch-create-form"'), "stable shipment creation form id missing"],
  [files.page.includes("ShipmentSelectionControls"), "bulk selection control is not wired into shipment page"],
  [files.page.match(/data-shipment-batch-select="true"/g)?.length === 2, "mobile and desktop checkbox hooks are not both present"],
  [files.page.match(/name="tracking_submission_ids"/g)?.length === 2, "existing tracking submission field names changed"],
  [files.controls.includes("Select all"), "Select all control missing"],
  [files.controls.includes("Clear selection"), "Clear selection control missing"],
  [files.controls.includes("selectedCount"), "selected count control missing"],
  [files.controls.includes("getClientRects"), "rendered responsive copy detection missing"],
  [files.controls.includes("box.disabled = !visible"), "hidden responsive copies are not disabled"],
  [files.controls.includes("box.checked = visible && selectedIdsRef.current.has(box.value)"), "logical selection is not mirrored only to rendered copies"],
  [files.controls.includes('form.addEventListener("submit", handleSubmit)'), "pre-submit responsive synchronisation missing"],
  [files.controls.includes('window.addEventListener("resize", handleResponsiveChange)'), "responsive resize synchronisation missing"],
  [files.controls.includes('window.addEventListener("orientationchange", handleResponsiveChange)'), "orientation synchronisation missing"],
  [files.controls.includes('type="button"'), "bulk controls may accidentally submit the form"],
  [!files.action.includes("new Set"), "server action was changed to silently deduplicate selections"],
  [files.page.includes("Create shipment batch"), "existing shipment page title changed"],
  [files.page.includes("Eligible received packages"), "existing candidate section label changed"],
  [files.page.includes("Shipment-eligible contents"), "existing contents label changed"],
  [files.addendum.includes("Anything outside the permitted runtime scope"), "scope lock missing from governing addendum"],
];

for (const [passed, message] of checks) {
  if (!passed) throw new Error(`FAIL: ${message}`);
}

console.log(JSON.stringify({
  probe: "shipper_shipment_bulk_selection_source_regression_v1",
  passed: true,
  runtime_files: [
    "app/shipper/shipments/new/page.tsx",
    "app/shipper/shipments/new/ShipmentSelectionControls.tsx",
  ],
  backend_action_unchanged_by_scope: true,
  responsive_duplicate_submission_guard_wired: true,
  existing_exact_shipment_wiring_preserved: true,
}, null, 2));
