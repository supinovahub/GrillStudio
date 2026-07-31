import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  forbidOnly: Boolean(process.env.CI),
  fullyParallel: false,
  outputDir: "test-results",
  reporter: process.env.CI ? [["github"], ["line"]] : "line",
  retries: process.env.CI ? 1 : 0,
  testDir: "tests/blackbox",
  timeout: 45_000,
  use: {
    baseURL: process.env.APP_BASE_URL ?? "http://127.0.0.1:3000",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "pnpm start",
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
    url: process.env.APP_BASE_URL ?? "http://127.0.0.1:3000",
  },
  workers: 1,
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
