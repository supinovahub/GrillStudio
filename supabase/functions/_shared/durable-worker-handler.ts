type EnvironmentReader = (name: string) => string | undefined;
type Fetcher = typeof fetch;

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
};

async function digestSecret(value: string): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return new Uint8Array(digest);
}

/**
 * Hashing both supplied values first gives the comparison a fixed byte length.
 * The loop always inspects every digest byte and never exposes either secret.
 */
export async function constantTimeSecretEqual(
  expected: string | undefined,
  supplied: string | null,
): Promise<boolean> {
  if (!expected || expected.length < 32 || supplied === null) return false;

  const [expectedDigest, suppliedDigest] = await Promise.all([
    digestSecret(expected),
    digestSecret(supplied),
  ]);
  let difference = 0;
  for (let index = 0; index < expectedDigest.length; index += 1) {
    difference |= expectedDigest[index] ^ suppliedDigest[index];
  }
  return difference === 0;
}

export function createDurableWorkerHandler(
  readEnvironment: EnvironmentReader,
  workerFetch: Fetcher = fetch,
) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return new Response(JSON.stringify({ error: "method_not_allowed" }), {
        status: 405,
        headers: jsonHeaders,
      });
    }

    const authorized = await constantTimeSecretEqual(
      readEnvironment("DURABLE_WORKER_WAKE_SECRET"),
      request.headers.get("x-durable-worker-wake-secret"),
    );
    if (!authorized) {
      return new Response(JSON.stringify({ error: "forbidden" }), {
        status: 403,
        headers: jsonHeaders,
      });
    }

    const supabaseUrl = readEnvironment("SUPABASE_URL");
    const serviceRoleKey = readEnvironment("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(JSON.stringify({ error: "worker_not_configured" }), {
        status: 503,
        headers: jsonHeaders,
      });
    }

    const response = await workerFetch(
      `${supabaseUrl}/rest/v1/rpc/run_durable_workers`,
      {
        method: "POST",
        headers: {
          ...jsonHeaders,
          apikey: serviceRoleKey,
          authorization: `Bearer ${serviceRoleKey}`,
        },
        body: JSON.stringify({ maximum_messages: 25 }),
        signal: AbortSignal.timeout(8_000),
      },
    );
    const body = await response.text();

    return new Response(body || JSON.stringify({ ok: response.ok }), {
      status: response.status,
      headers: jsonHeaders,
    });
  };
}
