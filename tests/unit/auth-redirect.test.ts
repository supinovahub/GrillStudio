import { describe, expect, it } from "vitest";

import { safeInternalPath } from "@/lib/auth/redirects";

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
