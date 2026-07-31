const DEFAULT_AUTH_REDIRECT = "/";

export function appBaseUrl(): string {
  const value = process.env.APP_BASE_URL;
  if (!value) {
    throw new Error("APP_BASE_URL is required for Auth redirects");
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
