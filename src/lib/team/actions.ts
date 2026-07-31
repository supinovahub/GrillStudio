"use server";

import { createHash } from "node:crypto";
import { headers } from "next/headers";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { getRequestContext } from "@/lib/auth/context";
import { isPreviewAuthEmailAllowed } from "@/lib/auth/email-policy";
import { appBaseUrl } from "@/lib/auth/redirects";
import { writeLog } from "@/lib/observability";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import type { ManagerPermission, MemberRole } from "@/lib/team/types";

const invitationTokenPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const whatsappPattern = /^\+[1-9][0-9]{7,14}$/;
const allowedRoles = new Set<MemberRole>(["manager", "broker"]);

function field(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function stringValues(formData: FormData, name: string): string[] {
  return formData
    .getAll(name)
    .filter((value): value is string => typeof value === "string")
    .map((value) => value.trim())
    .filter(Boolean);
}

function teamRedirect(result: string): never {
  redirect(`/app/configuracoes/equipe?resultado=${result}`);
}

export async function createIndividualInvitationAction(formData: FormData) {
  const email = field(formData, "email").toLowerCase();
  const operationId = field(formData, "operation_id");
  const roles = stringValues(formData, "roles").filter(
    (role): role is MemberRole => allowedRoles.has(role as MemberRole),
  );
  const context = await getRequestContext();

  if (!email || !operationId || roles.length === 0) {
    teamRedirect("convite-invalido");
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("create_individual_invitation", {
    invite_email: email,
    invite_operation_id: operationId,
    invite_roles: roles,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
  });

  writeLog("member.invitation_created", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    teamRedirect("convite-negado");
  }

  revalidatePath("/app/configuracoes/equipe");
  teamRedirect("convite-criado");
}

export async function createGeneralInvitationLinkAction(formData: FormData) {
  const operationId = field(formData, "operation_id");
  const context = await getRequestContext();
  const supabase = await createClient();
  const { error } = await supabase.rpc("create_general_invitation_link", {
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  writeLog("member.general_link_created", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    teamRedirect("link-negado");
  }

  revalidatePath("/app/configuracoes/equipe");
  teamRedirect("link-criado");
}

export async function setGeneralInvitationLinkStatusAction(
  formData: FormData,
) {
  const linkId = field(formData, "link_id");
  const status = field(formData, "status");
  const context = await getRequestContext();

  if (!linkId || !["active", "paused"].includes(status)) {
    teamRedirect("link-invalido");
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc(
    "set_general_invitation_link_status",
    {
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
      target_link_id: linkId,
      target_status: status,
    },
  );

  writeLog("member.general_link_status_changed", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    teamRedirect("link-negado");
  }

  revalidatePath("/app/configuracoes/equipe");
  teamRedirect(status === "paused" ? "link-pausado" : "link-retomado");
}

export async function regenerateGeneralInvitationLinkAction(
  formData: FormData,
) {
  const linkId = field(formData, "link_id");
  const context = await getRequestContext();
  const supabase = await createClient();
  const { error } = await supabase.rpc(
    "regenerate_general_invitation_link",
    {
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
      target_link_id: linkId,
    },
  );

  writeLog("member.general_link_regenerated", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    teamRedirect("link-negado");
  }

  revalidatePath("/app/configuracoes/equipe");
  teamRedirect("link-regenerado");
}

export async function approveMembershipAction(formData: FormData) {
  const membershipId = field(formData, "membership_id");
  const operationId = field(formData, "operation_id");
  const roles = stringValues(formData, "roles").filter(
    (role): role is MemberRole => allowedRoles.has(role as MemberRole),
  );
  const permissions = stringValues(
    formData,
    "permissions",
  ) as ManagerPermission[];
  const context = await getRequestContext();

  if (!membershipId || !operationId || roles.length === 0) {
    teamRedirect("aprovacao-invalida");
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("approve_membership", {
    approved_permissions: permissions,
    approved_roles: roles,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_membership_id: membershipId,
    target_operation_id: operationId,
  });

  writeLog("member.approved", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    teamRedirect(
      error.message.includes("email is not confirmed")
        ? "email-nao-confirmado"
        : "aprovacao-negada",
    );
  }

  revalidatePath("/app/configuracoes/equipe");
  teamRedirect("membro-aprovado");
}

export async function deactivateMembershipAction(formData: FormData) {
  const membershipId = field(formData, "membership_id");
  const operationId = field(formData, "operation_id");
  const password = field(formData, "password");
  const confirmed = formData.get("confirmation") === "on";
  const context = await getRequestContext();

  if (!membershipId || !operationId || !password || !confirmed) {
    teamRedirect("desativacao-invalida");
  }

  const supabase = await createClient();
  const { data: userData, error: userError } = await supabase.auth.getUser();
  const email = userData.user?.email;

  if (userError || !userData.user || !email) {
    redirect("/entrar");
  }

  const { error: reauthenticationError } =
    await supabase.auth.signInWithPassword({ email, password });
  if (reauthenticationError) {
    writeLog("member.deactivation_reauthentication", {
      ...context,
      outcome: "denied",
    });
    teamRedirect("senha-incorreta");
  }

  const admin = createAdminClient();
  const { error } = await admin.rpc(
    "deactivate_membership_after_reauthentication",
    {
      actor_user_id: userData.user.id,
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
      target_membership_id: membershipId,
      target_operation_id: operationId,
    },
  );

  writeLog("member.deactivated", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    teamRedirect("desativacao-negada");
  }

  revalidatePath("/app/configuracoes/equipe");
  teamRedirect("membro-desativado");
}

function invitationRedirect(token: string, result: string): never {
  redirect(`/convite/${token}?resultado=${result}`);
}

export async function registerFromInvitationAction(formData: FormData) {
  const token = field(formData, "token");
  const email = field(formData, "email").toLowerCase();
  const fullName = field(formData, "full_name");
  const whatsapp = field(formData, "whatsapp");
  const password = field(formData, "password");
  const passwordConfirmation = field(formData, "password_confirmation");
  const context = await getRequestContext();

  if (
    !invitationTokenPattern.test(token) ||
    !email ||
    !fullName ||
    !whatsappPattern.test(whatsapp) ||
    password.length < 12 ||
    password !== passwordConfirmation ||
    !isPreviewAuthEmailAllowed(
      email,
      process.env.PREVIEW_AUTH_EMAIL_ALLOWLIST,
    )
  ) {
    invitationRedirect(token, "cadastro-invalido");
  }

  const requestHeaders = await headers();
  const forwardedFor =
    requestHeaders.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const fingerprint = createHash("sha256")
    .update(`${forwardedFor}:${requestHeaders.get("user-agent") ?? "unknown"}`)
    .digest("hex");

  const admin = createAdminClient();
  const { data: reservation, error: reservationError } = await admin.rpc(
    "reserve_invitation_registration",
    {
      registration_email: email,
      registration_token: token,
      request_fingerprint: fingerprint,
    },
  );

  if (reservationError || reservation.length !== 1) {
    writeLog("member.registration_reserved", {
      ...context,
      outcome: "denied",
    });
    invitationRedirect(token, "convite-indisponivel");
  }

  const supabase = await createClient();
  const redirectTo = new URL("/auth/callback", appBaseUrl());
  redirectTo.searchParams.set("next", "/aguardando-aprovacao");
  const { data, error: signupError } = await supabase.auth.signUp({
    email,
    options: {
      emailRedirectTo: redirectTo.toString(),
    },
    password,
  });

  if (
    signupError ||
    !data.user ||
    (data.user.identities && data.user.identities.length === 0)
  ) {
    writeLog("member.registration_auth_created", {
      ...context,
      outcome: "failed",
    });
    invitationRedirect(token, "cadastro-indisponivel");
  }

  const { error: completionError } = await admin.rpc(
    "complete_invitation_registration",
    {
      registration_email: email,
      registration_full_name: fullName,
      registration_token: token,
      registration_user_id: data.user.id,
      registration_whatsapp: whatsapp,
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
    },
  );

  if (completionError) {
    await admin.auth.admin.deleteUser(data.user.id);
    writeLog("member.registration_completed", {
      ...context,
      outcome: "failed",
    });
    invitationRedirect(token, "cadastro-indisponivel");
  }

  writeLog("member.registration_completed", {
    ...context,
    outcome: "succeeded",
  });
  invitationRedirect(token, "aguardando-confirmacao");
}
