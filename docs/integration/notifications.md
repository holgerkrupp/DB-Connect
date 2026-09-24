# Notifications and Live Activities

Use notifications for timely user value, not engagement pressure. Evaluate Live
Activities for an ongoing event that benefits from live glanceable state instead
of repeated notifications.

## Permission and relevance

- Ask for authorization in context, after explaining the benefit. Do not prompt
  automatically on first launch without a user-understandable reason.
- Offer useful behavior before permission and clear settings after denial.
- Respect Focus, interruption levels, relevance, scheduled summaries, and user
  preferences. Use critical alerts only with the required entitlement and a
  truly critical use case.
- Avoid duplicate, stale, or noisy notifications and provide granular controls.

## Content and actions

- Keep lock-screen content private by default and localize all text.
- Deep-link to the exact relevant destination through centralized routes.
- Add only useful actions; implement them with App Intents where appropriate.
- Revalidate authentication, authorization, and entity state before an action.
- Support background, foreground, cold-launch, and multiple-scene delivery.
- Reconcile server and device state so read, delete, revoke, or sign-out removes
  outdated pending/delivered content.

## Live Activities

Use a Live Activity for a finite ongoing event with meaningful updates. Define
start/end rules, stale and dismissal behavior, privacy on locked devices, update
budget, offline behavior, and Dynamic Island/Lock Screen layouts. Always end an
activity promptly when the event completes or access is revoked.
