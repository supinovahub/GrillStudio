import { describe, expect, it, vi } from "vitest";

import { createRequestContext, writeLog } from "@/lib/observability";

describe("request observability", () => {
  it("creates trace and correlation identifiers without personal data", () => {
    const context = createRequestContext();

    expect(context.traceId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(context.correlationId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
  });

  it("emits only allowlisted structured fields", () => {
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);

    writeLog("auth.login", {
      correlationId: "b4df1958-1c55-47df-a30f-354695cd5e71",
      outcome: "denied",
      traceId: "df9e6c13-734c-4969-b417-b195525b7002",
      unsafe: {
        email: "dono@example.invalid",
        password: "never-log-this",
      },
    });

    expect(info).toHaveBeenCalledOnce();
    const output = info.mock.calls[0]?.[0];
    expect(output).toContain('"event":"auth.login"');
    expect(output).toContain('"outcome":"denied"');
    expect(output).not.toContain("dono@example.invalid");
    expect(output).not.toContain("never-log-this");

    info.mockRestore();
  });
});
