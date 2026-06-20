export default function Notice({ message }: { message?: string | null }) {
  if (!message) return null;
  return <div>{message}</div>;
}
