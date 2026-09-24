# App Intents and Shortcuts

Evaluate App Intents for every major feature. Add only actions and entities that
are useful outside the full app and supported by the selected targets.

## Design

- Identify the app's important actions, objects, queries, and parameters.
- Model durable user-recognizable objects as `AppEntity` where appropriate.
- Give entities stable identifiers and queries backed by the real data layer.
- Use clear titles, parameter summaries, defaults, disambiguation, and errors.
- Keep intents focused and composable; never expose an internal method as an
  intent without designing its user-facing contract.
- Prefer App Intents to private automation schemes for Shortcuts, Siri,
  Spotlight, widgets, controls, and system suggestions.

## Safety and execution

- Validate every parameter and entity again at execution time.
- Require authentication, confirmation, or foreground continuation for
  sensitive, destructive, financial, or privacy-relevant work.
- Keep execution cancellation-aware and avoid assuming the main app is running.
- Return useful dialogs, results, and entity representations.
- Localize intent titles, descriptions, parameters, and errors.
- Test missing entities, stale identifiers, denied access, offline operation,
  cancellation, and duplicate invocation.

Intents should share domain operations and routes with the main app rather than
maintaining a separate behavior layer.
