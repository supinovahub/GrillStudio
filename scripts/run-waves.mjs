import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const REPOSITORY = "supinovahub/GrillStudio";
const DEFAULT_MODEL = "gpt-5.6-sol";
const DEFAULT_CONCURRENCY = 3;
const POLL_INTERVAL_MS = 20_000;
const MERGE_TIMEOUT_MS = 6 * 60 * 60 * 1_000;
const PREVIEW_TIMEOUT_MS = 15 * 60 * 1_000;
const SUPABASE_CLI_VERSION = "2.110.0";
const MAIN_PROJECT_REF = ["vummfrwi", "xxmshsepqqlz"].join("");
const REQUIRED_CHECKS = ["Agent verified", "quality", "Supabase Preview"];
const SUPABASE_ENVIRONMENT_KEYS = [
  "ANON_KEY",
  "API_URL",
  "DATABASE_URL",
  "DB_URL",
  "DIRECT_URL",
  "NEXT_PUBLIC_SUPABASE_ANON_KEY",
  "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
  "NEXT_PUBLIC_SUPABASE_URL",
  "POSTGRES_URL",
  "POSTGRES_URL_NON_POOLING",
  "PUBLISHABLE_KEY",
  "SERVICE_ROLE_KEY",
  "SUPABASE_ANON_KEY",
  "SUPABASE_BRANCH_ID",
  "SUPABASE_BRANCH_NAME",
  "SUPABASE_PUBLISHABLE_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_URL",
];

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: "utf8",
    env: options.env ?? process.env,
    stdio: options.capture ? "pipe" : "inherit",
  });

  if (result.status !== 0) {
    const detail = options.sensitive
      ? result.stderr
      : [result.stdout, result.stderr].filter(Boolean).join("\n");
    throw new Error(
      `${command} ${args.join(" ")} failed with ${result.status}${
        detail ? `\n${detail}` : ""
      }`,
    );
  }

  return result.stdout?.trim() ?? "";
}

function withoutSupabaseCredentials(environment = process.env) {
  return Object.fromEntries(
    Object.entries(environment).filter(
      ([key]) =>
        !SUPABASE_ENVIRONMENT_KEYS.includes(key) &&
        !key.startsWith("SUPABASE_") &&
        !key.startsWith("POSTGRES_") &&
        !["PGDATABASE", "PGHOST", "PGPASSWORD", "PGPORT", "PGUSER"].includes(
          key,
        ),
    ),
  );
}

function environmentWithNode(environment = process.env) {
  const nodeDirectory = path.dirname(process.execPath);
  const currentPath = environment.PATH ?? "";
  return {
    ...environment,
    PATH: [nodeDirectory, currentPath].filter(Boolean).join(path.delimiter),
  };
}

function ghJson(args, cwd) {
  return JSON.parse(run("gh", args, { cwd, capture: true }));
}

