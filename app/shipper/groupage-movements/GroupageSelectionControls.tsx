"use client";

export default function GroupageSelectionControls({ fieldName, label }: { fieldName: string; label?: string }) {
  function setAll(checked: boolean) {
    const boxes = Array.from(document.querySelectorAll<HTMLInputElement>(`input[name="${fieldName}"]`));
    for (const box of boxes) {
      if (!box.disabled) box.checked = checked;
    }
  }

  return (
    <div className="flex flex-wrap items-center gap-2 rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm">
      <span className="font-semibold text-slate-700">{label ?? "Selection"}</span>
      <button type="button" onClick={() => setAll(true)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-100">
        Select all
      </button>
      <button type="button" onClick={() => setAll(false)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-100">
        Unselect all
      </button>
    </div>
  );
}
