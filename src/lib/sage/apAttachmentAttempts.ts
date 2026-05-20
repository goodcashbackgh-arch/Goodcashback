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
  const endpointTemplate = text(args.configuredEndpointTemplate);
  const transactionId = text(args.sageTransactionId);

  const endpoints = endpointTemplate
    ? [
        endpointTemplate
          .replaceAll("{purchase_invoice_id}", encodeURIComponent(args.sageInvoiceId))
          .replaceAll("{transaction_id}", encodeURIComponent(transactionId))
          .replaceAll("{id}", encodeURIComponent(args.sageInvoiceId))
          .replaceAll("{sage_object_id}", encodeURIComponent(args.sageInvoiceId)),
      ]
    : transactionId
      ? [`/transactions/${encodeURIComponent(transactionId)}/attachments`, "/attachments"]
      : ["/attachments"];

  const redacted = `[encoded PDF redacted; ${args.byteLength} bytes]`;
  const baseAttachment = {
    file: args.encodedFile,
    mime_type: args.mimeType,
    file_name: args.fileName,
  };
  const auditBaseAttachment = {
    file: redacted,
    mime_type: args.mimeType,
    file_name: args.fileName,
  };

  const attempts: SageAttachmentJsonAttempt[] = [];

  for (const endpoint of endpoints) {
    if (endpoint.startsWith("/transactions/")) {
      attempts.push({
        endpoint,
        label: "json_transaction_endpoint_required_fields",
        payload: { attachment: baseAttachment },
        auditPayload: { attachment: auditBaseAttachment },
      });
      continue;
    }

    if (transactionId) {
      attempts.push({
        endpoint,
        label: "json_required_fields_with_transaction_context",
        payload: {
          attachment: {
            ...baseAttachment,
            context_type: "transaction",
            context_id: transactionId,
          },
        },
        auditPayload: {
          attachment: {
            ...auditBaseAttachment,
            context_type: "transaction",
            context_id: transactionId,
          },
        },
      });

      attempts.push({
        endpoint,
        label: "json_required_fields_with_transaction_id",
        payload: {
          attachment: {
            ...baseAttachment,
            transaction_id: transactionId,
          },
        },
        auditPayload: {
          attachment: {
            ...auditBaseAttachment,
            transaction_id: transactionId,
          },
        },
      });

      attempts.push({
        endpoint,
        label: "json_required_fields_with_transaction_object",
        payload: {
          attachment: {
            ...baseAttachment,
            transaction: { id: transactionId },
          },
        },
        auditPayload: {
          attachment: {
            ...auditBaseAttachment,
            transaction: { id: transactionId },
          },
        },
      });
    }

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
      label: "json_required_fields_with_purchase_invoice_context",
      payload: {
        attachment: {
          ...baseAttachment,
          context_type: "purchase_invoice",
          context_id: args.sageInvoiceId,
        },
      },
      auditPayload: {
        attachment: {
          ...auditBaseAttachment,
          context_type: "purchase_invoice",
          context_id: args.sageInvoiceId,
        },
      },
    });
  }

  return attempts;
}
