export default function Notice({ message }: { message?: string | null }) {
  if (!message) return null;

  return <div className="mt-4 rounded-xl border border-green-300 bg-green-50 p-3 text-sm font-semibold text-green-900">{message}</div>;
}
