import type { RequestContext } from "@/lib/observability";

export async function wakeDurableWorker(
  context: Pick<RequestContext, "correlationId" | "traceId">,
): Promise<boolean> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const wakeSecret = process.env.DURABLE_WORKER_WAKE_SECRET;
  if (!supabaseUrl || !serviceRoleKey || !wakeSecret) return false;

  try {
    const response = await fetch(
      `${supabaseUrl}/functions/v1/durable-worker`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${serviceRoleKey}`,
          "x-correlation-id": context.correlationId,
          "x-durable-worker-wake-secret": wakeSecret,
          "x-trace-id": context.traceId,
        },
        body: "{}",
        cache: "no-store",
        signal: AbortSignal.timeout(1_500),
      },
    );
    return response.ok;
  } catch {
    return false;
  }
}
