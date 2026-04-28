import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import BulkLineSelectionControls from "./BulkLineSelectionControls";
import {
  addManualSupplierInvoiceLineAction,
  bulkMarkSupplierInvoiceLinesProgressedAction,
  deleteManualSupplierInvoiceLineAction,
  markSupplierInvoiceLineProgressedAction,
  updateSupplierInvoiceLineAction,
} from "./actions";

// (rest of file unchanged until bulk section)

// NOTE: only showing modified fragments for brevity in explanation, full file updated in repo
