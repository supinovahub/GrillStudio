const APPROVED_CRITICAL_WHATSAPP_TYPES = new Set([
  "call_unassigned_t15",
  "call_unassigned_at_start",
  "call_returned_without_replacement_t15",
  "broker_reported_absent",
  "call_link_missing_near_start",
]);

export function initialState() {
  return {
    canonical: {},
    client: {},
    systemNotifications: {},
    deliveries: [],
    device: {
      lifecycle: "foreground",
      realtime: "connected",
      permission: "granted",
      subscription: "active",
    },
  };
}

function copy(state) {
  return structuredClone(state);
}

function record(state, notificationId, channel, status, detail = null) {
  state.deliveries.push({
    sequence: state.deliveries.length + 1,
    notificationId,
    channel,
    status,
    detail,
  });
}

function syncFromCanonical(state) {
  for (const [id, alert] of Object.entries(state.canonical)) {
    state.client[id] = {
      id,
      revision: alert.revision,
      severity: alert.severity,
      type: alert.type,
      readAt: alert.readAt,
      openedAt: state.client[id]?.openedAt ?? null,
    };
  }
}

export function reduce(previous, action) {
  const state = copy(previous);

  switch (action.type) {
    case "device/set_lifecycle": {
      state.device.lifecycle = action.lifecycle;
      state.device.realtime =
        action.lifecycle === "foreground" ? "connected" : "disconnected";
      return state;
    }

    case "device/deny_permission": {
      state.device.permission = "denied";
      state.device.subscription = "none";
      record(state, null, "push", "disabled", "permission_denied");
      return state;
    }

    case "device/invalidate_subscription": {
      state.device.subscription = "invalid";
      record(state, null, "push", "disabled", "subscription_invalid");
      return state;
    }

    case "server/create_alert": {
      const prior = state.canonical[action.alert.id];
      state.canonical[action.alert.id] = {
        ...action.alert,
        revision: Math.max(action.alert.revision ?? 1, prior?.revision ?? 0),
        readAt: prior?.readAt ?? null,
      };
      record(state, action.alert.id, "platform", "persisted");

      if (
        state.device.permission === "granted" &&
        state.device.subscription === "active"
      ) {
        record(state, action.alert.id, "push", "queued");
      } else {
        record(
          state,
          action.alert.id,
          "push",
          "skipped",
          state.device.permission !== "granted"
            ? "permission_unavailable"
            : "subscription_unavailable",
        );
      }

      if (
        action.alert.severity === "critical" &&
        APPROVED_CRITICAL_WHATSAPP_TYPES.has(action.alert.type)
      ) {
        record(state, action.alert.id, "whatsapp", "queued", "no_link");
      }
      return state;
    }

    case "signal/realtime": {
      const alert = state.canonical[action.notificationId];
      if (
        !alert ||
        state.device.lifecycle !== "foreground" ||
        state.device.realtime !== "connected"
      ) {
        record(
          state,
          action.notificationId,
          "realtime",
          "ignored",
          alert ? "page_not_active" : "unknown_notification",
        );
        return state;
      }
      state.client[action.notificationId] = {
        id: alert.id,
        revision: alert.revision,
        severity: alert.severity,
        type: alert.type,
        readAt: alert.readAt,
        openedAt: state.client[action.notificationId]?.openedAt ?? null,
      };
      record(state, action.notificationId, "realtime", "applied");
      return state;
    }

    case "signal/push": {
      const alert = state.canonical[action.notificationId];
      if (
        !alert ||
        state.device.permission !== "granted" ||
        state.device.subscription !== "active"
      ) {
        record(
          state,
          action.notificationId,
          "push",
          "ignored",
          alert ? "subscription_unavailable" : "unknown_notification",
        );
        return state;
      }
      const replaced = Boolean(
        state.systemNotifications[action.notificationId],
      );
      state.systemNotifications[action.notificationId] = {
        tag: action.notificationId,
        severity: alert.severity,
        type: alert.type,
      };
      record(
        state,
        action.notificationId,
        "push",
        replaced ? "replaced_same_tag" : "shown",
      );
      return state;
    }

    case "client/resume_and_sync": {
      state.device.lifecycle = "foreground";
      state.device.realtime = "connected";
      syncFromCanonical(state);
      record(state, null, "platform", "rehydrated");
      return state;
    }

    case "client/notification_click": {
      state.device.lifecycle = "foreground";
      state.device.realtime = "connected";
      syncFromCanonical(state);
      if (state.client[action.notificationId]) {
        state.client[action.notificationId].openedAt = action.at;
      }
      record(state, action.notificationId, "push", "opened");
      return state;
    }

    case "client/mark_read": {
      const alert = state.canonical[action.notificationId];
      if (!alert) return state;
      alert.readAt = action.at;
      syncFromCanonical(state);
      record(state, action.notificationId, "platform", "read");
      return state;
    }

    default:
      throw new Error(`Unknown action: ${action.type}`);
  }
}

export function summarize(state) {
  return {
    device: state.device,
    canonicalIds: Object.keys(state.canonical),
    clientIds: Object.keys(state.client),
    systemNotificationTags: Object.keys(state.systemNotifications),
    unreadClientIds: Object.values(state.client)
      .filter((alert) => !alert.readAt)
      .map((alert) => alert.id),
    deliveries: state.deliveries,
  };
}

export function invariantFailures(state) {
  const failures = [];
  const canonicalIds = new Set(Object.keys(state.canonical));

  for (const id of Object.keys(state.client)) {
    if (!canonicalIds.has(id)) failures.push(`client alert ${id} is not canonical`);
  }
  for (const id of Object.keys(state.systemNotifications)) {
    if (!canonicalIds.has(id)) {
      failures.push(`system notification ${id} is not canonical`);
    }
  }

  const whatsapp = state.deliveries.filter(
    (delivery) => delivery.channel === "whatsapp",
  );
  for (const delivery of whatsapp) {
    const alert = state.canonical[delivery.notificationId];
    if (
      !alert ||
      alert.severity !== "critical" ||
      !APPROVED_CRITICAL_WHATSAPP_TYPES.has(alert.type)
    ) {
      failures.push(`WhatsApp was used for non-approved alert ${delivery.notificationId}`);
    }
  }

  return failures;
}
