export function isPreviewAuthEmailAllowed(
  email: string,
  rawAllowlist: string | undefined,
): boolean {
  const normalizedEmail = email.trim().toLowerCase();
  if (!normalizedEmail || !rawAllowlist) {
    return false;
  }

  const allowlist = rawAllowlist
    .split(",")
    .map((candidate) => candidate.trim().toLowerCase())
    .filter((candidate) => candidate.includes("@"));

  return allowlist.includes(normalizedEmail);
}
