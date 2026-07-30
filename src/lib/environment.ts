const MAIN_SUPABASE_PROJECT_REF = ["vummfrwi", "xxmshsepqqlz"].join("");
const PROJECT_REF_PATTERN = /^[a-z0-9]{20}$/;
const PR_NUMBER_PATTERN = /^[1-9][0-9]*$/;

export class EnvironmentConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EnvironmentConfigurationError";
  }
}

export type PreviewEnvironmentInput = {
  appEnvironment?: string;
  expectedGitBranch?: string;
  expectedProjectRef?: string;
  gitBranch?: string;
  prNumber?: string;
  supabaseBranchName?: string;
  supabaseUrl?: string;
};

export type PreviewEnvironment = {
  branchName: string;
  label: string;
  prNumber: number;
  projectRef: string;
  tone: "preview";
};

function required(value: string | undefined, name: string): string {
  if (!value?.trim()) {
    throw new EnvironmentConfigurationError(`${name} is required in preview`);
  }

  return value.trim();
}

function projectRefFromUrl(rawUrl: string): string {
  let hostname: string;

  try {
    hostname = new URL(rawUrl).hostname;
  } catch {
    throw new EnvironmentConfigurationError(
      "NEXT_PUBLIC_SUPABASE_URL must be a valid URL",
    );
  }

  const match = hostname.match(/^([a-z0-9]{20})\.supabase\.co$/);
  if (!match?.[1]) {
    throw new EnvironmentConfigurationError(
      "NEXT_PUBLIC_SUPABASE_URL must use a hosted Supabase project",
    );
  }

  return match[1];
}

export function validatePreviewEnvironment(
  input: PreviewEnvironmentInput,
): PreviewEnvironment {
  if (input.appEnvironment !== "preview") {
    throw new EnvironmentConfigurationError(
      "APP_ENVIRONMENT must be preview for worktree and PR execution",
    );
  }

  const expectedProjectRef = required(
    input.expectedProjectRef,
    "APP_EXPECTED_SUPABASE_PROJECT_REF",
  );
  const expectedGitBranch = required(
    input.expectedGitBranch,
    "APP_EXPECTED_GIT_BRANCH",
  );
  const gitBranch = required(input.gitBranch, "GIT_BRANCH");
  const supabaseBranchName = required(
    input.supabaseBranchName,
    "SUPABASE_BRANCH_NAME",
  );
  const prNumber = required(input.prNumber, "GITHUB_PR_NUMBER");
  const projectRef = projectRefFromUrl(
    required(input.supabaseUrl, "NEXT_PUBLIC_SUPABASE_URL"),
  );

  if (!PROJECT_REF_PATTERN.test(expectedProjectRef)) {
    throw new EnvironmentConfigurationError(
      "APP_EXPECTED_SUPABASE_PROJECT_REF is malformed",
    );
  }

  if (!PR_NUMBER_PATTERN.test(prNumber)) {
    throw new EnvironmentConfigurationError("GITHUB_PR_NUMBER is malformed");
  }

  if (projectRef === MAIN_SUPABASE_PROJECT_REF) {
    throw new EnvironmentConfigurationError(
      "The main Supabase project is forbidden in preview execution",
    );
  }

  if (projectRef !== expectedProjectRef) {
    throw new EnvironmentConfigurationError(
      "The Supabase project does not match this pull request Preview Branch",
    );
  }

  if (
    gitBranch !== expectedGitBranch ||
    supabaseBranchName !== expectedGitBranch
  ) {
    throw new EnvironmentConfigurationError(
      "The Git branch and Supabase Preview Branch do not match",
    );
  }

  return {
    branchName: gitBranch,
    label: `Preview segura — PR #${prNumber}`,
    prNumber: Number(prNumber),
    projectRef,
    tone: "preview",
  };
}

export function getPreviewEnvironment(): PreviewEnvironment {
  return validatePreviewEnvironment({
    appEnvironment: process.env.APP_ENVIRONMENT,
    expectedGitBranch: process.env.APP_EXPECTED_GIT_BRANCH,
    expectedProjectRef: process.env.APP_EXPECTED_SUPABASE_PROJECT_REF,
    gitBranch: process.env.GIT_BRANCH,
    prNumber: process.env.GITHUB_PR_NUMBER,
    supabaseBranchName: process.env.SUPABASE_BRANCH_NAME,
    supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL,
  });
}
