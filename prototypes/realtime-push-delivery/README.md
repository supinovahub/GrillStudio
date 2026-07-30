# PROTOTYPE — Realtime, push and fallback convergence

## Question

Can one persisted notification record remain the source of truth while Supabase
Realtime, Web Push, page reloads and the approved critical WhatsApp fallback
arrive late, out of order or more than once?

This throwaway prototype models only that delivery and deduplication question.
It does not connect to Supabase, a browser push service or a real WhatsApp
provider, and it does not prove that iOS or Android delivered a notification.

## Run

Use Node.js 22:

```sh
node prototypes/realtime-push-delivery/prototype.mjs --scenario all
```

Run without arguments for the interactive terminal:

```sh
node prototypes/realtime-push-delivery/prototype.mjs
```

The automated scenarios exercise:

1. duplicate Realtime and push signals in foreground;
2. a background page recovered by notification click;
3. denied permission followed by page reload;
4. a critical call alert with the approved WhatsApp fallback;
5. an invalidated push subscription;
6. the distinction between opening and reading an alert.

## Expected invariants

- Every alert exists first in the canonical persisted store.
- Realtime and push carry the same stable notification ID.
- Duplicate or reordered signals converge to one in-app record and one system
  notification tag.
- Reload/resume rehydrates from canonical state instead of trusting a missed
  signal.
- Notification click records an interaction but does not imply that the alert
  was read.
- Only the approved critical call types create a WhatsApp delivery.
- Denied permission or an invalid subscription never removes the in-app copy.

## Scope limit

Physical-device checks over HTTPS remain necessary for installed iOS/iPadOS
Home Screen web apps and current Android browsers. Browser and operating-system
delivery cannot be inferred from this state model.
