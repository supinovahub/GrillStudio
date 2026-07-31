declare const Deno: {
  env: { get(name: string): string | undefined };
  serve(handler: (request: Request) => Promise<Response>): void;
};

// @ts-expect-error Deno Edge Functions require the explicit TypeScript suffix.
import { createDurableWorkerHandler } from "../_shared/durable-worker-handler.ts";

Deno.serve(
  createDurableWorkerHandler((name: string) => Deno.env.get(name)),
);
