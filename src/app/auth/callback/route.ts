import { type NextRequest, NextResponse } from "next/server";

import { appBaseUrl, safeInternalPath } from "@/lib/auth/redirects";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");
  const next = safeInternalPath(request.nextUrl.searchParams.get("next"));

  if (code) {
    const response = NextResponse.redirect(new URL(next, appBaseUrl()));
    const supabase = await createClient(response);
    const { error } = await supabase.auth.exchangeCodeForSession(code);

    if (!error) {
      return response;
    }
  }

  return NextResponse.redirect(new URL("/entrar?erro=link", appBaseUrl()));
}
