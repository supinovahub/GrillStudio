import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const MAIN_PROJECT_REF = ["vummfrwi", "xxmshsepqqlz"].join("");
const runtimePrefixes = [
  ".github/",
  "app/",
  "apps/",
  "lib/",
  "packages/",
  "scripts/",
  "src/",
  "supabase/",
  "tests/",
];

const trackedFiles = execFileSync("git", ["ls-files", "-z"], {
  encoding: "utf8",
})
  .split("\0")
  .filter(Boolean);

const failures = [];
const trackedEnvironmentFiles = trackedFiles.filter((file) =>
  /(^|\/)\.env($|\.)/.test(file),
);

if (trackedEnvironmentFiles.length > 0) {
  failures.push(
    `Environment files must not be tracked: ${trackedEnvironmentFiles.join(", ")}`,
  );
}

for (const file of trackedFiles) {
  if (!runtimePrefixes.some((prefix) => file.startsWith(prefix))) {
    continue;
  }

  const contents = readFileSync(file, "utf8");

  if (contents.includes(MAIN_PROJECT_REF)) {
    failures.push(`${file} contains the main Supabase project reference`);
  }

  if (/\bsupabase\s+(start|stop)\b/.test(contents)) {
    failures.push(`${file} starts or stops a local Supabase stack`);
  }

  if (/\bsupabase\s+db\s+(reset|start)\b/.test(contents)) {
    failures.push(`${file} depends on a local Supabase database`);
  }

  if (
    /NEXT_PUBLIC_SUPABASE_URL\s*=\s*https:\/\/[^$\s]+\.supabase\.co/.test(
      contents,
    )
  ) {
    failures.push(`${file} hardcodes a Supabase runtime URL`);
  }
}

if (failures.length > 0) {
  console.error("Cloud boundary validation failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(
  `Cloud boundary validated across ${trackedFiles.length} tracked files.`,
);
