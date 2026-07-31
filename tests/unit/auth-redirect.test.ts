import { describe, expect, it } from "vitest";

import { appBaseUrl, safeInternalPath } from "@/lib/auth/redirects";

describe("appBaseUrl", () => {
  it("uses the configured canonical origin for Auth redirects", () => {
    const previous = process.env.APP_BASE_URL;
    process.env.APP_BASE_URL = "http://127.0.0.1:3000/path";

    expect(appBaseUrl()).toBe("http://127.0.0.1:3000");

    if (previous === undefined) {
      delete process.env.APP_BASE_URL;
    } else {
      process.env.APP_BASE_URL = previous;
    }
  });

  it("requires HTTPS outside local development", () => {
    const previous = process.env.APP_BASE_URL;
    process.env.APP_BASE_URL = "http://preview.example.com";

    expect(() => appBaseUrl()).toThrow(
      "APP_BASE_URL must use HTTPS outside localhost",
    );

    if (previous === undefined) {
      delete process.env.APP_BASE_URL;
    } else {
      process.env.APP_BASE_URL = previous;
    }
  });
});

describe("safeInternalPath", () => {
  it.each([
    ["/app/central", "/app/central"],
    ["/redefinir-senha?origem=email", "/redefinir-senha?origem=email"],
    [undefined, "/"],
  ])("keeps safe application paths", (value, expected) => {
    expect(safeInternalPath(value)).toBe(expected);
  });

  it.each([
    "https://example.com",
    "//example.com",
    "/\\example.com",
    "javascript:alert(1)",
    "app/central",
  ])("refuses an unsafe redirect: %s", (value) => {
    expect(safeInternalPath(value)).toBe("/");
  });
});
