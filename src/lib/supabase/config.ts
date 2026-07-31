import { getPreviewEnvironment } from "@/lib/environment";

export function getSupabasePublicConfig() {
  getPreviewEnvironment();

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (!url || !publishableKey) {
    throw new Error("Preview Supabase public credentials are unavailable");
  }

  return { publishableKey, url };
}
