type Row = Record<string, unknown>;

export type SageAttachmentJsonAttempt = {
  endpoint: string;
  label: string;
  payload: Row;
  auditPayload: Row;
};

function text(value: unknown) {
  if (typeof value === "string") return value.trim();
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

export function buildSageAttachmentJsonAttempts(args: {
  configuredEndpointTemplate?: string;
  sageInvoiceId: string;
  sageTransactionId?: string;
  sourceUrl?: string;
  fileName: string;
  mimeType: string;
  encodedFile: string;
  byteLength: number;
}): SageAttachmentJsonAttempt[] {
  const transactionId = text(args.sageTransactionId);
  if (!transactionId) return [];

  const redacted = `[encoded PDF redacted; ${args.byteLength} bytes]`;

  return [
    {
      endpoint: "/attachments",
      label: "json_required_fields_with_transaction_id",
      payload: {
        attachment: {
          file: args.encodedFile,
          mime_type: args.mimeType,
          file_name: args.fileName,
          transaction_id: transactionId,
        },
      },
      auditPayload: {
        attachment: {
          file: redacted,
          mime_type: args.mimeType,
          file_name: args.fileName,
          transaction_id: transactionId,
        },
      },
    },
  ];
}
