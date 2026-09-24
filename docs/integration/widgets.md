# Widgets, Complications, and Controls

Evaluate glanceable information and high-value actions for each supported
platform. Do not add a widget or extension unless it has a concrete user job.

Consider Home Screen, Lock Screen, StandBy, macOS widgets, watchOS complications
and Smart Stack, interactive widgets, and Control Center controls only where the
selected targets support and benefit from them.

## Requirements

- Show one clear piece of timely information or a small high-value action set.
- Design every supported family deliberately; do not simply scale one layout.
- Use App Intents for configuration and interactive actions where appropriate.
- Deep-link taps through centralized, stable routes.
- Share the minimum required data using an intentional mechanism such as an App
  Group; never create an unrelated source of truth.
- Treat snapshots and timelines as stale caches and handle missing data,
  redaction, locked devices, sign-out, and migration.
- Protect sensitive information in previews, screenshots, StandBy, and the Lock
  Screen. Respect relevant-information and privacy settings.
- Keep timeline work, refreshes, images, and storage within system budgets.
- Make widget text accessible and localizable.

Deleting or revoking access to content must update shared data and timelines.
Test placeholder, snapshot, empty, offline, stale, and error states.
