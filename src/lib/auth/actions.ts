"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { getRequestContext } from "@/lib/auth/context";
import { isPreviewAuthEmailAllowed } from "@/lib/auth/email-policy";
import { safeInternalPath } from "@/lib/auth/redirects";
import { writeLog } from "@/lib/observability";
import { createClient } from "@/lib/supabase/server";

function field(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function appBaseUrl(): string {
  const value = process.env.APP_BASE_URL;
  if (!value) {
    throw new Error("APP_BASE_URL is required for Auth email redirects");
  }

  const url = new URL(value);
  const isLocalHttp =
    url.protocol === "http:" &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1");

  if (url.protocol !== "https:" && !isLocalHttp) {
    throw new Error("APP_BASE_URL must use HTTPS outside localhost");
  }

  return url.origin;
}

export async function signInAction(formData: FormData) {
  const email = field(formData, "email");
  const password = field(formData, "password");
  const next = safeInternalPath(field(formData, "next"));
  const context = await getRequestContext();

  if (!email || !password) {
    redirect(`/entrar?erro=campos&next=${encodeURIComponent(next)}`);
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });

  if (error) {
    writeLog("auth.login", { ...context, outcome: "denied" });
    redirect(`/entrar?erro=credenciais&next=${encodeURIComponent(next)}`);
  }

  writeLog("auth.login", { ...context, outcome: "succeeded" });
  revalidatePath("/", "layout");
  redirect(next);
}

export async function requestPasswordResetAction(formData: FormData) {
  const email = field(formData, "email");
  const context = await getRequestContext();

  if (!email) {
    redirect("/recuperar-senha?erro=campos");
  }

  if (
    !isPreviewAuthEmailAllowed(
      email,
      process.env.PREVIEW_AUTH_EMAIL_ALLOWLIST,
    )
  ) {
    writeLog("auth.password_recovery_requested", {
      ...context,
      outcome: "denied",
    });
    redirect("/recuperar-senha?enviado=1");
  }

  const supabase = await createClient();
  const redirectTo = new URL("/auth/callback", appBaseUrl());
  redirectTo.searchParams.set("next", "/redefinir-senha");

  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: redirectTo.toString(),
  });

  writeLog("auth.password_recovery_requested", {
    ...context,
    outcome: error ? "failed" : "accepted",
  });

  redirect("/recuperar-senha?enviado=1");
}

export async function updatePasswordAction(formData: FormData) {
  const password = field(formData, "password");
  const confirmation = field(formData, "password_confirmation");
  const context = await getRequestContext();

  if (password.length < 12 || password !== confirmation) {
    redirect("/redefinir-senha?erro=senha");
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.updateUser({ password });

  if (error) {
    writeLog("auth.password_updated", { ...context, outcome: "failed" });
    redirect("/redefinir-senha?erro=indisponivel");
  }

  await supabase.auth.signOut({ scope: "global" });
  writeLog("auth.password_updated", { ...context, outcome: "succeeded" });
  redirect("/entrar?senha=alterada");
}

export async function signOutCurrentAction() {
  const supabase = await createClient();
  await supabase.auth.signOut({ scope: "local" });
  redirect("/entrar");
}

export async function signOutOtherSessionsAction() {
  const context = await getRequestContext();
  const supabase = await createClient();
  const { error } = await supabase.auth.signOut({ scope: "others" });

  writeLog("auth.other_sessions_ended", {
    ...context,
    outcome: error ? "failed" : "succeeded",
  });

  redirect(
    error
      ? "/app/central?sessao=erro"
      : "/app/central?sessao=outras-encerradas",
  );
}

export async function signOutAllSessionsAction() {
  const context = await getRequestContext();
  const supabase = await createClient();
  const { error } = await supabase.auth.signOut({ scope: "global" });

  writeLog("auth.all_sessions_ended", {
    ...context,
    outcome: error ? "failed" : "succeeded",
  });

  redirect("/entrar?sessao=encerrada");
}
