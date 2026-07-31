const DEFAULT_AUTH_REDIRECT = "/";

export function safeInternalPath(
  candidate: string | null | undefined,
): string {
  if (!candidate) {
    return DEFAULT_AUTH_REDIRECT;
  }

  let decoded: string;
  try {
    decoded = decodeURIComponent(candidate);
  } catch {
    return DEFAULT_AUTH_REDIRECT;
  }

  if (
    !decoded.startsWith("/") ||
    decoded.startsWith("//") ||
    decoded.includes("\\") ||
    /[\u0000-\u001f\u007f]/.test(decoded)
  ) {
    return DEFAULT_AUTH_REDIRECT;
  }

  return candidate;
}
