import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import {
  initialState,
  invariantFailures,
  reduce,
  summarize,
} from "./delivery-model.mjs";

const alerts = {
  normal: {
    id: "notification-normal-001",
    revision: 1,
    severity: "normal",
    type: "conversation_needs_action",
  },
  background: {
    id: "notification-background-001",
    revision: 1,
    severity: "normal",
    type: "conversation_needs_action",
  },
  denied: {
    id: "notification-denied-001",
    revision: 1,
    severity: "normal",
    type: "integration_degraded",
  },
  critical: {
    id: "notification-critical-001",
    revision: 1,
    severity: "critical",
    type: "call_unassigned_t15",
  },
  invalid: {
    id: "notification-invalid-001",
    revision: 1,
    severity: "normal",
    type: "call_result_overdue",
  },
  read: {
    id: "notification-read-001",
    revision: 1,
    severity: "normal",
    type: "conversation_needs_action",
  },
};

function apply(state, actions) {
  return actions.reduce(reduce, state);
}

const scenarios = [
  {
    name: "foreground duplicate Realtime and push",
    actions: [
      { type: "server/create_alert", alert: alerts.normal },
      { type: "signal/realtime", notificationId: alerts.normal.id },
      { type: "signal/realtime", notificationId: alerts.normal.id },
      { type: "signal/push", notificationId: alerts.normal.id },
      { type: "signal/push", notificationId: alerts.normal.id },
      { type: "client/resume_and_sync" },
    ],
    check(state) {
      return (
        Object.keys(state.client).length === 1 &&
        Object.keys(state.systemNotifications).length === 1
      );
    },
  },
  {
    name: "background notification click catches up from canonical state",
    actions: [
      { type: "device/set_lifecycle", lifecycle: "background" },
      { type: "server/create_alert", alert: alerts.background },
      { type: "signal/realtime", notificationId: alerts.background.id },
      { type: "signal/push", notificationId: alerts.background.id },
      {
        type: "client/notification_click",
        notificationId: alerts.background.id,
        at: "2026-07-30T20:00:00Z",
      },
    ],
    check(state) {
      return Boolean(state.client[alerts.background.id]?.openedAt);
    },
  },
  {
    name: "denied permission keeps the persisted platform fallback",
    actions: [
      { type: "device/deny_permission" },
      { type: "device/set_lifecycle", lifecycle: "terminated" },
      { type: "server/create_alert", alert: alerts.denied },
      { type: "signal/push", notificationId: alerts.denied.id },
      { type: "client/resume_and_sync" },
    ],
    check(state) {
      return (
        Boolean(state.client[alerts.denied.id]) &&
        !state.systemNotifications[alerts.denied.id]
      );
    },
  },
  {
    name: "critical call alert also queues the approved WhatsApp fallback",
    actions: [
      { type: "device/deny_permission" },
      { type: "server/create_alert", alert: alerts.critical },
      { type: "client/resume_and_sync" },
    ],
    check(state) {
      return state.deliveries.some(
        (delivery) =>
          delivery.notificationId === alerts.critical.id &&
          delivery.channel === "whatsapp" &&
          delivery.status === "queued" &&
          delivery.detail === "no_link",
      );
    },
  },
  {
    name: "invalid subscription never removes the in-app copy",
    actions: [
      { type: "device/invalidate_subscription" },
      { type: "server/create_alert", alert: alerts.invalid },
      { type: "signal/push", notificationId: alerts.invalid.id },
      { type: "client/resume_and_sync" },
    ],
    check(state) {
      return (
        Boolean(state.client[alerts.invalid.id]) &&
        !state.systemNotifications[alerts.invalid.id]
      );
    },
  },
  {
    name: "open is observable but only the platform marks read",
    actions: [
      { type: "server/create_alert", alert: alerts.read },
      { type: "signal/push", notificationId: alerts.read.id },
      {
        type: "client/notification_click",
        notificationId: alerts.read.id,
        at: "2026-07-30T20:01:00Z",
      },
    ],
    check(state) {
      const clicked = state.client[alerts.read.id];
      if (!clicked?.openedAt || clicked.readAt) return false;
      const read = reduce(state, {
        type: "client/mark_read",
        notificationId: alerts.read.id,
        at: "2026-07-30T20:02:00Z",
      });
      return Boolean(read.client[alerts.read.id]?.readAt);
    },
  },
];