function parseBlockers(body) {
  const section = body.match(/## Blocked by\s*([\s\S]*?)(?=\n## |\s*$)/i);
  if (!section || /\bnone\b/i.test(section[1])) {
    return [];
  }

  return [...section[1].matchAll(/#(\d+)/g)].map((match) => Number(match[1]));
}

function hasLabel(issue, label) {
  return issue.labels.some((candidate) => candidate.name === label);
}

function nativeOpenBlockers(repoRoot, issues) {
  if (issues.length === 0) {
    return new Map();
  }

  const selections = issues
    .map(
      (issue) =>
        `issue${issue.number}: issue(number: ${issue.number}) { blockedBy(first: 100) { nodes { number state } } }`,
    )
    .join("\n");
  const result = ghJson(
    [
      "api",
      "graphql",
      "-f",
      `query={ repository(owner: "supinovahub", name: "GrillStudio") { ${selections} } }`,
    ],
    repoRoot,
  );
  const repository = result.data.repository;

  return new Map(
    issues.map((issue) => [
      issue.number,
      repository[`issue${issue.number}`].blockedBy.nodes
        .filter((blocker) => blocker.state === "OPEN")
        .map((blocker) => blocker.number),
    ]),
  );
}

function getFrontier(repoRoot) {
  const openIssues = ghJson(
    [
      "issue",
      "list",
      "--repo",
      REPOSITORY,
      "--state",
      "open",
      "--limit",
      "100",
      "--json",
      "number,title,body,url,labels,assignees",
    ],
    repoRoot,
  );
  const openNumbers = new Set(openIssues.map((issue) => issue.number));
  const tickets = openIssues.filter((issue) => /^T\d+\s+—/.test(issue.title));
  const nativeBlockers = nativeOpenBlockers(repoRoot, tickets);

  return tickets
    .filter((issue) => hasLabel(issue, "ready-for-agent"))
    .filter((issue) => !hasLabel(issue, "ready-for-human"))
    .filter((issue) => issue.assignees.length === 0)
    .filter((issue) =>
      parseBlockers(issue.body).every((blocker) => !openNumbers.has(blocker)),
    )
    .filter((issue) => nativeBlockers.get(issue.number).length === 0)
    .sort((left, right) => left.number - right.number);
}

function assertTicketMergeable(repoRoot, issueNumber) {
  const issue = ghJson(
    [
      "issue",
      "view",
      String(issueNumber),
      "--repo",
      REPOSITORY,
      "--json",
      "state,body,labels",
    ],
    repoRoot,
  );
  const openIssueNumbers = new Set(
    ghJson(
      [
        "issue",
        "list",
        "--repo",
        REPOSITORY,
        "--state",
        "open",
        "--limit",
        "100",
        "--json",
        "number",
      ],
      repoRoot,
    ).map((candidate) => candidate.number),
  );
  const nativeBlockers =
    nativeOpenBlockers(repoRoot, [{ number: issueNumber }]).get(issueNumber) ??
    [];

  if (issue.state !== "OPEN") {
    throw new Error(`Issue #${issueNumber} is no longer open`);
  }
  if (!hasLabel(issue, "ready-for-agent")) {
    throw new Error(`Issue #${issueNumber} lost ready-for-agent`);
  }
  if (hasLabel(issue, "ready-for-human")) {
    throw new Error(`Issue #${issueNumber} now requires a human`);
  }
  if (
    parseBlockers(issue.body).some((blocker) =>
      openIssueNumbers.has(blocker),
    ) ||
    nativeBlockers.length > 0
  ) {
    throw new Error(`Issue #${issueNumber} has an open blocker`);
  }
}

function slugFor(issue) {
  const ticket = issue.title.match(/^(T\d+)/)?.[1]?.toLowerCase() ?? "ticket";
  return `${ticket}-issue-${issue.number}`;
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function parseEnvironment(output) {
  const environment = {};

  for (const line of output.split("\n")) {
    const match = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (!match) {
      continue;
    }

    const [, key, rawValue] = match;
    let value = rawValue;
    if (rawValue.startsWith('"') && rawValue.endsWith('"')) {
      value = JSON.parse(rawValue);
    } else if (rawValue.startsWith("'") && rawValue.endsWith("'")) {
      value = rawValue.slice(1, -1);
    }
    environment[key] = value;
  }

  return environment;
}

function resolvePreviewEnvironment(worktree, branch, prNumber) {
  const managementEnvironment = environmentWithNode(process.env);
  const cleanEnvironment = environmentWithNode(withoutSupabaseCredentials());
  const output = run(
    "pnpm",
    [
      "dlx",
      `supabase@${SUPABASE_CLI_VERSION}`,
      "branches",
      "get",
      branch,
      "--project-ref",
      MAIN_PROJECT_REF,
      "--output",
      "env",
    ],
    {
      cwd: worktree,
      capture: true,
      env: managementEnvironment,
      sensitive: true,
    },
  );
  const branchEnvironment = parseEnvironment(output);
  const supabaseUrl =
    branchEnvironment.SUPABASE_URL ?? branchEnvironment.API_URL;
  const publicKey =
    branchEnvironment.SUPABASE_PUBLISHABLE_KEY ??
    branchEnvironment.PUBLISHABLE_KEY ??
    branchEnvironment.SUPABASE_ANON_KEY ??
    branchEnvironment.ANON_KEY;
  const serviceRoleKey =
    branchEnvironment.SUPABASE_SERVICE_ROLE_KEY ??
    branchEnvironment.SERVICE_ROLE_KEY;
  const databaseUrl =
    branchEnvironment.POSTGRES_URL_NON_POOLING ??
    branchEnvironment.POSTGRES_URL;

  if (!supabaseUrl || !publicKey || !serviceRoleKey || !databaseUrl) {
    throw new Error(
      `Preview Branch ${branch} did not return the required credentials`,
    );
  }
  if (supabaseUrl.includes(MAIN_PROJECT_REF)) {
    throw new Error(`Preview Branch ${branch} resolved to the main project`);
  }
  const previewProjectRef = new URL(supabaseUrl).hostname.split(".")[0];
  if (!/^[a-z0-9]{20}$/.test(previewProjectRef)) {
    throw new Error(`Preview Branch ${branch} returned an invalid project ref`);
  }
  if (!Number.isInteger(prNumber) || prNumber < 1) {
    throw new Error(`Preview Branch ${branch} is missing its pull request`);
  }

  return {
    ...cleanEnvironment,
    ...branchEnvironment,
    APP_BASE_URL: "http://127.0.0.1:3000",
    APP_ENVIRONMENT: "preview",
    APP_EXPECTED_GIT_BRANCH: branch,
    APP_EXPECTED_SUPABASE_PROJECT_REF: previewProjectRef,
    DATABASE_URL: databaseUrl,
    GIT_BRANCH: branch,
    GITHUB_PR_NUMBER: String(prNumber),
    NEXT_PUBLIC_SUPABASE_ANON_KEY: publicKey,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: publicKey,
    NEXT_PUBLIC_SUPABASE_URL: supabaseUrl,
    PLAYWRIGHT_BROWSERS_PATH: path.join(
      worktree,
      ".orchestrator",
      "playwright",
    ),
    PREVIEW_AUTH_EMAIL_ALLOWLIST: "@example.com",
    SUPABASE_ANON_KEY: publicKey,
    SUPABASE_BRANCH_NAME: branch,
    SUPABASE_SERVICE_ROLE_KEY: serviceRoleKey,
    SUPABASE_URL: supabaseUrl,
  };
}

function packageHasScript(worktree, script, environment) {
  const result = spawnSync(
    process.execPath,
    [
      "-e",
      `const p=require('./package.json'); process.exit(p.scripts?.[${JSON.stringify(
        script,
      )}] ? 0 : 1)`,
    ],
    { cwd: worktree, env: environment, stdio: "ignore" },
  );
  return result.status === 0;
}

function verifyPreviewDatabase(worktree, environment) {
  const databaseUrl = environment.DATABASE_URL;
  if (!databaseUrl) {
    throw new Error("Preview Branch database URL is required for lint");
  }

  const result = spawnSync(
    "pnpm",
    [
      "dlx",
      `supabase@${SUPABASE_CLI_VERSION}`,
      "db",
      "lint",
      "--db-url",
      databaseUrl,
      "--schema",
      "public,private,audit",
      "--level",
      "warning",
      "--fail-on",
      "error",
    ],
    {
      cwd: worktree,
      env: environment,
      stdio: "inherit",
    },
  );

  if (result.status !== 0) {
    throw new Error("Supabase Preview database lint failed");
  }
}

function verifyImplementation(worktree, environment) {
  run(process.execPath, ["scripts/validate-cloud-boundary.mjs"], {
    cwd: worktree,
    env: environment,
  });
  run("git", ["diff", "--check", "origin/main...HEAD"], {
    cwd: worktree,
    env: environment,
  });

  if (!existsSync(path.join(worktree, "package.json"))) {
    return;
  }
  if (!existsSync(path.join(worktree, "pnpm-lock.yaml"))) {
    throw new Error("package.json exists without pnpm-lock.yaml");
  }

  run("pnpm", ["install", "--frozen-lockfile"], {
    cwd: worktree,
    env: environment,
  });
  for (const script of [
    "lint",
    "typecheck",
    "test:unit",
    "build",
  ]) {
    if (packageHasScript(worktree, script, environment)) {
      run("pnpm", [script], { cwd: worktree, env: environment });
    }
  }
  verifyPreviewDatabase(worktree, environment);
  if (packageHasScript(worktree, "test:blackbox", environment)) {
    run("pnpm", ["exec", "playwright", "install", "chromium"], {
      cwd: worktree,
      env: environment,
    });
    run("pnpm", ["test:blackbox"], { cwd: worktree, env: environment });
  }
}

function setAgentStatus(repoRoot, sha, state, description) {
  run(
    "gh",
    [
      "api",
      `repos/${REPOSITORY}/statuses/${sha}`,
      "--method",
      "POST",
      "-f",
      `state=${state}`,
      "-f",
      "context=Agent verified",
      "-f",
      `description=${description}`,
    ],
    { cwd: repoRoot },
  );
}

async function runCodex(worktree, issue, model, previewEnvironment) {
  const prompt = [
    `Use /implement ${issue.url}.`,
    "Work only on this ticket and follow AGENTS.md, CONTEXT.md and the accepted ADRs.",
    "The branch and draft PR already exist. Do not merge or close the PR.",
    "Use only the Supabase Preview Branch corresponding to this PR.",
    "Never use the main Supabase project and never start Supabase locally.",
    "Keep providers simulated or allowlisted. Do not invent credentials or gates.",
    "Run the required checks, use /code-review origin/main and commit all changes.",
    "If a required Preview Branch, credential, provider asset or human gate is unavailable, stop safely and report the exact blocker without weakening acceptance criteria.",
  ].join("\n");

  const child = spawn(
    "codex",
    [
      "exec",
      "--ephemeral",
      "--model",
      model,
      "--sandbox",
      "workspace-write",
      "--config",
      'approval_policy="never"',
      "--config",
      "sandbox_workspace_write.network_access=true",
      "--cd",
      worktree,
      prompt,
    ],
    {
      cwd: worktree,
      env: previewEnvironment,
      stdio: "inherit",
    },
  );

  const exitCode = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", resolve);
  });

  if (exitCode !== 0) {
    throw new Error(`Codex exited with ${exitCode} for issue #${issue.number}`);
  }
}

function currentPr(repoRoot, branch) {
  const prs = ghJson(
    [
      "pr",
      "list",
      "--repo",
      REPOSITORY,
      "--head",
      branch,
      "--state",
      "open",
      "--json",
      "number,url,isDraft,mergeStateStatus",
    ],
    repoRoot,
  );

  if (prs.length !== 1) {
    throw new Error(
      `Expected exactly one open PR for ${branch}, found ${prs.length}`,
    );
  }

  return prs[0];
}

function checksForPr(repoRoot, prNumber) {
  const result = ghJson(
    [
      "pr",
      "view",
      String(prNumber),
      "--repo",
      REPOSITORY,
      "--json",
      "statusCheckRollup",
    ],
    repoRoot,
  );

  return result.statusCheckRollup.map((check) => {
    const name = check.name ?? check.context ?? "unknown";
    const terminalState = check.conclusion ?? check.state;
    const pending =
      check.status && !["COMPLETED", "SUCCESS"].includes(check.status);
    const passed = ["SUCCESS", "NEUTRAL"].includes(terminalState);
    const skipped = terminalState === "SKIPPED";
    const failed =
      !pending &&
      terminalState &&
      !passed &&
      !skipped &&
      terminalState !== "PENDING";

    return { name, pending, passed, skipped, failed, terminalState };
  });
}

async function waitForSupabasePreview(repoRoot, prNumber) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < PREVIEW_TIMEOUT_MS) {
    const checks = checksForPr(repoRoot, prNumber);
    const previewChecks = checks.filter((check) =>
      check.name.toLowerCase().includes("supabase preview"),
    );

    // Supabase briefly reports SKIPPED while provisioning a new Preview Branch,
    // then transitions the same check through pending to success. Treat SKIPPED
    // as non-terminal here; a truly unavailable preview will hit the timeout.
    if (previewChecks.some((check) => check.failed)) {
      throw new Error(`Supabase Preview failed for PR #${prNumber}`);
    }

    if (
      previewChecks.length > 0 &&
      previewChecks.every((check) => check.passed)
    ) {
      return;
    }

    await wait(POLL_INTERVAL_MS);
  }

  throw new Error(
    `Supabase Preview did not become healthy for PR #${prNumber}`,
  );
}

