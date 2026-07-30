import { describe, expect, it } from "vitest";

import {
  EnvironmentConfigurationError,
  validatePreviewEnvironment,
} from "@/lib/environment";

const PREVIEW_REF = "abcdefghijklmnopqrst";
const MAIN_REF = ["vummfrwi", "xxmshsepqqlz"].join("");

function previewInput() {
  return {
    appEnvironment: "preview",
    expectedGitBranch: "agent/t01-issue-13",
    expectedProjectRef: PREVIEW_REF,
    gitBranch: "agent/t01-issue-13",
    prNumber: "60",
    supabaseBranchName: "agent/t01-issue-13",
    supabaseUrl: `https://${PREVIEW_REF}.supabase.co`,
  };
}

describe("validatePreviewEnvironment", () => {
  it("accepts only the matching PR Preview Branch", () => {
    expect(validatePreviewEnvironment(previewInput())).toEqual({
      branchName: "agent/t01-issue-13",
      label: "Preview segura — PR #60",
      prNumber: 60,
      projectRef: PREVIEW_REF,
      tone: "preview",
    });
  });

  it.each([
    ["the main project", { supabaseUrl: `https://${MAIN_REF}.supabase.co` }],
    ["another project", { supabaseUrl: "https://zyxwvutsrqponmlkjihg.supabase.co" }],
    ["another Git branch", { gitBranch: "agent/another-ticket" }],
    ["another Supabase branch", { supabaseBranchName: "agent/another-ticket" }],
    ["a missing PR number", { prNumber: undefined }],
  ])("refuses %s", (_name, override) => {
    expect(() =>
      validatePreviewEnvironment({ ...previewInput(), ...override }),
    ).toThrow(EnvironmentConfigurationError);
  });
});
