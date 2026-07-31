import { describe, expect, it } from "vitest";

import { isPreviewAuthEmailAllowed } from "@/lib/auth/email-policy";

describe("Preview Auth email allowlist", () => {
  it("allows only an exact normalized address", () => {
    expect(
      isPreviewAuthEmailAllowed(
        " dono@example.com ",
        "gestor@example.com,DONO@example.com",
      ),
    ).toBe(true);
  });

  it.each([
    ["dono@example.com", undefined],
    ["dono@example.com", ""],
    ["dono@example.com", "*"],
    ["outro@example.com", "dono@example.com"],
  ])("fails closed for %s with %s", (email, allowlist) => {
    expect(isPreviewAuthEmailAllowed(email, allowlist)).toBe(false);
  });
});