async function waitForRequiredChecks(repoRoot, prNumber) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < MERGE_TIMEOUT_MS) {
    const checks = checksForPr(repoRoot, prNumber);
    const required = REQUIRED_CHECKS.map((name) => ({
      name,
      check: checks.find((candidate) => candidate.name === name),
    }));
    const failed = required.filter(
      ({ check }) => check?.failed || check?.skipped,
    );

    if (failed.length > 0) {
      throw new Error(
        `PR #${prNumber} failed required checks: ${failed
          .map(({ name }) => name)
          .join(", ")}`,
      );
    }
    if (required.every(({ check }) => check?.passed)) {
      return;
    }

    await wait(POLL_INTERVAL_MS);
  }

  throw new Error(`Required checks did not pass for PR #${prNumber}`);
}

async function verifyCurrentHead({
  repoRoot,
  worktree,
  branch,
  prNumber,
  issueNumber,
}) {
  await waitForSupabasePreview(repoRoot, prNumber);
  const sha = run("git", ["rev-parse", "HEAD"], {
    cwd: worktree,
    capture: true,
  });
  const previewEnvironment = resolvePreviewEnvironment(
    worktree,
    branch,
    prNumber,
  );
  setAgentStatus(repoRoot, sha, "pending", "Validating against Preview Branch");

  try {
    verifyImplementation(worktree, previewEnvironment);
  } catch (error) {
    setAgentStatus(repoRoot, sha, "failure", "Automated verification failed");
    throw error;
  }

  setAgentStatus(
    repoRoot,
    sha,
    "success",
    "Preview Branch verification passed",
  );
  await waitForRequiredChecks(repoRoot, prNumber);
  assertTicketMergeable(repoRoot, issueNumber);
}

