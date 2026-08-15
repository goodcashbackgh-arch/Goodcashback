export function customerImporterTerminology(value: string | null | undefined) {
  if (!value) return value ?? "";

  return value
    .replace(/\bmindee\s+ocr\s+status\b/gi, "Document extraction status")
    .replace(/\bsend\s+to\s+mindee\s+ocr\b/gi, "Start document extraction")
    .replace(/\bfetch\/save\s+mindee\s+result\b/gi, "Fetch/save extraction result")
    .replace(/\bocr\s+control\s+room\b/gi, "Document review control")
    .replace(/\bocr\/header\s+issues\b/gi, "Document/header issues")
    .replace(/\bpre-sage\b/gi, "Pre-accounting")
    .replace(/\bsage posting\b/gi, "Accounting posting")
    .replace(/\bsage readiness\b/gi, "Accounting readiness")
    .replace(/\bmindee\s+ocr\b/gi, "Document extraction")
    .replace(/\bocr\b/gi, "Document extraction")
    .replace(/\bmindee\b/gi, "Document processor")
    .replace(/\bsage\b/gi, "Accounting system");
}
