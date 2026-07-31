import { type NextRequest } from "next/server";

import { createRequestContext } from "@/lib/observability";
import { updateSession } from "@/lib/supabase/proxy";

export async function proxy(request: NextRequest) {
  const context = createRequestContext();
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("x-correlation-id", context.correlationId);
  requestHeaders.set(
    "x-request-path",
    `${request.nextUrl.pathname}${request.nextUrl.search}`,
  );
  requestHeaders.set("x-trace-id", context.traceId);

  const response = await updateSession(request, requestHeaders);
  response.headers.set("x-correlation-id", context.correlationId);
  response.headers.set("x-trace-id", context.traceId);
  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|icon.svg|sw.js|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