async function waitForMerge({
  repoRoot,
  worktree,
  branch,
  prNumber,
  issueNumber,
}) {
  const startedAt = Date.now();

  while (Date.now() - startedAt < MERGE_TIMEOUT_MS) {
    const state = ghJson(
      [
        "pr",
        "view",
        String(prNumber),
        "--repo",
        REPOSITORY,
        "--json",
        "state,mergedAt,mergeStateStatus",
      ],
      repoRoot,
    );

    if (state.mergedAt) {
      return;
    }

    if (state.state !== "OPEN") {
      throw new Error(`PR #${prNumber} closed without merge`);
    }

    const checks = checksForPr(repoRoot, prNumber);
    const failedChecks = checks.filter((check) => check.failed);
    if (failedChecks.length > 0) {
      throw new Error(
        `PR #${prNumber} has failed checks: ${failedChecks
          .map((check) => `${check.name} (${check.terminalState})`)
          .join(", ")}`,
      );
    }

    if (state.mergeStateStatus === "BEHIND") {
      run("git", ["fetch", "origin"], { cwd: worktree });
      run("git", ["merge", "--no-edit", "origin/main"], { cwd: worktree });
      run("git", ["push", "origin", branch], { cwd: worktree });
      await verifyCurrentHead({
        repoRoot,
        worktree,
        branch,
        prNumber,
        issueNumber,
      });
    }

    await wait(POLL_INTERVAL_MS);
  }

  throw new Error(`Timed out waiting for PR #${prNumber} to merge`);
}

