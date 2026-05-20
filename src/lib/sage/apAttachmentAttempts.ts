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
  sourceUrl?: string;
  fileName: string;
  mimeType: string;
  encodedFile: string;
  byteLength: number;
}): SageAttachmentJsonAttempt[] {
  const endpointTemplate = text(args.configuredEndpointTemplate);

  const endpoints = endpointTemplate
    ? [
        endpointTemplate
          .replaceAll("{purchase_invoice_id}", encodeURIComponent(args.sageInvoiceId))
          .replaceAll("{id}", encodeURIComponent(args.sageInvoiceId))
          .replaceAll("{sage_object_id}", encodeURIComponent(args.sageInvoiceId)),
      ]
    : ["/attachments"];

  const redacted = `[encoded PDF redacted; ${args.byteLength} bytes]`;
  const attempts: SageAttachmentJsonAttempt[] = [];

  for (const endpoint of endpoints) {
    /*
      Sage has told us the required JSON fields are:
      attachment[file]
      attachment[mime_type]

      So the first probe must be the cleanest possible body.
      No filename.
      No file_name.
      No description.
      No context_id.
      No context_type.
    */
    attempts.push({
      endpoint,
      label: "json_minimal_required_fields",
      payload: {
        attachment: {
          file: args.encodedFile,
          mime_type: args.mimeType,
        },
      },
      auditPayload: {
        attachment: {
          file: redacted,
          mime_type: args.mimeType,
        },
      },
    });

    attempts.push({
      endpoint,
      label: "json_required_fields_with_file_name",
      payload: {
        attachment: {
          file: args.encodedFile,
          mime_type: args.mimeType,
          file_name: args.fileName,
        },
      },
      auditPayload: {
        attachment: {
          file: redacted,
          mime_type: args.mimeType,
          file_name: args.fileName,
        },
      },
    });

    attempts.push({
      endpoint,
      label: "json_required_fields_with_filename",
      payload: {
        attachment: {
          file: args.encodedFile,
          mime_type: args.mimeType,
          filename: args.fileName,
        },
      },
      auditPayload: {
        attachment: {
          file: redacted,
          mime_type: args.mimeType,
          filename: args.fileName,
        },
      },
    });

    attempts.push({
      endpoint,
      label: "json_required_fields_with_purchase_invoice_context",
      payload: {
        attachment: {
          file: args.encodedFile,
          mime_type: args.mimeType,
          file_name: args.fileName,
          context_type: "purchase_invoice",
          context_id: args.sageInvoiceId,
        },
      },
      auditPayload: {
        attachment: {
          file: redacted,
          mime_type: args.mimeType,
          file_name: args.fileName,
          context_type: "purchase_invoice",
          context_id: args.sageInvoiceId,
        },
      },
    });
  }

  return attempts;
}
