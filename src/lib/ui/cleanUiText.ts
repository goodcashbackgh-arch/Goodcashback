const UI_TEXT_REPLACEMENTS: Array<[RegExp, string]> = [
  [/\bMindee\b/g, "Document processor"],
  [/\bOCR\b/g, "document read"],
  [/\bPDF document read control\b/g, "PDF statement extraction"],
  [/\bSage Cloud\b/g, "accounting system"],
  [/\bpre-Sage readiness\b/gi, "accounting readiness"],
  [/\bSage readiness\b/gi, "accounting readiness"],
  [/\bSage posting\b/gi, "accounting posting"],
  [/\bposted to Sage\b/gi, "posted to accounting records"],
  [/\bSage invoice ID\b/gi, "accounting document ID"],
  [/\bSage reference\b/gi, "accounting reference"],
  [/\bSage\b/g, "accounting system"],
  [/\bDVA\/card\b/gi, "payment account"],
  [/\bDVA statement\b/gi, "payment statement"],
  [/\bFX\/card diff\b/gi, "FX/payment variance"],
  [/\bFX\/card\b/gi, "FX/payment"],
  [/\bshipper AP invoices\b/gi, "shipper charge records"],
  [/\bshipper AP invoice\b/gi, "shipper charge record"],
  [/\bshipper AP\b/gi, "shipper charges"],
  [/\bAP invoice\b/gi, "payable charge document"],
  [/\bsales invoices\b/gi, "final order documents"],
  [/\bsales invoice\b/gi, "final order document"],
  [/\bsupplier invoice\b/gi, "supplier charge document"],
  [/\bfinal balance\b/gi, "remaining order balance"],
  [/\bImporter funding\b/g, "Importer payment matching"],
  [/\bfunding\b/gi, "payment"],
  [/\bVAT\b/g, "tax"],
  [/\bHMRC\b/g, "compliance authority"],
  [/\bauth ref\b/gi, "payment reference"],
  [/\bledger\b/gi, "account record"],
];

export function cleanUiText(value: string | null | undefined): string {
  if (value === null || value === undefined) return "";
  let cleaned = String(value);

  for (const [pattern, replacement] of UI_TEXT_REPLACEMENTS) {
    cleaned = cleaned.replace(pattern, replacement);
  }

  return cleaned;
}
