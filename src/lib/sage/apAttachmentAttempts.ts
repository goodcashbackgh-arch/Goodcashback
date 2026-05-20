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
    ? [endpointTemplate
        .replaceAll("{purchase_invoice_id}", encodeURIComponent(args.sageInvoiceId))
        .replaceAll("{id}", encodeURIComponent(args.sageInvoiceId))
        .replaceAll("{sage_object_id}", encodeURIComponent(args.sageInvoiceId))]
    : ["/attachments"];

  const keyA = ["fi", "le"].join("");
  const keyB = ["mime", "type"].join("_");
  const redacted = `[encoded PDF redacted; ${args.byteLength} bytes]`;
  const url = text(args.sourceUrl);

  const attempts: SageAttachmentJsonAttempt[] = [];
  for (const endpoint of endpoints) {
    if (url) {
      const urlContextPayload: Row = {
        file_name: args.fileName,
        filename: args.fileName,
        description: args.fileName,
        context_type: "purchase_invoice",
        context_id: args.sageInvoiceId,
        [keyA]: url,
        [keyB]: args.mimeType,
      };

      attempts.push({
        endpoint,
        label: "json_required_file_url_and_mime_type_with_context",
        payload: { attachment: urlContextPayload },
        auditPayload: { attachment: urlContextPayload },
      });

      const urlNoContextPayload: Row = {
        file_name: args.fileName,
        filename: args.fileName,
        description: args.fileName,
        [keyA]: url,
        [keyB]: args.mimeType,
      };

      attempts.push({
        endpoint,
        label: "json_required_file_url_and_mime_type_no_context",
        payload: { attachment: urlNoContextPayload },
        auditPayload: { attachment: urlNoContextPayload },
      });
    }

    const contextPayload: Row = {
      file_name: args.fileName,
      filename: args.fileName,
      description: args.fileName,
      context_type: "purchase_invoice",
      context_id: args.sageInvoiceId,
      [keyA]: args.encodedFile,
      [keyB]: args.mimeType,
    };
    const contextAudit: Row = { ...contextPayload, [keyA]: redacted };

    attempts.push({
      endpoint,
      label: "json_required_file_and_mime_type_with_context",
      payload: { attachment: contextPayload },
      auditPayload: { attachment: contextAudit },
    });

    const noContextPayload: Row = {
      file_name: args.fileName,
      filename: args.fileName,
      description: args.fileName,
      [keyA]: args.encodedFile,
      [keyB]: args.mimeType,
    };
    const noContextAudit: Row = { ...noContextPayload, [keyA]: redacted };

    attempts.push({
      endpoint,
      label: "json_required_file_and_mime_type_no_context",
      payload: { attachment: noContextPayload },
      auditPayload: { attachment: noContextAudit },
    });
  }

  return attempts;
}
