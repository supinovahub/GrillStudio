// @ts-nocheck -- Supabase Edge Functions are type-checked by the Deno runtime.

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
};

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "worker_not_configured" }), {
      status: 503,
      headers: jsonHeaders,
    });
  }

  const response = await fetch(
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
});
