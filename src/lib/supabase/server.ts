import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { NextResponse } from "next/server";

import { getSupabasePublicConfig } from "@/lib/supabase/config";
import type { Database } from "@/types/database";

export async function createClient(response?: NextResponse) {
  const cookieStore = await cookies();
  const { publishableKey, url } = getSupabasePublicConfig();

  return createServerClient<Database>(url, publishableKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        if (response) {
          for (const { name, options, value } of cookiesToSet) {
            response.cookies.set(name, value, options);
          }
        }

        try {
          for (const { name, options, value } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Server Components cannot write cookies. Proxy handles refreshes.
        }
      },
    },
  });
}
