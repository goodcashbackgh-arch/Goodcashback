"use client";

type Props = {
  formId: string;
  disabled?: boolean;
};

function setSelected(formId: string, checked: boolean) {
  const inputs = Array.from(
    document.querySelectorAll<HTMLInputElement>(
      `input[type="checkbox"][form="${formId}"][name="shipment_batch_id"][data-release-checkbox="true"]`
    )
  ).filter((input) => !input.disabled);

  for (const input of inputs) {
    input.checked = checked;
  }
}

export default function SelectionControls({ formId, disabled = false }: Props) {
  return (
    <div className="flex flex-wrap gap-2">
      <button
        type="button"
        disabled={disabled}
        onClick={() => setSelected(formId, true)}
        className="rounded-xl border border-emerald-300 bg-white px-3 py-2 text-xs font-semibold text-emerald-800 hover:bg-emerald-50 disabled:cursor-not-allowed disabled:border-slate-200 disabled:text-slate-400"
      >
        Select all
      </button>
      <button
        type="button"
        disabled={disabled}
        onClick={() => setSelected(formId, false)}
        className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-50 disabled:cursor-not-allowed disabled:border-slate-200 disabled:text-slate-400"
      >
        Unselect all
      </button>
    </div>
  );
}