function runScenarios() {
  let passed = 0;

  for (const scenario of scenarios) {
    const state = apply(initialState(), scenario.actions);
    const failures = invariantFailures(state);
    const ok = failures.length === 0 && scenario.check(state);
    if (ok) passed += 1;

    console.log(`\n${ok ? "PASS" : "FAIL"} — ${scenario.name}`);
    console.log(JSON.stringify(summarize(state), null, 2));
    if (failures.length) console.log("Invariant failures:", failures);
  }

  console.log(`\nResult: ${passed}/${scenarios.length} scenarios passed`);
  if (passed !== scenarios.length) process.exitCode = 1;
}

function render(state) {
  console.clear();
  console.log("\x1b[1mPROTOTYPE — delivery convergence\x1b[0m");
  console.log(JSON.stringify(summarize(state), null, 2));
  console.log(
    "\n\x1b[1m[n]\x1b[0m normal alert  \x1b[1m[c]\x1b[0m critical alert" +
      "  \x1b[1m[r]\x1b[0m Realtime newest  \x1b[1m[p]\x1b[0m push newest",
  );
  console.log(
    "\x1b[1m[b]\x1b[0m background  \x1b[1m[t]\x1b[0m terminated" +
      "  \x1b[1m[f]\x1b[0m foreground + sync  \x1b[1m[d]\x1b[0m deny push",
  );
  console.log(
    "\x1b[1m[i]\x1b[0m invalidate subscription  \x1b[1m[o]\x1b[0m open newest" +
      "  \x1b[1m[m]\x1b[0m mark newest read  \x1b[1m[q]\x1b[0m quit",
  );
}

async function interactive() {
  const rl = createInterface({ input, output });
  let state = initialState();
  let sequence = 0;
  let newestId = null;
  render(state);

  while (true) {
    const command = (await rl.question("> ")).trim().toLowerCase();
    if (command === "q") break;

    if (command === "n" || command === "c") {
      sequence += 1;
      newestId = `interactive-${sequence}`;
      state = reduce(state, {
        type: "server/create_alert",
        alert: {
          id: newestId,
          revision: 1,
          severity: command === "c" ? "critical" : "normal",
          type:
            command === "c"
              ? "call_unassigned_t15"
              : "conversation_needs_action",
        },
      });
    } else if (command === "r" && newestId) {
      state = reduce(state, {
        type: "signal/realtime",
        notificationId: newestId,
      });
    } else if (command === "p" && newestId) {
      state = reduce(state, {
        type: "signal/push",
        notificationId: newestId,
      });
    } else if (command === "b" || command === "t") {
      state = reduce(state, {
        type: "device/set_lifecycle",
        lifecycle: command === "b" ? "background" : "terminated",
      });
    } else if (command === "f") {
      state = reduce(state, { type: "client/resume_and_sync" });
    } else if (command === "d") {
      state = reduce(state, { type: "device/deny_permission" });
    } else if (command === "i") {
      state = reduce(state, { type: "device/invalidate_subscription" });
    } else if (command === "o" && newestId) {
      state = reduce(state, {
        type: "client/notification_click",
        notificationId: newestId,
        at: new Date().toISOString(),
      });
    } else if (command === "m" && newestId) {
      state = reduce(state, {
        type: "client/mark_read",
        notificationId: newestId,
        at: new Date().toISOString(),
      });
    }

    render(state);
  }

  rl.close();
}

if (process.argv.includes("--scenario")) runScenarios();
else await interactive();
