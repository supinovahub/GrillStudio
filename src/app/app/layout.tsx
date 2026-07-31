import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { safeInternalPath } from "@/lib/auth/redirects";
import { createClient } from "@/lib/supabase/server";

export default async function AuthenticatedLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();

  if (error || !data?.claims) {
    const requestPath = safeInternalPath(
      (await headers()).get("x-request-path"),
    );
    redirect(`/entrar?next=${encodeURIComponent(requestPath)}`);
  }

  return children;
}
