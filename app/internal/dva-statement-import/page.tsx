import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import { createRealStatementImportBatchAction, voidDvaStatementImportBatchAction } from "./actions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const BATCH