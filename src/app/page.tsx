import { redirect } from "next/navigation";

import { getMemberWorkspace } from "@/lib/operation/shell";
import { createClient } from "@/lib/supabase/server";

export default async function HomePage() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();

  if (error || !data?.claims) {
    redirect("/entrar");
  }

  const workspace = await getMemberWorkspace();

  if (!workspace) {
    redirect("/entrar");
  }

  redirect(
    workspace.member_role === "broker" ? "/app/hoje" : "/app/central",
  );
}
