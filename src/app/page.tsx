import { redirect } from "next/navigation";

import { getMemberWorkspace } from "@/lib/operation/shell";

export default async function HomePage() {
  const workspace = await getMemberWorkspace();

  if (!workspace) {
    redirect("/entrar");
  }

  redirect(
    workspace.member_role === "broker" ? "/app/hoje" : "/app/central",
  );
}