function cleanupFailedTicket({
  repoRoot,
  worktree,
  branch,
  issueNumber,
  prNumber,
  worktreeCreated,
  issueAssigned,
}) {
  if (prNumber) {
    try {
      run(
        "gh",
        [
          "pr",
          "close",
          String(prNumber),
          "--repo",
          REPOSITORY,
          "--comment",
          "Automação pausada com falha fechada. A Preview Branch foi encerrada; consulte os logs locais antes de retomar.",
        ],
        { cwd: repoRoot },
      );
    } catch (error) {
      console.error(`Could not close PR #${prNumber}: ${error.message}`);
    }
  }

  if (issueAssigned) {
    try {
      run(
        "gh",
        [
          "issue",
          "edit",
          String(issueNumber),
          "--repo",
          REPOSITORY,
          "--remove-assignee",
          "@me",
        ],
        { cwd: repoRoot },
      );
    } catch (error) {
      console.error(
        `Could not unassign issue #${issueNumber}: ${error.message}`,
      );
    }
  }

  if (!worktreeCreated) {
    return;
  }

  try {
    let status = run("git", ["status", "--porcelain"], {
      cwd: worktree,
      capture: true,
    });
    let commitCount = Number(
      run("git", ["rev-list", "--count", "origin/main..HEAD"], {
        cwd: worktree,
        capture: true,
      }),
    );

    let recoveryBundle;
    if (status || commitCount > 1) {
      if (status) {
        run("git", ["add", "-A"], { cwd: worktree });
        run(
          "git",
          [
            "commit",
            "--no-verify",
            "-m",
            `Preserve failed automation #${issueNumber}`,
          ],
          { cwd: worktree },
        );
        status = "";
        commitCount += 1;
      }

      const failureDirectory = path.join(repoRoot, ".orchestrator", "failures");
      mkdirSync(failureDirectory, { recursive: true });
      recoveryBundle = path.join(
        failureDirectory,
        `issue-${issueNumber}-${Date.now()}.bundle`,
      );
      run("git", ["bundle", "create", recoveryBundle, branch], {
        cwd: repoRoot,
      });
      run("git", ["bundle", "verify", recoveryBundle], { cwd: repoRoot });
    }

    if (!status) {
      run("git", ["worktree", "remove", worktree], { cwd: repoRoot });
      const remoteBranch = run(
        "git",
        ["ls-remote", "--heads", "origin", branch],
        { cwd: repoRoot, capture: true },
      );
      if (remoteBranch) {
        run("git", ["push", "origin", "--delete", branch], { cwd: repoRoot });
      }
      run("git", ["branch", "--delete", "--force", branch], { cwd: repoRoot });
      if (recoveryBundle) {
        console.error(`Failure preserved in bundle: ${recoveryBundle}`);
      }
    } else {
      console.error(`Failure worktree preserved for recovery: ${worktree}`);
    }
  } catch (error) {
    console.error(`Could not reconcile failed worktree: ${error.message}`);
  }
}

async function executeTicket({ repoRoot, worktreeRoot, issue, model }) {
  const slug = slugFor(issue);
  const branch = `agent/${slug}`;
  const worktree = path.join(worktreeRoot, `issue-${issue.number}`);
  let worktreeCreated = false;
  let issueAssigned = false;
  let prNumber;

  if (existsSync(worktree)) {
    throw new Error(`Worktree path already exists: ${worktree}`);
  }

  try {
    assertTicketMergeable(repoRoot, issue.number);
    run("git", ["fetch", "--prune", "origin"], { cwd: repoRoot });
    run("git", ["worktree", "add", "-b", branch, worktree, "origin/main"], {
      cwd: repoRoot,
    });
    worktreeCreated = true;
    run("git", ["commit", "--allow-empty", "-m", `Start #${issue.number}`], {
      cwd: worktree,
    });
    run("git", ["push", "--set-upstream", "origin", branch], {
      cwd: worktree,
    });
    run(
      "gh",
      [
        "issue",
        "edit",
        String(issue.number),
        "--repo",
        REPOSITORY,
        "--add-assignee",
        "@me",
      ],
      { cwd: repoRoot },
    );
    issueAssigned = true;
    run(
      "gh",
      [
        "pr",
        "create",
        "--repo",
        REPOSITORY,
        "--draft",
        "--base",
        "main",
        "--head",
        branch,
        "--title",
        issue.title,
        "--body",
        `Closes #${issue.number}\n\nImplementação automática da onda.`,
      ],
      { cwd: worktree, capture: true },
    );

    const initialPr = currentPr(repoRoot, branch);
    prNumber = initialPr.number;
    await waitForSupabasePreview(repoRoot, prNumber);
    const previewEnvironment = resolvePreviewEnvironment(
      worktree,
      branch,
      prNumber,
    );
    await runCodex(worktree, issue, model, previewEnvironment);

    const status = run("git", ["status", "--porcelain"], {
      cwd: worktree,
      capture: true,
    });
    if (status) {
      throw new Error(
        `Agent left uncommitted changes for #${issue.number}:\n${status}`,
      );
    }

    const commitCount = Number(
      run("git", ["rev-list", "--count", "origin/main..HEAD"], {
        cwd: worktree,
        capture: true,
      }),
    );
    if (commitCount < 2) {
      throw new Error(
        `Agent produced no implementation commit for #${issue.number}`,
      );
    }

    run("git", ["fetch", "origin"], { cwd: worktree });
    run("git", ["merge", "--no-edit", "origin/main"], { cwd: worktree });
    run("git", ["push", "origin", branch], { cwd: worktree });

    await verifyCurrentHead({
      repoRoot,
      worktree,
      branch,
      prNumber,
      issueNumber: issue.number,
    });
    run("gh", ["pr", "ready", String(prNumber), "--repo", REPOSITORY], {
      cwd: repoRoot,
    });
    assertTicketMergeable(repoRoot, issue.number);
    run(
      "gh",
      [
        "pr",
        "merge",
        String(prNumber),
        "--repo",
        REPOSITORY,
        "--auto",
        "--squash",
        "--delete-branch",
      ],
      { cwd: repoRoot },
    );

    await waitForMerge({
      repoRoot,
      worktree,
      branch,
      prNumber,
      issueNumber: issue.number,
    });

    run("git", ["worktree", "remove", worktree], { cwd: repoRoot });
    worktreeCreated = false;
    run("git", ["branch", "--delete", "--force", branch], { cwd: repoRoot });
  } catch (error) {
    cleanupFailedTicket({
      repoRoot,
      worktree,
      branch,
      issueNumber: issue.number,
      prNumber,
      worktreeCreated,
      issueAssigned,
    });
    throw error;
  }
}

function parseArguments(argv) {
  const runMode = argv.includes("--run");
  const once = argv.includes("--once");
  const concurrencyArgument = argv.find((argument) =>
    argument.startsWith("--max="),
  );
  const modelArgument = argv.find((argument) =>
    argument.startsWith("--model="),
  );
  const concurrency = concurrencyArgument
    ? Number(concurrencyArgument.split("=")[1])
    : DEFAULT_CONCURRENCY;

  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 5) {
    throw new Error("--max must be an integer from 1 to 5");
  }

  return {
    runMode,
    once,
    concurrency,
    model: modelArgument?.split("=")[1] || DEFAULT_MODEL,
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const repoRoot = run("git", ["rev-parse", "--show-toplevel"], {
    capture: true,
  });
  const worktreeRoot = path.join(
    path.dirname(repoRoot),
    `${path.basename(repoRoot)}-agent-worktrees`,
  );
  if (options.runMode) {
    mkdirSync(worktreeRoot, { recursive: true });
  }

  do {
    const frontier = getFrontier(repoRoot);
    const wave = frontier.slice(0, options.concurrency);

    console.log(
      JSON.stringify(
        {
          mode: options.runMode ? "run" : "plan",
          concurrency: options.concurrency,
          frontier: frontier.map(({ number, title, url }) => ({
            number,
            title,
            url,
          })),
          wave: wave.map((issue) => issue.number),
        },
        null,
        2,
      ),
    );

    if (!options.runMode || wave.length === 0) {
      return;
    }

    const results = await Promise.allSettled(
      wave.map((issue) =>
        executeTicket({
          repoRoot,
          worktreeRoot,
          issue,
          model: options.model,
        }),
      ),
    );
    const failures = results
      .map((result, index) => ({ result, issue: wave[index] }))
      .filter(({ result }) => result.status === "rejected");

    if (failures.length > 0) {
      for (const { result, issue } of failures) {
        console.error(`#${issue.number}: ${result.reason}`);
      }
      process.exitCode = 1;
      return;
    }
  } while (!options.once);
}

await main();
