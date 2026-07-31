import { redirect } from "next/navigation";

import { getActiveMemberRole } from "@/lib/operation/membership";

export default async function HomePage() {
  const role = await getActiveMemberRole();

  if (!role) {
    redirect("/entrar");
  }

  redirect(role === "broker" ? "/app/hoje" : "/app/central");
}
