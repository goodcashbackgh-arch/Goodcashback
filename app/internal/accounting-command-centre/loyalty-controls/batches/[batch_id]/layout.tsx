import RetireControlBanner from "./RetireControlBanner";

type Params = { batch_id: string } | Promise<{ batch_id: string }>;

export default async function LoyaltySageBatchLayout({ children, params }: { children: React.ReactNode; params: Params }) {
  const { batch_id: batchId } = await Promise.resolve(params);

  return (
    <>
      <RetireControlBanner batchId={batchId} />
      {children}
    </>
  );
}
