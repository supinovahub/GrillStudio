import "server-only";

import { createClient } from "@supabase/supabase-js";

import { getPreviewEnvironment } from "@/lib/environment";
import { getSupabasePublicConfig } from "@/lib/supabase/config";
import type { Database } from "@/types/database";

export function createAdminClient() {
  getPreviewEnvironment();

  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) {
    throw new Error(
      "A credencial efêmera da Preview Branch não está disponível.",
    );
  }

  const { url } = getSupabasePublicConfig();
  return createClient<Database>(url, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}
