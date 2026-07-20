import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;

type SubmissionRow = {
  id: string;
  dispute_id: string | null;
  document_mode: string | null;
  credit_note_ref: string | null;
  credit_note_date: string | null;
  expected_credit_note_total_gbp: string | number | null;
  credit_note_file_url: string | null;
  ocr_status: string | null;
  ocr_credit_note_ref: