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

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: "utf8",
    env: process.env,
    stdio: options.capture ? "pipe" : "inherit",
  });

  if (result.status !== 0) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join("\n");
    throw new Error(
      `${command} ${args.join(" ")} failed with ${result.status}${
        detail ? `\n${detail}` : ""
      }`,
    );
  }

  return result.stdout?.trim() ?? "";
}

function ghJson(args, cwd) {
  return JSON.parse(run("gh", args, { cwd, capture: true }));
}

function parseBlockers(body) {
  const section = body.match(/## Blocked by\s*([\s\S]*?)(?=\n## |\s*$)/i);
  if (!section || /\bnone\b/i.test(section[1])) {
    return [];
  }

  return [...section[1].matchAll(/#(\d+)/g)].map((match) =>
    Number(match[1]),
  );
}

function hasLabel(issue, label) {
  return issue.labels.some((candidate) => candidate.name === label);
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

  return openIssues
    .filter((issue) => /^T\d+\s+—/.test(issue.title))
    .filter((issue) => hasLabel(issue, "ready-for-agent"))
    .filter((issue) => !hasLabel(issue, "ready-for-human"))
    .filter((issue) => issue.assignees.length === 0)
    .filter((issue) =>
      parseBlockers(issue.body).every((blocker) => !openNumbers.has(blocker)),
    )
    .sort((left, right) => left.number - right.number);
}

function slugFor(issue) {
  const ticket = issue.title.match(/^(T\d+)/)?.[1]?.toLowerCase() ?? "ticket";
  return `${ticket}-issue-${issue.number}`;
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runCodex(worktree, issue, model) {
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
      "--cd",
      worktree,
      prompt,
    ],
    {
      cwd: worktree,
      env: process.env,
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
      !pending && terminalState && !passed && terminalState !== "PENDING";

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

    if (previewChecks.some((check) => check.failed || check.skipped)) {
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

async function waitForMerge({ repoRoot, worktree, branch, prNumber }) {
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
    }

    await wait(POLL_INTERVAL_MS);
  }

  throw new Error(`Timed out waiting for PR #${prNumber} to merge`);
}

async function executeTicket({ repoRoot, worktreeRoot, issue, model }) {
  const slug = slugFor(issue);
  const branch = `agent/${slug}`;
  const worktree = path.join(worktreeRoot, `issue-${issue.number}`);

  if (existsSync(worktree)) {
    throw new Error(`Worktree path already exists: ${worktree}`);
  }

  run("git", ["fetch", "--prune", "origin"], { cwd: repoRoot });
  run(
    "git",
    ["worktree", "add", "-b", branch, worktree, "origin/main"],
    { cwd: repoRoot },
  );
  run(
    "git",
    ["commit", "--allow-empty", "-m", `Start #${issue.number}`],
    { cwd: worktree },
  );
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
  await waitForSupabasePreview(repoRoot, initialPr.number);
  await runCodex(worktree, issue, model);

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
    throw new Error(`Agent produced no implementation commit for #${issue.number}`);
  }

  run("git", ["push", "origin", branch], { cwd: worktree });

  const pr = currentPr(repoRoot, branch);
  run(
    "gh",
    ["pr", "ready", String(pr.number), "--repo", REPOSITORY],
    { cwd: repoRoot },
  );
  run(
    "gh",
    [
      "pr",
      "merge",
      String(pr.number),
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
    prNumber: pr.number,
  });

  run("git", ["worktree", "remove", worktree], { cwd: repoRoot });
  run("git", ["branch", "--delete", "--force", branch], { cwd: repoRoot });
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
