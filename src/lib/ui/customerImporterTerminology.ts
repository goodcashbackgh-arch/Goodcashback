export function customerImporterTerminology(value: string | null | undefined) {
  if (!value) return value ?? "";

  return value
    .replace(/\bpre-sage\b/gi, "Pre-accounting")
    .replace(/\bsage posting\b/gi, "Accounting posting")
    .replace(/\bsage readiness\b/gi, "Accounting readiness")
    .replace(/\bmindee\s+ocr\b/gi, "Document extraction")
    .replace(/\bocr\b/gi, "Document extraction")
    .replace(/\bmindee\b/gi, "Document processor")
    .replace(/\bsage\b/gi, "Accounting system");
}
